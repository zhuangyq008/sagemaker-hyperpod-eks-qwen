#!/usr/bin/env bash
# Step 5 · 模型准备（MODEL_SOURCE=s3 时）：一次性 Job，HF → 节点缓存 → S3；幂等
source "$(dirname "$0")/lib/common.sh"
use_kubeconfig

[[ "$MODEL_SOURCE" == "s3" ]] || { ok "MODEL_SOURCE=$MODEL_SOURCE，跳过"; exit 0; }
S3_URI="s3://${S3_BUCKET}/${MODEL_S3_PREFIX}"
if aws s3 ls "$S3_URI/_SUCCESS" >/dev/null 2>&1; then
  ok "$S3_URI 已有 _SUCCESS，跳过"; exit 0
fi

if [[ -n "${HF_TOKEN:-}" ]]; then
  kubectl -n "$K8S_NAMESPACE" create secret generic hf-token --from-file=token=<(printf %s "$HF_TOKEN") \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

JOB_STATE=$(kubectl -n "$K8S_NAMESPACE" get job stage-model -o jsonpath='{.status.active}/{.status.failed}/{.metadata.annotations.model-id}' 2>/dev/null || echo "none")
if [[ "$JOB_STATE" == "none" || "$JOB_STATE" == */[1-9]*/* || "$JOB_STATE" != */"$MODEL_ID" ]]; then
  log "提交 Job stage-model: $MODEL_ID → $S3_URI"
  kubectl -n "$K8S_NAMESPACE" delete job stage-model --ignore-not-found >/dev/null
  render "$ROOT_DIR/k8s/stage-model-job.yaml.tpl" \
    K8S_NAMESPACE MODEL_LOADER_SA INSTANCE_TYPE MODEL_ID MODEL_NAME S3_BUCKET MODEL_S3_PREFIX \
    | kubectl apply -f -
else
  log "Job stage-model 已在运行（$MODEL_ID），继续跟踪"
fi

log "等待完成（约 15–25 分钟），日志："
until kubectl -n "$K8S_NAMESPACE" get pod -l job-name=stage-model \
        -o jsonpath='{.items[0].status.initContainerStatuses[0].state}' 2>/dev/null | grep -qE 'running|terminated'; do sleep 5; done
kubectl -n "$K8S_NAMESPACE" logs -f job/stage-model -c hf-download || true
until kubectl -n "$K8S_NAMESPACE" get pod -l job-name=stage-model \
        -o jsonpath='{.items[0].status.containerStatuses[0].state}' 2>/dev/null | grep -qE 'running|terminated'; do sleep 5; done
kubectl -n "$K8S_NAMESPACE" logs -f job/stage-model -c s3-upload || true
kubectl -n "$K8S_NAMESPACE" wait job/stage-model --for=condition=complete --timeout=60m
aws s3 ls "$S3_URI/_SUCCESS" >/dev/null && ok "模型已上传到 $S3_URI"
