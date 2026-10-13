#!/usr/bin/env bash
# Step 2 · 基础设施：CloudFormation 部署 VPC + EKS + IAM + S3（约 20 分钟）
source "$(dirname "$0")/lib/common.sh"

PUBLIC_CIDRS=$(resolve_public_cidrs)
validate_public_cidrs "$PUBLIC_CIDRS"
log "部署栈 $STACK_NAME（EKS 公网白名单: ${PUBLIC_CIDRS:-<仅内网>}）"

# 桶已存在（例如上次清理时保留）则不能再由 CFN 创建
if aws s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null \
   && ! aws cloudformation describe-stack-resource --stack-name "$STACK_NAME" --logical-resource-id Bucket >/dev/null 2>&1; then
  die "桶 $S3_BUCKET 已存在但不属于栈 $STACK_NAME；请在 config.env 换一个 S3_BUCKET，或先删除/导入该桶"
fi

IFS=',' read -ra _extra <<<"${EXTRA_AZ_IDS:-}"
(( ${#_extra[@]} <= 3 )) || die "EXTRA_AZ_IDS 最多 3 个"
STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE)
case "$STATUS" in
  CREATE_IN_PROGRESS) log "栈正在创建（上次会话中断？），等待完成"; aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" ;;
  UPDATE_IN_PROGRESS|UPDATE_COMPLETE_CLEANUP_IN_PROGRESS) log "栈正在更新，等待完成"; aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME" ;;
  ROLLBACK_COMPLETE) die "栈 $STACK_NAME 首次创建失败（ROLLBACK_COMPLETE），请查看事件后执行 99-cleanup.sh 再重试" ;;
  *_IN_PROGRESS) die "栈 $STACK_NAME 状态 $STATUS，请稍后重试" ;;
esac
aws cloudformation validate-template --template-body "file://$ROOT_DIR/cfn/infra.yaml" >/dev/null
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$ROOT_DIR/cfn/infra.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --tags Project="$NAME_PREFIX" \
  --parameter-overrides \
    NamePrefix="$NAME_PREFIX" \
    VpcCidr="$VPC_CIDR" \
    HyperPodAzId="$HYPERPOD_AZ_ID" \
    SecondAzId="$SECOND_AZ_ID" \
    EksVersion="$EKS_VERSION" \
    ExtraAzId1="${_extra[0]:-}" ExtraAzId2="${_extra[1]:-}" ExtraAzId3="${_extra[2]:-}" \
    EksPublicAccessCidrs="$PUBLIC_CIDRS" \
    S3BucketName="$S3_BUCKET" \
    K8sNamespace="$K8S_NAMESPACE" \
    ModelLoaderServiceAccount="$MODEL_LOADER_SA" \
    ModelS3Prefix="${MODEL_S3_PREFIX%%/*}" \
    SystemNodeInstanceType="${SYSTEM_NODE_TYPE:-}" SystemNodeCount="${SYSTEM_NODE_COUNT:-1}"

aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
ok "基础设施就绪"
