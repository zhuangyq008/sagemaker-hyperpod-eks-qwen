#!/usr/bin/env bash
# Step 1 · 预检：身份、区域、配额、机型/AZ 供应、DLC 镜像
source "$(dirname "$0")/lib/common.sh"
FAIL=0
fail() { warn "$*"; FAIL=1; }

log "身份与区域"
aws sts get-caller-identity --query Arn --output text
ok "账号 $ACCOUNT_ID / 区域 $REGION / 操作者角色 $(resolve_operator_role_arn)"
OPT=$(aws account get-region-opt-status --region-name "$REGION" --query RegionOptStatus --output text 2>/dev/null || echo "UNKNOWN")
[[ "$OPT" =~ ^(ENABLED|ENABLED_BY_DEFAULT|UNKNOWN)$ ]] && ok "区域状态: $OPT" || fail "区域未开通: $OPT"

log "SageMaker HyperPod 配额"
SM_QUOTAS=$(aws service-quotas list-service-quotas --service-code sagemaker \
  --query 'Quotas[].[QuotaName,Value]' --output text)
quota() {  # $1=配额名称（精确匹配） $2=需求值
  local v
  v=$(awk -F'\t' -v n="$1" '$1==n{print int($2); exit}' <<<"$SM_QUOTAS")
  [[ -z "$v" ]] && { warn "未找到配额: $1"; return; }
  if (( v >= $2 )); then ok "$1 = $v (需要 ≥ $2)"; else fail "$1 = $v < $2"; fi
}
quota "${INSTANCE_TYPE} for cluster usage" "$INSTANCE_COUNT"
quota "Total number of instances allowed across SageMaker HyperPod clusters" "$INSTANCE_COUNT"
quota "Maximum number instances allowed per SageMaker HyperPod cluster" "$INSTANCE_COUNT"
quota "Maximum size of EBS volume in GB for a SageMaker HyperPod cluster instance" "$EBS_VOLUME_GB"

log "VPC 相关配额"
NEW_STACK=true
aws cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1 && NEW_STACK=false
vpc_quota() {  # $1=service $2=quota-code $3=当前用量 $4=名称 $5=hard（新建栈时满额即失败）
  local q; q=$(aws service-quotas get-service-quota --service-code "$1" --quota-code "$2" --query Quota.Value --output text 2>/dev/null || echo 0)
  if (( $3 < ${q%.*} )); then ok "$4: $3 / ${q%.*}"
  elif $NEW_STACK && [[ "${5:-}" == hard ]]; then
    fail "$4: $3 / ${q%.*} 已满，无法新建 VPC。请清理不用的 VPC，或申请提额：aws service-quotas request-service-quota-increase --service-code $1 --quota-code $2 --desired-value $(( ${q%.*} + 5 ))"
  elif $NEW_STACK; then warn "$4: $3 / ${q%.*}（已满；该配额通常为软限制，若创建失败请申请提额）"
  else ok "$4: $3 / ${q%.*}（已含本项目，复用现有 VPC）"; fi
}
vpc_quota vpc L-F678F1CE "$(aws ec2 describe-vpcs --query 'length(Vpcs)')" "VPC" hard
vpc_quota vpc L-A4707A72 "$(aws ec2 describe-internet-gateways --query 'length(InternetGateways)')" "IGW" hard
vpc_quota ec2 L-0263D0A3 "$(aws ec2 describe-addresses --query 'length(Addresses)')" "Elastic IP"

log "AZ 与机型供应"
EC2_TYPE="${INSTANCE_TYPE#ml.}"
for az in "$HYPERPOD_AZ_ID" "$SECOND_AZ_ID"; do
  aws ec2 describe-availability-zones --zone-ids "$az" --query 'AvailabilityZones[0].ZoneName' --output text >/dev/null 2>&1 \
    && ok "AZ ID $az 存在" || fail "AZ ID $az 在 $REGION 中不存在"
done
[[ "$HYPERPOD_AZ_ID" != "$SECOND_AZ_ID" ]] || fail "HYPERPOD_AZ_ID 与 SECOND_AZ_ID 不能相同"
OFFER=$(aws ec2 describe-instance-type-offerings --location-type availability-zone-id \
  --filters Name=instance-type,Values="$EC2_TYPE" Name=location,Values="$HYPERPOD_AZ_ID" \
  --query 'length(InstanceTypeOfferings)')
(( OFFER > 0 )) && ok "$EC2_TYPE 在 $HYPERPOD_AZ_ID 有供应" || fail "$EC2_TYPE 在 $HYPERPOD_AZ_ID 无供应"

log "EKS 版本"
aws eks describe-cluster-versions --cluster-versions "$EKS_VERSION" --query 'clusterVersions[0].clusterVersion' --output text 2>/dev/null \
  | grep -qx "$EKS_VERSION" && ok "EKS $EKS_VERSION 可用" || fail "EKS $EKS_VERSION 不可用"

log "vLLM 镜像"
if [[ "$VLLM_IMAGE" == *.dkr.ecr.*.amazonaws.com/* ]]; then
  REG="${VLLM_IMAGE%%.*}"; REPO="${VLLM_IMAGE#*/}"; TAG="${REPO##*:}"; REPO="${REPO%:*}"
  aws ecr describe-images --registry-id "$REG" --repository-name "$REPO" --image-ids imageTag="$TAG" \
    --query 'imageDetails[0].imagePushedAt' --output text >/dev/null 2>&1 \
    && ok "$VLLM_IMAGE 存在" || fail "$VLLM_IMAGE 不存在或无权限"
else
  warn "非 ECR 镜像 ($VLLM_IMAGE)，跳过检查"
fi

log "已有资源"
aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text 2>/dev/null \
  && warn "CloudFormation 栈 $STACK_NAME 已存在（02-infra 将执行更新）" || ok "栈 $STACK_NAME 不存在"
ok "HyperPod 集群 $HP_CLUSTER_NAME: $(hp_cluster_status)"

(( FAIL == 0 )) && log "预检通过" || die "预检未通过，请处理上面的问题"
