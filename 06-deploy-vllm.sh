#!/usr/bin/env bash
# Step 6 · 部署 vLLM：Secret / Deployment / Service（port-forward 或 internal-nlb）
source "$(dirname "$0")/lib/common.sh"
source "$ROOT_DIR/lib/lbc.sh"
source "$ROOT_DIR/lib/expose.sh"
source "$ROOT_DIR/lib/eks_access.sh"
source "$ROOT_DIR/lib/client_guide.sh"
ensure_eks_access

if [[ "$MODEL_SOURCE" == "s3" ]]; then
  aws s3 ls "s3://${S3_BUCKET}/${MODEL_S3_PREFIX}/_SUCCESS" >/dev/null 2>&1 || die "S3 上没有模型，请先执行 05-stage-model.sh"
  MODEL_PATH="/models/${MODEL_NAME}"; MODELS_READONLY=true
else
  MODEL_PATH="$MODEL_ID"; MODELS_READONLY=false   # vLLM 直接从 HF 下载到 HF_HOME=/models/hf-cache
fi
export MODEL_PATH MODELS_READONLY

log "Secret vllm-api-key"
if ! kubectl -n "$K8S_NAMESPACE" get secret vllm-api-key >/dev/null 2>&1; then
  KEY="${API_KEY:-$(python3 -c 'import secrets; print("sk-" + secrets.token_hex(24))')}"
  kubectl -n "$K8S_NAMESPACE" create secret generic vllm-api-key --from-file=key=<(printf %s "$KEY") >/dev/null
  ok "已创建（读取方式见 README）"
elif [[ -n "${API_KEY:-}" ]]; then
  kubectl -n "$K8S_NAMESPACE" create secret generic vllm-api-key --from-file=key=<(printf %s "$API_KEY") \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "已按 config.env 更新"
else
  ok "已存在，保持不变"
fi
# API Key 同步到 Secrets Manager（<prefix>/vllm-api-key），业务系统按 IAM 权限读取
[[ "${SYNC_KEY_TO_SECRETS_MANAGER:-true}" == true ]] && sync_key_to_secrets_manager
if [[ -n "${HF_TOKEN:-}" ]]; then
  kubectl -n "$K8S_NAMESPACE" create secret generic hf-token --from-file=token=<(printf %s "$HF_TOKEN") \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

log "Deployment vllm（image: $VLLM_IMAGE · 模型缓存: $MODEL_CACHE_DIR）"
render "$ROOT_DIR/k8s/vllm-deployment.yaml.tpl" \
  K8S_NAMESPACE MODEL_LOADER_SA INSTANCE_TYPE MODEL_CACHE_DIR MODEL_SOURCE MODEL_NAME S3_BUCKET MODEL_S3_PREFIX \
  VLLM_IMAGE MODEL_PATH MODELS_READONLY SHM_SIZE VLLM_CPU_REQUEST VLLM_MEM_REQUEST VLLM_MEM_LIMIT SERVED_MODEL_NAME TP_SIZE MAX_MODEL_LEN GPU_MEM_UTIL MAX_NUM_SEQS VLLM_EXTRA_ARGS \
  | tee "$STATE_DIR/vllm-deployment.yaml" | kubectl apply -f -

log "服务暴露（EXPOSE_MODE=$EXPOSE_MODE）"
[[ "${ALB_ACM_CERT_ARN:-}" == auto || "${ALB_WAF_ACL_ARN:-}" == auto ]] || validate_expose_config
log "等待 vLLM 就绪（S3 同步 + 加载 + 编译，约 5–20 分钟）"
until kubectl -n "$K8S_NAMESPACE" get pod -l app=vllm \
        -o jsonpath='{.items[0].status.containerStatuses[0].state}' 2>/dev/null | grep -qE 'running|terminated'; do
  kubectl -n "$K8S_NAMESPACE" get pod -l app=vllm --no-headers 2>/dev/null | sed 's/^/  /'; sleep 30
done
kubectl -n "$K8S_NAMESPACE" logs -f deploy/vllm -c vllm --since=1h 2>/dev/null | \
  { while IFS= read -r line; do echo "$line"; [[ "$line" == *"Application startup complete"* ]] && break; done; } || true
kubectl -n "$K8S_NAMESPACE" rollout status deploy/vllm --timeout=30m
# 先等 vLLM 就绪再建 LB，避免 LB 健康检查长时间失败
deploy_expose
kubectl -n "$K8S_NAMESPACE" get pod,svc,ingress -l app=vllm -o wide
ok "vLLM 已就绪；下一步: ./07-test.sh"
