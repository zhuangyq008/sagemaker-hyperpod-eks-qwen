#!/usr/bin/env bash
# EKS API 连通性保障：CloudShell 每个会话的出口公网 IP 都会变，公网白名单（/32）需要随之更新
# 依赖 lib/common.sh

# kubectl 能否访问 API Server；失败原因写入 EKS_ACCESS_ERR
eks_reachable() {
  EKS_ACCESS_ERR=$(timeout 20 kubectl get --raw /healthz --request-timeout=10s 2>&1 >/dev/null) && return 0
  EKS_ACCESS_ERR="${EKS_ACCESS_ERR:-timeout}"; return 1
}

# 等待 EKS 集群配置更新完成（update-cluster-config 期间不能再次更新）
eks_wait_updates() {
  local id
  for id in $(aws eks list-updates --name "$EKS_CLUSTER_NAME" --query 'updateIds[]' --output text); do
    while [[ "$(aws eks describe-update --name "$EKS_CLUSTER_NAME" --update-id "$id" --query 'update.status' --output text)" == "InProgress" ]]; do
      printf '  %s  等待 EKS 配置更新 %s...\n' "$(date +%H:%M:%S)" "${id:0:8}"; sleep 20
    done
  done
}

# 确保 kubectl 可用；EKS_PUBLIC_ACCESS_CIDRS=auto 时把白名单更新为当前出口 IP
ensure_eks_access() {
  use_kubeconfig
  if eks_reachable; then ok "EKS API 可访问"; return 0; fi

  if [[ "$EKS_ACCESS_ERR" =~ (Unauthorized|forbidden|Forbidden|credentials) ]]; then
    die "能连上 EKS API 但认证/授权失败：请确认当前身份 $(resolve_operator_role_arn) 已有 Access Entry（03-eks-bootstrap.sh）"
  fi
  local mode="${EKS_PUBLIC_ACCESS_CIDRS:-}" cur want ip
  if [[ -z "$mode" ]]; then
    die "EKS 只开启了内网端点，当前环境访问不到。请在同一 VPC 内运行（例如 CloudShell VPC 环境），或把 EKS_PUBLIC_ACCESS_CIDRS 设为 auto"
  fi
  ip=$(resolve_public_cidrs); validate_public_cidrs "$ip"
  cur=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" \
          --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text | tr '\t' ',')
  if [[ ",$cur," == *",${ip%%,*},"* ]]; then
    die "当前 IP 已在白名单（$cur），但仍连不上 EKS API：$EKS_ACCESS_ERR"
  fi
  # 追加而不是覆盖（不冲掉团队其他成员的条目）；EKS 最多 40 条
  want=$(printf '%s,%s' "$cur" "$ip" | tr ',' '\n' | grep -v '^$' | awk '!seen[$0]++' | tail -40 | paste -sd, -)
  if declare -F confirm >/dev/null && ! confirm "把当前出口 IP ${ip} 加入 EKS API 白名单？" y; then
    die "已取消；当前环境无法访问 EKS API"
  fi
  warn "当前出口 IP 不在 EKS 白名单中（现有: $cur）→ 追加 $ip（约 3–8 分钟）"
  eks_wait_updates
  aws eks update-cluster-config --name "$EKS_CLUSTER_NAME" \
    --resources-vpc-config "endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs=${want}" >/dev/null
  sleep 10; eks_wait_updates
  for _ in $(seq 1 12); do
    if eks_reachable; then
      ok "EKS API 可访问（白名单 $want）"
      warn "白名单会随 CloudShell 会话累积；重新执行 02-infra.sh 会收敛为当前 IP"
      return 0
    fi
    sleep 10
  done
  die "更新白名单后仍无法访问 EKS API"
}
