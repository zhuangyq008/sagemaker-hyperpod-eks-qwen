#!/usr/bin/env bash
# Step 3 · EKS 初始化：kubeconfig、Access Entry、coredns、HyperPod Helm Chart、命名空间/ServiceAccount
source "$(dirname "$0")/lib/common.sh"

source "$ROOT_DIR/lib/eks_access.sh"
log "kubeconfig / EKS API 访问"
ensure_eks_access
kubectl version 2>/dev/null | sed -n 2p

log "Access Entry"
OP_ARN=$(resolve_operator_role_arn)
if aws eks describe-access-entry --cluster-name "$EKS_CLUSTER_NAME" --principal-arn "$OP_ARN" >/dev/null 2>&1; then
  ok "$OP_ARN 已有 Access Entry（创建者自动授予或已存在）"
else
  aws eks create-access-entry --cluster-name "$EKS_CLUSTER_NAME" --principal-arn "$OP_ARN" >/dev/null
  ok "已创建 Access Entry: $OP_ARN"
fi
aws eks associate-access-policy --cluster-name "$EKS_CLUSTER_NAME" --principal-arn "$OP_ARN" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster >/dev/null
ok "已关联 AmazonEKSClusterAdminPolicy"

log "coredns 插件（没有节点前状态为 DEGRADED，属正常）"
if aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name coredns >/dev/null 2>&1; then
  ok "coredns 已存在"
else
  aws eks create-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name coredns --resolve-conflicts OVERWRITE >/dev/null
  ok "coredns 已创建"
fi
WANT="{\"replicaCount\":${COREDNS_REPLICAS}}"
[[ -n "${SYSTEM_NODE_TYPE:-}" ]] && WANT="{\"replicaCount\":${COREDNS_REPLICAS},\"nodeSelector\":{\"node-role\":\"system\"}}"
CUR=$(aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name coredns --query 'addon.configurationValues' --output text)
if [[ "$(jq -cS . <<<"${CUR/None/{\}}" 2>/dev/null)" != "$(jq -cS . <<<"$WANT")" ]]; then
  for _ in $(seq 1 20); do   # addon 处于 UPDATING 时会拒绝更新
    aws eks update-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name coredns --resolve-conflicts OVERWRITE \
      --configuration-values "$WANT" >/dev/null 2>&1 && break
    sleep 15
  done
fi
ok "coredns 配置: $WANT"

log "HyperPod Helm Chart"
CHART_REPO="$STATE_DIR/sagemaker-hyperpod-cli"
# 固定到已验证的 commit；升级时修改 HYPERPOD_CLI_REF
HYPERPOD_CLI_REF="${HYPERPOD_CLI_REF:-89b6a52d601a31191afecc40f5f00740d51825b1}"
[[ -d "$CHART_REPO/.git" ]] || git clone -q https://github.com/aws/sagemaker-hyperpod-cli.git "$CHART_REPO"
git -C "$CHART_REPO" fetch -q origin
git -C "$CHART_REPO" -c advice.detachedHead=false checkout -q "$HYPERPOD_CLI_REF"
CHART="$CHART_REPO/helm_chart/HyperPodHelmChart"
ok "Chart commit: $(git -C "$CHART_REPO" rev-parse --short HEAD)"
helm dependencies update "$CHART" >/dev/null
REGIONAL_VALUES=()
[[ -f "$CHART/regional-values/values-${REGION}.yaml" ]] && REGIONAL_VALUES=(-f "$CHART/regional-values/values-${REGION}.yaml")
# 确保 INSTANCE_TYPE 在 nvidia-device-plugin 的机型白名单里（新机型可能还没被 Chart 收录）
python3 "$ROOT_DIR/lib/device_plugin_values.py" "$CHART/values.yaml" "$INSTANCE_TYPE" "$STATE_DIR/device-plugin-values.yaml"
REGIONAL_VALUES+=(-f "$STATE_DIR/device-plugin-values.yaml")
# 注意：deep-health-check 使用的命名空间 aws-hyperpod 不能改名
# 不加 --wait：此时还没有 HyperPod 节点，operator Pod 会 Pending，节点加入后自动调度
helm upgrade --install "$HELM_RELEASE" "$CHART" -n kube-system \
  "${REGIONAL_VALUES[@]}" \
  --set global.region="$REGION" \
  --set trainingOperators.enabled="$HYPERPOD_TRAINING_OPERATORS" \
  --set mpi-operator.enabled="$HYPERPOD_TRAINING_OPERATORS" \
  --timeout 10m
helm list -n kube-system

log "命名空间与 ServiceAccount"
render "$ROOT_DIR/k8s/namespace.yaml" K8S_NAMESPACE MODEL_LOADER_SA | kubectl apply -f -
aws eks list-pod-identity-associations --cluster-name "$EKS_CLUSTER_NAME" --namespace "$K8S_NAMESPACE" \
  --query 'associations[].[namespace,serviceAccount,associationId]' --output text
ok "EKS 初始化完成"
