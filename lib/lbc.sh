#!/usr/bin/env bash
# AWS Load Balancer Controller 安装（EXPOSE_MODE=internal-nlb 时由 06 调用），使用 Pod Identity
LBC_VERSION="${LBC_VERSION:-v2.13.4}"
LBC_CHART_VERSION="${LBC_CHART_VERSION:-1.13.4}"   # 对应 appVersion v2.13.4
LBC_POLICY_SHA256="${LBC_POLICY_SHA256:-16f232c9d9f79366fe949c4550ad517a202380058a9e48d45a4e215044a20a6a}"   # v2.13.4 iam_policy.json
LBC_ROLE="${NAME_PREFIX}-lbc-role"
LBC_POLICY="${NAME_PREFIX}-lbc-policy"

install_lbc() {
  if helm status aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
    ok "AWS Load Balancer Controller 已安装"; return
  fi
  local policy_arn="arn:aws:iam::${ACCOUNT_ID}:policy/${LBC_POLICY}"
  if ! aws iam get-policy --policy-arn "$policy_arn" >/dev/null 2>&1; then
    curl -fsSL "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC_VERSION}/docs/install/iam_policy.json" \
      -o "$STATE_DIR/lbc-iam-policy.json"
    echo "${LBC_POLICY_SHA256}  $STATE_DIR/lbc-iam-policy.json" | sha256sum -c - >/dev/null \
      || die "LBC IAM policy 校验失败（sha256 不符），拒绝创建"
    aws iam create-policy --policy-name "$LBC_POLICY" --policy-document "file://$STATE_DIR/lbc-iam-policy.json" >/dev/null
  fi
  if ! aws iam get-role --role-name "$LBC_ROLE" >/dev/null 2>&1; then
    aws iam create-role --role-name "$LBC_ROLE" --assume-role-policy-document "{
      \"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",
      \"Principal\":{\"Service\":\"pods.eks.amazonaws.com\"},\"Action\":[\"sts:AssumeRole\",\"sts:TagSession\"],
      \"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"${ACCOUNT_ID}\"},
      \"ArnEquals\":{\"aws:SourceArn\":\"$(stack_output EksClusterArn)\"}}}]}" >/dev/null
    aws iam attach-role-policy --role-name "$LBC_ROLE" --policy-arn "$policy_arn"
  fi
  aws eks create-pod-identity-association --cluster-name "$EKS_CLUSTER_NAME" --namespace kube-system \
    --service-account aws-load-balancer-controller --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${LBC_ROLE}" >/dev/null 2>&1 || true
  LBC_NODE_ARGS=()   # 有系统节点组时固定到系统节点，不占 GPU 节点的 Pod 槽位
  [[ -n "${SYSTEM_NODE_TYPE:-}" ]] && LBC_NODE_ARGS=(--set nodeSelector.node-role=system)
  helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
  helm repo update eks >/dev/null
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --version "$LBC_CHART_VERSION" \
    --set clusterName="$EKS_CLUSTER_NAME" --set region="$REGION" \
    --set vpcId="$(stack_output VpcId)" --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set replicaCount="$(( SYSTEM_NODE_COUNT >= 2 ? 2 : 1 ))" \
    "${LBC_NODE_ARGS[@]}" --wait --timeout 10m
  ok "AWS Load Balancer Controller 已安装"
}

uninstall_lbc() {
  helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
  local id
  id=$(aws eks list-pod-identity-associations --cluster-name "$EKS_CLUSTER_NAME" --namespace kube-system \
        --service-account aws-load-balancer-controller --query 'associations[0].associationId' --output text 2>/dev/null || true)
  [[ -n "$id" && "$id" != "None" ]] && aws eks delete-pod-identity-association --cluster-name "$EKS_CLUSTER_NAME" --association-id "$id" >/dev/null
  aws iam detach-role-policy --role-name "$LBC_ROLE" --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${LBC_POLICY}" 2>/dev/null || true
  aws iam delete-role --role-name "$LBC_ROLE" 2>/dev/null || true
  aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${LBC_POLICY}" 2>/dev/null || true
}
