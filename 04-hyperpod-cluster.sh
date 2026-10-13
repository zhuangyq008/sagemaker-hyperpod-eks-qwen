#!/usr/bin/env bash
# Step 4 · HyperPod 集群：上传 lifecycle 脚本 → create-cluster → 等待 InService 与节点 Ready → GPU/驱动检查
# 用法: ./04-hyperpod-cluster.sh [--create-only | --wait-nodes]
#   --create-only  只创建集群并等待 InService（实例数取 CREATE_INSTANCE_COUNT，默认 INSTANCE_COUNT；
#                  配合 04b 竞速时传 0）
#   --wait-nodes   只等待节点 Ready 并做 GPU / 驱动检查
source "$(dirname "$0")/lib/common.sh"
source "$ROOT_DIR/lib/eks_access.sh"
PHASE="${1:-all}"
[[ "$PHASE" =~ ^(all|--create-only|--wait-nodes)$ ]] || die "未知参数: $PHASE"
ensure_eks_access
CREATE_INSTANCE_COUNT="${CREATE_INSTANCE_COUNT:-$INSTANCE_COUNT}"

EKS_ARN=$(stack_output EksClusterArn)
EXEC_ROLE=$(stack_output HyperPodExecutionRoleArn)
SG_ID=$(stack_output SecurityGroupId)
SUBNET_A=$(stack_output PrivateSubnetA)

if [[ "$PHASE" != "--wait-nodes" ]]; then
log "上传 lifecycle 脚本到 s3://${S3_BUCKET}/lifecycle/"
aws s3 sync "$ROOT_DIR/lifecycle/" "s3://${S3_BUCKET}/lifecycle/" --delete --only-show-errors

STATUS=$(hp_cluster_status)
if [[ "$STATUS" == "NotFound" ]]; then
  log "生成 create_cluster.json"
  # 深度健康检查 / Training Plan 为空时删除对应字段
  jq -n \
    --arg name "$HP_CLUSTER_NAME" --arg eks "$EKS_ARN" --arg ig "$INSTANCE_GROUP_NAME" \
    --arg type "$INSTANCE_TYPE" --argjson count "$CREATE_INSTANCE_COUNT" \
    --arg lc "s3://${S3_BUCKET}/lifecycle/" --arg role "$EXEC_ROLE" \
    --argjson ebs "$EBS_VOLUME_GB" --arg dhc "${DEEP_HEALTH_CHECKS:-}" \
    --arg tp "${TRAINING_PLAN_ARN:-}" --arg sg "$SG_ID" --arg subnet "$SUBNET_A" \
    --arg recovery "$NODE_RECOVERY" --arg prefix "$NAME_PREFIX" '
    {
      ClusterName: $name,
      Orchestrator: { Eks: { ClusterArn: $eks } },
      InstanceGroups: [
        ({
          InstanceGroupName: $ig,
          InstanceType: $type,
          InstanceCount: $count,
          LifeCycleConfig: { SourceS3Uri: $lc, OnCreate: "on_create.sh" },
          ExecutionRole: $role,
          InstanceStorageConfigs: [ { EbsVolumeConfig: { VolumeSizeInGB: $ebs } } ]
        }
        + (if $dhc == "" then {} else { OnStartDeepHealthChecks: ($dhc | split(",")) } end)
        + (if $tp  == "" then {} else { TrainingPlanArn: $tp } end))
      ],
      VpcConfig: { SecurityGroupIds: [ $sg ], Subnets: [ $subnet ] },
      NodeRecovery: $recovery,
      Tags: [ { Key: "Project", Value: $prefix } ]
    }' > "$STATE_DIR/create_cluster.json"
  cat "$STATE_DIR/create_cluster.json"

  log "创建 HyperPod 集群 $HP_CLUSTER_NAME（初始实例数 $CREATE_INSTANCE_COUNT）"
  if ! aws sagemaker create-cluster --cli-input-json "file://$STATE_DIR/create_cluster.json" --query ClusterArn --output text 2>"$STATE_DIR/create.err"; then
    cat "$STATE_DIR/create.err" >&2
    # 部分区域/版本不接受 0 台起建：退回 1 台（随后 04b 会接管并缩容）
    if (( CREATE_INSTANCE_COUNT == 0 )) && grep -qi 'InstanceCount' "$STATE_DIR/create.err"; then
      warn "不支持以 0 台创建，改为 1 台"
      jq '.InstanceGroups[0].InstanceCount = 1' "$STATE_DIR/create_cluster.json" > "$STATE_DIR/create_cluster.1.json"
      aws sagemaker create-cluster --cli-input-json "file://$STATE_DIR/create_cluster.1.json" --query ClusterArn --output text
    else
      die "create-cluster 失败"
    fi
  fi
else
  ok "集群已存在，当前状态: $STATUS"
fi

log "等待集群 InService（约 15–25 分钟）"
while true; do
  STATUS=$(hp_cluster_status)
  case "$STATUS" in
    InService) ok "InService"; break ;;
    Failed|RollingBack)
      aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" --query FailureMessage --output text
      die "集群状态 $STATUS" ;;
    *) printf '  %s  %s\n' "$(date +%H:%M:%S)" "$STATUS"; sleep 60 ;;
  esac
done
[[ "$PHASE" == "--create-only" ]] && { ok "集群已就绪（下一步: 04b 竞速申请节点，或 $0 --wait-nodes）"; exit 0; }
fi

aws sagemaker list-cluster-nodes --cluster-name "$HP_CLUSTER_NAME" \
  --query 'ClusterNodeSummaries[].[InstanceId,InstanceType,InstanceStatus.Status]' --output table

log "等待 K8s 节点 Ready"
for _ in $(seq 1 60); do
  READY=$(kubectl get nodes -l "node.kubernetes.io/instance-type=${INSTANCE_TYPE}" --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
  (( READY >= INSTANCE_COUNT )) && break
  sleep 20
done
(( READY >= INSTANCE_COUNT )) || die "节点未 Ready: $READY/$INSTANCE_COUNT"
kubectl get nodes -L node.kubernetes.io/instance-type,sagemaker.amazonaws.com/node-health-status

log "检查 GPU 资源（期望每节点 nvidia.com/gpu = ${TP_SIZE}）"
for _ in $(seq 1 30); do
  GPUS=$(kubectl get nodes -l "node.kubernetes.io/instance-type=${INSTANCE_TYPE}" \
    -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
  [[ "${GPUS:-0}" -ge "$TP_SIZE" ]] && break
  sleep 10
done
[[ "${GPUS:-0}" -ge "$TP_SIZE" ]] && ok "nvidia.com/gpu = $GPUS" || die "GPU 资源不足: ${GPUS:-0}（检查 nvidia-device-plugin）"

log "nvidia-smi（使用 vLLM 镜像，同时预拉取镜像；驱动需满足 DLC 的 CUDA 13.0 要求，≥ 580）"
VLLM_POD=$(kubectl -n "$K8S_NAMESPACE" get pod -l app=vllm --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$VLLM_POD" ]]; then
  # 重新运行时 GPU 已被 vLLM 占用：直接在 vLLM 容器里查看
  ok "vLLM 已在运行，复用其容器执行 nvidia-smi"
  kubectl -n "$K8S_NAMESPACE" exec "$VLLM_POD" -c vllm -- nvidia-smi > "$STATE_DIR/nvidia-smi.txt"; head -15 "$STATE_DIR/nvidia-smi.txt"
else
  kubectl delete pod gpu-smoke -n default --ignore-not-found >/dev/null
  kubectl run gpu-smoke -n default --restart=Never --image="$VLLM_IMAGE" \
    --overrides="{\"spec\":{\"priorityClassName\":\"llm-workload\",\"nodeSelector\":{\"node.kubernetes.io/instance-type\":\"${INSTANCE_TYPE}\"},\"containers\":[{\"name\":\"gpu-smoke\",\"image\":\"${VLLM_IMAGE}\",\"command\":[\"nvidia-smi\"],\"resources\":{\"limits\":{\"nvidia.com/gpu\":1}}}]}}"
  kubectl wait pod/gpu-smoke -n default --for=jsonpath='{.status.phase}'=Succeeded --timeout=30m
  kubectl logs gpu-smoke -n default > "$STATE_DIR/nvidia-smi.txt"; head -15 "$STATE_DIR/nvidia-smi.txt"
  kubectl delete pod gpu-smoke -n default >/dev/null
fi
DRIVER=$(grep -oP 'Driver Version: \K[0-9]+' "$STATE_DIR/nvidia-smi.txt" || echo 0)
(( DRIVER >= 580 )) && ok "驱动主版本 $DRIVER 满足 CUDA 13.0" \
  || warn "驱动主版本 $DRIVER < 580，可能不满足 CUDA 13.0；可把 VLLM_IMAGE 换成 vllm/vllm-openai:v0.31.0 或依赖镜像的 CUDA 兼容包"
ok "HyperPod 集群就绪"
