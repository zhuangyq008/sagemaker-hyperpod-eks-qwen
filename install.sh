#!/usr/bin/env bash
# =============================================================================
# SageMaker HyperPod (EKS) + vLLM 交互式部署向导（适用于 AWS CloudShell / Linux 运维机）
#
#   ./install.sh                  交互式菜单
#   ./install.sh deploy           直接进入部署流程（新建或从中断处继续）
#   ./install.sh status|verify|guide|cleanup
#   ./install.sh deploy --yes     非交互：全部采用默认值（需已有 config.env）
#
# 每一步都可重复执行；CloudShell 会话超时或断开后，重新运行并选择“部署”即可从中断处继续
# =============================================================================
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$ROOT_DIR/.state"; LOG_DIR="$STATE_DIR/logs"; PROGRESS="$STATE_DIR/progress"
mkdir -p "$LOG_DIR"; touch "$PROGRESS"
export PATH="$HOME/.local/bin:$PATH" AWS_RETRY_MODE="${AWS_RETRY_MODE:-adaptive}" AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-10}"
export CONFIG_FILE="${CONFIG_FILE:-$ROOT_DIR/config.env}"

ACTION="${1:-menu}"; [[ "${2:-}" == "--yes" || "${1:-}" == "--yes" ]] && export ASSUME_YES=true
[[ "$ACTION" == "--yes" ]] && ACTION=deploy

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  ✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ⚠\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m  ✘ %s\033[0m\n' "$*" >&2; exit 1; }
source "$ROOT_DIR/lib/ui.sh"
source "$ROOT_DIR/lib/resources.sh"
source "$ROOT_DIR/lib/wizard_config.sh"

is_cloudshell() { [[ "${AWS_EXECUTION_ENV:-}" == CloudShell* ]]; }
cfg() { (set +u; set -a; source "$CONFIG_FILE"; eval "echo \"\${$1:-}\"") 2>/dev/null; }

# ----------------------------------------------------------------------------- 环境检查
step_env() {
  ui_title "运行环境检查"
  local ident free
  printf '  %-14s %s\n' "终端" "$(is_cloudshell && echo "AWS CloudShell（$AWS_REGION）" || echo "$(uname -n)")" \
                       "系统/架构" "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-$(uname -s)}") / $(uname -m)"
  ident=$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>/dev/null) || die "无法获取 AWS 身份：请在 CloudShell 中运行，或先配置凭证（aws configure / 实例角色）"
  printf '  %-14s %s\n' "账号" "${ident%%$'\t'*}" "身份" "${ident#*$'\t'}"
  free=$(df -Pm "$HOME" | awk 'NR==2{print $4}')
  printf '  %-14s %s MB\n' "\$HOME 可用" "$free"
  (( free >= 300 )) || die "\$HOME 可用空间不足 300 MB（CloudShell 上限 1 GB），请清理后重试"
  is_cloudshell && ui_note "CloudShell 空闲 20–30 分钟会断开：断开后重新打开，执行 ./install.sh 选择“部署”即可继续"

  local missing=() c
  for c in aws kubectl helm jq git python3 curl; do command -v "$c" >/dev/null || missing+=("$c"); done
  helm version --short 2>/dev/null | grep -q '^v3\.' || missing+=("helm3")
  python3 -c 'import yaml' 2>/dev/null || missing+=("PyYAML")
  if (( ${#missing[@]} )); then
    warn "缺少或版本不符: ${missing[*]}"
    confirm "安装到 ~/.local/bin（无需 sudo）？" y || die "缺少必要工具"
    "$ROOT_DIR/00-install-tools.sh" | tee "$LOG_DIR/00-tools.log"
  else
    ok "工具齐全：aws $(aws --version 2>&1 | cut -d/ -f2 | cut -d' ' -f1) · kubectl $(kubectl version --client 2>/dev/null | awk 'NR==1{print $3}') · helm $(helm version --short | cut -d+ -f1) · jq · git · python3 $(python3 -V | cut -d' ' -f2)"
  fi
}

# ----------------------------------------------------------------------------- 配置
show_config() {
  ui_title "当前配置（$CONFIG_FILE）"
  local k
  for k in REGION NAME_PREFIX VPC_CIDR HYPERPOD_AZ_ID SECOND_AZ_ID EXTRA_AZ_IDS INSTANCE_TYPE RACE_INSTANCE_TYPES \
           MODEL_ID SERVED_MODEL_NAME TP_SIZE MAX_MODEL_LEN EXPOSE_MODE ALB_SCHEME SYSTEM_NODE_TYPE SYSTEM_NODE_COUNT; do
    printf '  %-22s %s\n' "$k" "$(cfg "$k")"
  done
}

step_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    show_config
    choose _c "如何处理现有配置？" 1 "沿用（继续部署 / 断点续跑）" "重新运行配置向导（原文件自动备份）" "退出，手动编辑 config.env"
    case "$_c" in 1) return 0 ;; 3) exit 0 ;; esac
  else
    $ASSUME_YES && die "非交互模式需要已有的 config.env"
  fi
  : > "$PROGRESS"     # 配置变化后重新检查所有步骤
  wizard_config
  show_config
  confirm "确认以上配置？" y || die "已取消；可重新运行 ./install.sh"
}

# ----------------------------------------------------------------------------- 步骤执行
done_step() { grep -qx "$1" "$PROGRESS"; }
mark_step() { done_step "$1" || echo "$1" >> "$PROGRESS"; }

# run_step <id> <说明> <预计耗时> <命令...>
run_step() {
  local id="$1" desc="$2" eta="$3"; shift 3
  ui_title "$desc（预计 $eta）"
  if done_step "$id"; then
    ok "上次已完成"
    confirm "跳过？" y && return 0
  fi
  local logf="$LOG_DIR/${id}-$(date +%Y%m%d-%H%M%S).log"
  while true; do
    ui_note "日志: $logf"
    if (set -o pipefail; "$@" 2>&1 | tee -a "$logf"); then mark_step "$id"; ok "$desc 完成"; return 0; fi
    warn "$desc 失败（日志: $logf）"
    $ASSUME_YES && die "非交互模式下遇到失败，已停止；处理后重新运行 ./install.sh deploy 可从此步继续"
    choose _r "如何处理？" 1 "重试" "跳过此步（不推荐）" "退出（稍后重新运行 ./install.sh 可继续）"
    case "$_r" in 2) return 0 ;; 3) exit 1 ;; esac
  done
}

cost_notice() {
  ui_title "费用提示"
  ui_note "HyperPod 节点按 $(cfg INSTANCE_TYPE)（竞速候选: $(cfg RACE_INSTANCE_TYPES)）的 SageMaker HyperPod 单价按小时计费"
  ui_note "固定开销：EKS 控制面约 0.10 美元/小时 · NAT 网关约 0.045 美元/小时 + 流量 · 系统节点 $(cfg SYSTEM_NODE_TYPE) × $(cfg SYSTEM_NODE_COUNT)"
  ui_note "价格以 https://aws.amazon.com/sagemaker/pricing/ 为准；不用时执行 ./install.sh cleanup"
  confirm "继续部署？" y || exit 0
}

flow_deploy() {
  step_env
  step_config
  run_step preflight "前置检查（身份 / 配额 / 机型供应 / 镜像）" "1 分钟" "$ROOT_DIR/01-preflight.sh"
  cost_notice
  run_step infra   "基础设施（VPC / EKS / IAM / S3 / 系统节点组）" "20–25 分钟" "$ROOT_DIR/02-infra.sh"
  run_step eks     "EKS 初始化（访问授权 / HyperPod 组件）" "3–5 分钟" "$ROOT_DIR/03-eks-bootstrap.sh"
  if [[ "$(cfg INSTANCE_COUNT)" == 1 ]]; then
    run_step cluster  "创建 HyperPod 集群" "3–10 分钟" env CREATE_INSTANCE_COUNT=0 "$ROOT_DIR/04-hyperpod-cluster.sh" --create-only
    run_step capacity "申请 GPU 节点（多机型 × 多 AZ 竞速，拿到 1 台即停止）" "几分钟到数小时，取决于容量" "$ROOT_DIR/04b-capacity-race.sh"
    run_step nodes    "等待节点就绪并检查 GPU / 驱动" "5–15 分钟" "$ROOT_DIR/04-hyperpod-cluster.sh" --wait-nodes
  else
    run_step cluster  "创建 HyperPod 集群并等待 $(cfg INSTANCE_COUNT) 个节点" "15–40 分钟" "$ROOT_DIR/04-hyperpod-cluster.sh"
  fi
  run_step model   "模型权重准备（HF → S3）" "5–25 分钟" "$ROOT_DIR/05-stage-model.sh"
  run_step vllm    "部署 vLLM 与服务入口（$(cfg EXPOSE_MODE)）" "5–20 分钟" "$ROOT_DIR/06-deploy-vllm.sh"
  flow_verify
}

flow_verify() {
  local bench=(--skip-bench)
  confirm "运行压测（1/4/8 并发，约 3–5 分钟）？" n && bench=()
  run_step "verify-$(date +%s)" "端到端验证（经服务入口调用）" "2–6 分钟" "$ROOT_DIR/07-test.sh" "${bench[@]}"
  flow_guide
}

flow_guide() {
  ui_title "客户端接入指引"
  (
    source "$ROOT_DIR/lib/common.sh"; source "$ROOT_DIR/lib/client_guide.sh"
    if confirm "把 API Key 保存到 Secrets Manager（${NAME_PREFIX}/vllm-api-key），供业务系统按 IAM 权限读取？" y; then
      sync_key_to_secrets_manager
    fi
    generate_client_guide
    echo
    sed -n '/^## 1. 接入参数/,/^## 3/p' "$ROOT_DIR/CLIENT_GUIDE.md" | sed '$d'
    ui_note "完整指引（Python / Java / TypeScript / curl / LangChain / LiteLLM 示例）：$ROOT_DIR/CLIENT_GUIDE.md"
  )
}

flow_status() {
  ui_title "部署状态"
  [[ -f "$CONFIG_FILE" ]] || { warn "还没有 config.env"; return 0; }
  (
    source "$ROOT_DIR/lib/common.sh"
    printf '  %-18s %s\n' "CloudFormation" "$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo 未创建)"
    printf '  %-18s %s\n' "EKS" "$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --query cluster.status --output text 2>/dev/null || echo 未创建)"
    printf '  %-18s %s\n' "HyperPod" "$(hp_cluster_status)"
    aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" \
      --query 'InstanceGroups[?TargetCount>`0` || CurrentCount>`0`].[InstanceGroupName,InstanceType,CurrentCount,TargetCount]' \
      --output text 2>/dev/null | awk '{printf "    实例组 %-28s %-16s %s/%s\n", $1, $2, $3, $4}'
    source "$ROOT_DIR/lib/eks_access.sh"
    if [[ "$(hp_cluster_status)" != NotFound ]] && use_kubeconfig 2>/dev/null && eks_reachable; then
      kubectl get nodes -L node.kubernetes.io/instance-type --no-headers 2>/dev/null | awk '{printf "    节点 %-36s %-6s %s\n", $1, $2, $6}'
      kubectl -n "$K8S_NAMESPACE" get deploy vllm --no-headers 2>/dev/null | awk '{printf "  %-18s 就绪 %s\n", "vLLM", $2}'
    fi
    [[ -s "$STATE_DIR/endpoint" ]] && printf '  %-18s %s\n' "服务地址" "$(cat "$STATE_DIR/endpoint")"
    printf '  %-18s %s\n' "已完成步骤" "$(paste -sd' ' "$PROGRESS" | sed 's/verify-[0-9]*/verify/g')"
  )
}

flow_cleanup() {
  [[ -f "$CONFIG_FILE" ]] || die "没有 config.env，无法定位资源"
  local args=()
  confirm "同时删除 S3 桶中的模型权重？（否 = 保留，便于再次部署）" n && args+=(--purge-s3)
  "$ROOT_DIR/99-cleanup.sh" "${args[@]}" && : > "$PROGRESS" && rm -f "$STATE_DIR/endpoint"
}

main_menu() {
  ui_banner "SageMaker HyperPod (EKS) · vLLM 大模型推理部署向导"
  while true; do
    choose _m "请选择操作" 1 "部署（新建，或从中断处继续）" "查看状态" "重新验证（功能 + 可选压测）" \
      "生成客户端接入指引" "清理资源" "退出"
    case "$_m" in
      1) flow_deploy ;; 2) flow_status ;; 3) step_env; flow_verify ;; 4) flow_guide ;; 5) flow_cleanup ;; 6) exit 0 ;;
    esac
    $ASSUME_YES && exit 0
  done
}

case "$ACTION" in
  menu) main_menu ;;
  deploy) ui_banner "SageMaker HyperPod (EKS) · vLLM 大模型推理部署向导"; flow_deploy ;;
  status) flow_status ;;
  verify) step_env; flow_verify ;;
  guide) flow_guide ;;
  cleanup) flow_cleanup ;;
  *) sed -n '3,10p' "$0"; exit 1 ;;
esac
