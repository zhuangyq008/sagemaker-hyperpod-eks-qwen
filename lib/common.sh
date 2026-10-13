#!/usr/bin/env bash
# 公共函数：加载 config.env、推导派生参数、日志、模板渲染
# 用法：在各步骤脚本开头 source "$(dirname "$0")/lib/common.sh"
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
CONFIG_FILE="${CONFIG_FILE:-$ROOT_DIR/config.env}"
STATE_DIR="$ROOT_DIR/.state"
mkdir -p "$STATE_DIR"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  ✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ⚠\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m  ✘ %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "$CONFIG_FILE" ]] || die "缺少 $CONFIG_FILE，请先执行: cp config.env.example config.env"
set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
export AWS_RETRY_MODE="${AWS_RETRY_MODE:-adaptive}" AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-10}"

ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
S3_BUCKET="${S3_BUCKET:-sagemaker-hyperpod-${ACCOUNT_ID}-${REGION}}"
VLLM_IMAGE="${VLLM_IMAGE:-763104351884.dkr.ecr.${REGION}.amazonaws.com/vllm:0.31.0-gpu-py312-ec2}"
NLB_SOURCE_RANGES="${NLB_SOURCE_RANGES:-$VPC_CIDR}"
ALB_SCHEME="${ALB_SCHEME:-internal}"
ALB_INBOUND_CIDRS="${ALB_INBOUND_CIDRS:-$VPC_CIDR}"
ALB_IDLE_TIMEOUT="${ALB_IDLE_TIMEOUT:-900}"

STACK_NAME="${NAME_PREFIX}-infra"
EKS_CLUSTER_NAME="${NAME_PREFIX}-eks"
HP_CLUSTER_NAME="${NAME_PREFIX}-hp"
INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME:-gpu-inference}"
VLLM_CPU_REQUEST="${VLLM_CPU_REQUEST:-16}"
VLLM_MEM_REQUEST="${VLLM_MEM_REQUEST:-96Gi}"
VLLM_MEM_LIMIT="${VLLM_MEM_LIMIT:-170Gi}"
SHM_SIZE="${SHM_SIZE:-16Gi}"
HYPERPOD_TRAINING_OPERATORS="${HYPERPOD_TRAINING_OPERATORS:-true}"
COREDNS_REPLICAS="${COREDNS_REPLICAS:-2}"
SYSTEM_NODE_TYPE="${SYSTEM_NODE_TYPE-t3.large}"        # 空字符串 = 不建系统节点组
SYSTEM_NODE_COUNT="${SYSTEM_NODE_COUNT:-1}"
MODEL_NAME="${MODEL_ID##*/}"
MODEL_LOADER_SA="model-loader"
HELM_RELEASE="hyperpod-dependencies"

export ACCOUNT_ID S3_BUCKET VLLM_IMAGE NLB_SOURCE_RANGES ALB_SCHEME ALB_INBOUND_CIDRS ALB_IDLE_TIMEOUT STACK_NAME EKS_CLUSTER_NAME \
       HP_CLUSTER_NAME INSTANCE_GROUP_NAME VLLM_CPU_REQUEST VLLM_MEM_REQUEST VLLM_MEM_LIMIT SHM_SIZE MODEL_NAME MODEL_LOADER_SA HELM_RELEASE

[[ "$S3_BUCKET" == sagemaker-* ]] || die "S3_BUCKET 必须以 sagemaker- 开头（托管策略限制），当前: $S3_BUCKET"

# 会被拼进容器 bash -c 的配置值做字符白名单校验，防止 config.env 中的 ; $() ` 等注入
safe_check() {  # $1=变量名 $2=正则
  local v="${!1:-}"
  [[ -z "$v" || "$v" =~ $2 ]] || die "$1 含非法字符: $v"
}
safe_check MODEL_ID          '^[A-Za-z0-9._/-]+$'
safe_check MODEL_S3_PREFIX   '^[A-Za-z0-9._/-]+$'
safe_check SERVED_MODEL_NAME '^[A-Za-z0-9._-]+$'
safe_check VLLM_IMAGE        '^[A-Za-z0-9._/:@-]+$'
safe_check VLLM_EXTRA_ARGS   '^[A-Za-z0-9._/:=,{}" -]+$'
for _n in TP_SIZE MAX_MODEL_LEN MAX_NUM_SEQS INSTANCE_COUNT EBS_VOLUME_GB; do safe_check "$_n" '^[0-9]+$'; done
safe_check GPU_MEM_UTIL      '^0?\.[0-9]+$'
safe_check K8S_NAMESPACE     '^[a-z0-9-]+$'
safe_check HYPERPOD_TRAINING_OPERATORS '^(true|false)$'
safe_check COREDNS_REPLICAS '^[1-9]$'
safe_check SYSTEM_NODE_TYPE '^[a-z0-9]+\.[a-z0-9]+$'
safe_check SYSTEM_NODE_COUNT '^[1-5]$'
safe_check INSTANCE_GROUP_NAME '^[a-zA-Z0-9](-*[a-zA-Z0-9]){0,40}$'
for _n in VLLM_CPU_REQUEST VLLM_MEM_REQUEST VLLM_MEM_LIMIT SHM_SIZE; do safe_check "$_n" '^[0-9]+(\.[0-9]+)?(m|Mi|Gi)?$'; done

# 当前调用身份对应的 IAM 角色 ARN（assumed-role → role，带 path）
resolve_operator_role_arn() {
  if [[ -n "${OPERATOR_ROLE_ARN:-}" ]]; then echo "$OPERATOR_ROLE_ARN"; return; fi
  local arn role_name
  arn=$(aws sts get-caller-identity --query Arn --output text)
  if [[ "$arn" == *":assumed-role/"* ]]; then
    role_name=$(cut -d/ -f2 <<<"$arn")
    aws iam get-role --role-name "$role_name" --query Role.Arn --output text 2>/dev/null \
      || echo "arn:aws:iam::${ACCOUNT_ID}:role/${role_name}"
  else
    echo "$arn"
  fi
}

# EKS_PUBLIC_ACCESS_CIDRS: auto → 探测运维机公网 IP
resolve_public_cidrs() {
  if [[ "${EKS_PUBLIC_ACCESS_CIDRS:-}" == "auto" ]]; then
    local ip
    ip=$(curl -fsS -m 5 https://checkip.amazonaws.com | tr -d '[:space:]') || die "无法探测公网 IP，请在 config.env 中手动填写 EKS_PUBLIC_ACCESS_CIDRS"
    echo "${ip}/32"
  else
    echo "${EKS_PUBLIC_ACCESS_CIDRS:-}"
  fi
}

# 校验 EKS 公网白名单：每段必须是 IPv4 CIDR，且掩码 ≥ /16（拒绝 0.0.0.0/0 之类过宽网段）
validate_public_cidrs() {
  local c
  [[ -z "$1" ]] && return 0
  IFS=',' read -ra _cidrs <<<"$1"
  for c in "${_cidrs[@]}"; do
    [[ "$c" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || die "EKS_PUBLIC_ACCESS_CIDRS 非法: $c"
    (( BASH_REMATCH[2] >= 16 && BASH_REMATCH[2] <= 32 )) || die "EKS_PUBLIC_ACCESS_CIDRS 过宽（需 /16~/32）: $c"
  done
}

stack_output() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

# 只替换显式列出的变量，避免误伤清单里的 $(VAR) 写法
render() {
  python3 "$ROOT_DIR/lib/render.py" "$@"
}

hp_cluster_status() {
  aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" \
    --query ClusterStatus --output text 2>/dev/null || echo "NotFound"
}

use_kubeconfig() {
  aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --alias "$EKS_CLUSTER_NAME" >/dev/null
}
