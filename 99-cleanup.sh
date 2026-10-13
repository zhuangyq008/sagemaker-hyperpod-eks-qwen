#!/usr/bin/env bash
# 清理：按创建的相反顺序删除；需输入 HyperPod 集群名确认
# 用法: ./99-cleanup.sh [--purge-s3] [--yes]
source "$(dirname "$0")/lib/common.sh"
source "$ROOT_DIR/lib/lbc.sh"
PURGE_S3=false; ASSUME_YES=false
for a in "$@"; do
  case "$a" in
    --purge-s3) PURGE_S3=true ;;
    --yes) ASSUME_YES=true ;;
    *) die "未知参数: $a" ;;
  esac
done

warn "将删除: K8s 命名空间 $K8S_NAMESPACE、HyperPod 集群 $HP_CLUSTER_NAME、Helm $HELM_RELEASE、CloudFormation 栈 $STACK_NAME"
$PURGE_S3 && warn "并且清空删除 S3 桶 $S3_BUCKET（含模型权重）" || ok "S3 桶 $S3_BUCKET 将保留"
if ! $ASSUME_YES; then
  read -r -p "请输入集群名 ${HP_CLUSTER_NAME} 确认: " ans
  [[ "$ans" == "$HP_CLUSTER_NAME" ]] || die "已取消"
fi

EKS_EXISTS=false
aws eks describe-cluster --name "$EKS_CLUSTER_NAME" >/dev/null 2>&1 && { EKS_EXISTS=true; use_kubeconfig; }

log "1/5 删除命名空间 $K8S_NAMESPACE（含 NLB）"
if $EKS_EXISTS; then
  # 先删 Ingress / LoadBalancer Service，让 Load Balancer Controller 回收 ALB / NLB
  kubectl delete ingress vllm -n "$K8S_NAMESPACE" --ignore-not-found --wait=true --timeout=5m || true
  kubectl delete svc vllm -n "$K8S_NAMESPACE" --ignore-not-found --wait=true --timeout=5m || true
  sleep 30
  kubectl delete ns "$K8S_NAMESPACE" --ignore-not-found --timeout=10m || true
  kubectl delete pod gpu-smoke -n default --ignore-not-found || true
  uninstall_lbc
fi

if aws secretsmanager describe-secret --secret-id "${NAME_PREFIX}/vllm-api-key" >/dev/null 2>&1; then
  aws secretsmanager delete-secret --secret-id "${NAME_PREFIX}/vllm-api-key" --recovery-window-in-days 7 >/dev/null
  ok "Secrets Manager ${NAME_PREFIX}/vllm-api-key 已计划删除（7 天内可恢复）"
fi
[[ -n "${DOMAIN_NAME:-}" && -n "${ROUTE53_ZONE_ID:-}" ]] && warn "请手动删除 Route 53 记录 ${DOMAIN_NAME}（zone ${ROUTE53_ZONE_ID}）"

log "2/5 删除 HyperPod 集群 $HP_CLUSTER_NAME"
if [[ "$(hp_cluster_status)" != "NotFound" ]]; then
  [[ "$(hp_cluster_status)" == "Deleting" ]] || aws sagemaker delete-cluster --cluster-name "$HP_CLUSTER_NAME" >/dev/null
  while [[ "$(hp_cluster_status)" != "NotFound" ]]; do
    printf '  %s  %s\n' "$(date +%H:%M:%S)" "$(hp_cluster_status)"; sleep 30
  done
fi
ok "HyperPod 集群已删除"

log "3/5 卸载 Helm $HELM_RELEASE"
$EKS_EXISTS && { helm uninstall "$HELM_RELEASE" -n kube-system --wait 2>/dev/null || true; }
if $EKS_EXISTS && aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name coredns >/dev/null 2>&1; then
  aws eks delete-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name coredns >/dev/null
fi

log "4/5 删除 CloudFormation 栈 $STACK_NAME（S3 桶设置了 Retain，不随栈删除）"
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  aws cloudformation delete-stack --stack-name "$STACK_NAME"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
fi
ok "栈已删除"

log "5/5 S3 桶"
if $PURGE_S3 && aws s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null; then
  aws s3 rm "s3://${S3_BUCKET}" --recursive --only-show-errors
  aws s3api delete-bucket --bucket "$S3_BUCKET"
  ok "桶 $S3_BUCKET 已删除"
else
  ok "保留 s3://${S3_BUCKET}（再次部署时 02-infra 需要先删除该桶或换名；见 README）"
fi
rm -f "$STATE_DIR"/create_cluster.json
log "清理完成"
