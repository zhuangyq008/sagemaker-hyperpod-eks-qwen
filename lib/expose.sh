#!/usr/bin/env bash
# 服务暴露：port-forward（调试）/ internal-nlb（内网 L4，可选 TLS）/ alb（L7 HTTPS，internal 或 internet-facing）
# 依赖 lib/common.sh、lib/lbc.sh；完成后把客户端地址写入 $STATE_DIR/endpoint
ARN_RE='^arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:[A-Za-z0-9/_:.-]+$'
CIDR_RE='^(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}/([0-9]|[12][0-9]|3[0-2])$'

validate_cidr_list() {  # $1=变量名 $2=允许 0.0.0.0/0（true/false）
  local c v="${!1:-}"; [[ -n "$v" ]] || die "$1 不能为空"
  IFS=',' read -ra _cs <<<"$v"
  for c in "${_cs[@]}"; do
    [[ "$c" =~ $CIDR_RE ]] || die "$1 中的 CIDR 非法: $c"
    if [[ "$c" == "0.0.0.0/0" ]]; then [[ "$2" == true ]] || die "$1 不允许 0.0.0.0/0"
    elif (( ${c##*/} < 8 )); then die "$1 过宽: $c"; fi
  done
}

# ALB_ACM_CERT_ARN=auto / ALB_WAF_ACL_ARN=auto：部署 cfn/edge.yaml（ACM 证书 DNS 自动验证 + 专用 WAF），回填 ARN
EDGE_STACK="${NAME_PREFIX}-edge"
resolve_edge_resources() {
  [[ "$EXPOSE_MODE" == alb ]] || return 0
  local cert=false waf=false
  [[ "${ALB_ACM_CERT_ARN:-}" == auto ]] && cert=true
  [[ "${ALB_WAF_ACL_ARN:-}" == auto ]] && waf=true
  $cert || $waf || return 0
  if $cert; then
    [[ -n "${DOMAIN_NAME:-}" && -n "${ROUTE53_ZONE_ID:-}" ]] || die "ALB_ACM_CERT_ARN=auto 需要 DOMAIN_NAME 与 ROUTE53_ZONE_ID"
    aws route53 get-hosted-zone --id "$ROUTE53_ZONE_ID" --query 'HostedZone.Config.PrivateZone' --output text | grep -qx False \
      || die "ROUTE53_ZONE_ID 必须是公有托管区（ACM DNS 验证）"
    local zname; zname=$(aws route53 get-hosted-zone --id "$ROUTE53_ZONE_ID" --query 'HostedZone.Name' --output text | sed 's/\.$//')
    [[ "$DOMAIN_NAME" == "$zname" || "$DOMAIN_NAME" == *".$zname" ]] \
      || die "DOMAIN_NAME 不属于托管区 $ROUTE53_ZONE_ID"
  fi
  log "边缘资源栈 $EDGE_STACK（证书: $cert · WAF: $waf；首次签发证书约 2–5 分钟）"
  aws cloudformation deploy --stack-name "$EDGE_STACK" --template-file "$ROOT_DIR/cfn/edge.yaml" \
    --no-fail-on-empty-changeset --tags Project="$NAME_PREFIX" \
    --parameter-overrides NamePrefix="$NAME_PREFIX" DomainName="${DOMAIN_NAME:-}" HostedZoneId="${ROUTE53_ZONE_ID:-}" \
      CreateCertificate="$cert" CreateWaf="$waf" RateLimitPer5Min="${WAF_RATE_LIMIT:-300}" >/dev/null
  edge_out() { aws cloudformation describe-stacks --stack-name "$EDGE_STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
  $cert && ALB_ACM_CERT_ARN=$(edge_out CertificateArn) && ok "ACM 证书: $ALB_ACM_CERT_ARN"
  $waf && ALB_WAF_ACL_ARN=$(edge_out WebAclArn) && ok "WAF Web ACL: $ALB_WAF_ACL_ARN"
  export ALB_ACM_CERT_ARN ALB_WAF_ACL_ARN
}

validate_expose_config() {
  case "$EXPOSE_MODE" in
    port-forward) ;;
    internal-nlb)
      validate_cidr_list NLB_SOURCE_RANGES false
      [[ -z "${NLB_ACM_CERT_ARN:-}" || "$NLB_ACM_CERT_ARN" =~ $ARN_RE ]] || die "NLB_ACM_CERT_ARN 非法" ;;
    alb)
      [[ "$ALB_SCHEME" =~ ^(internal|internet-facing)$ ]] || die "ALB_SCHEME 只能是 internal 或 internet-facing"
      [[ "$ALB_IDLE_TIMEOUT" =~ ^[0-9]{2,4}$ ]] || die "ALB_IDLE_TIMEOUT 非法"
      [[ -z "${ALB_ACM_CERT_ARN:-}" || "$ALB_ACM_CERT_ARN" =~ $ARN_RE ]] || die "ALB_ACM_CERT_ARN 非法"
      if [[ -n "${ALB_WAF_ACL_ARN:-}" ]]; then
        local waf_re="^arn:aws[a-z-]*:wafv2:${REGION}:${ACCOUNT_ID}:regional/webacl/([A-Za-z0-9_-]+)/([0-9a-f-]{36})$"
        [[ "$ALB_WAF_ACL_ARN" =~ $waf_re ]] || die "ALB_WAF_ACL_ARN 必须是 ${REGION} 本账号的 REGIONAL WAFv2 Web ACL"
        aws wafv2 get-web-acl --scope REGIONAL --name "${BASH_REMATCH[1]}" --id "${BASH_REMATCH[2]}" >/dev/null 2>&1 \
          || die "WAF Web ACL 不存在或无权限: $ALB_WAF_ACL_ARN"
      fi
      [[ -z "${DOMAIN_NAME:-}" || "$DOMAIN_NAME" =~ ^([a-z0-9-]+\.)+[a-z]{2,}$ ]] || die "DOMAIN_NAME 非法"
      if [[ "$ALB_SCHEME" == internet-facing ]]; then
        [[ -n "${ALB_ACM_CERT_ARN:-}" ]] || die "internet-facing ALB 必须配置 ALB_ACM_CERT_ARN（禁止公网明文 HTTP）"
        [[ -n "${DOMAIN_NAME:-}" ]] || die "internet-facing ALB 必须配置 DOMAIN_NAME（只接受该 Host，拒绝经 ALB 原始 DNS 访问）"
        local allow_any=false; [[ -n "${ALB_WAF_ACL_ARN:-}" ]] && allow_any=true
        validate_cidr_list ALB_INBOUND_CIDRS "$allow_any"   # 放开 0.0.0.0/0 必须同时挂 WAF
      else
        validate_cidr_list ALB_INBOUND_CIDRS false
      fi ;;
    *) die "未知 EXPOSE_MODE: $EXPOSE_MODE（port-forward | internal-nlb | alb）" ;;
  esac
}

lb_hostname() {  # $1=svc|ingress，等待 LBC 分配地址
  local h
  for _ in $(seq 1 60); do
    h=$(kubectl -n "$K8S_NAMESPACE" get "$1" vllm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    [[ -n "$h" ]] && { echo "$h"; return 0; }
    sleep 10
  done
  die "等待 $1/vllm 的负载均衡器地址超时（kubectl -n $K8S_NAMESPACE describe $1 vllm 查看事件）"
}

wait_lb_healthy() {  # $1=LB DNS 名称：等待所有目标组的目标 healthy（NLB 注册 IP 目标通常需 3–5 分钟）
  local lb tgs states
  lb=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$1'].LoadBalancerArn | [0]" --output text)
  for _ in $(seq 1 60); do
    tgs=$(aws elbv2 describe-target-groups --load-balancer-arn "$lb" --query 'TargetGroups[].TargetGroupArn' --output text 2>/dev/null || true)
    states=""; for tg in $tgs; do
      states+=" $(aws elbv2 describe-target-health --target-group-arn "$tg" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)"
    done
    if [[ -n "${states// /}" && "$states" != *initial* && "$states" != *unhealthy* && "$states" != *draining* ]]; then
      ok "负载均衡器目标健康:${states}"; return 0
    fi
    printf '  %s  等待负载均衡器目标健康:%s\n' "$(date +%H:%M:%S)" "${states:- 尚未注册}"; sleep 15
  done
  die "负载均衡器目标长时间不健康（检查安全组 / Pod 就绪 / kubectl -n $K8S_NAMESPACE describe svc,ingress vllm）"
}

route53_upsert() {  # $1=LB DNS 名称：DOMAIN_NAME + ROUTE53_ZONE_ID 都配置时创建 Alias 记录
  [[ -n "${DOMAIN_NAME:-}" && -n "${ROUTE53_ZONE_ID:-}" ]] || return 0
  local zone cur
  zone=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$1'].CanonicalHostedZoneId | [0]" --output text)
  # 只覆盖“不存在”或“已指向本项目 LB（k8s-<ns>-vllm-*）”的记录，避免误改同名业务记录
  cur=$(aws route53 list-resource-record-sets --hosted-zone-id "$ROUTE53_ZONE_ID" \
    --query "ResourceRecordSets[?Name=='${DOMAIN_NAME}.' && (Type=='A' || Type=='CNAME')] | [0].[Type,AliasTarget.DNSName]" --output text)
  if [[ -n "$cur" && "$cur" != "None" && "$cur" != *"k8s-${K8S_NAMESPACE}-vllm-"* ]]; then
    die "Route 53 中已有 ${DOMAIN_NAME} 记录（$cur）且不属于本项目，拒绝覆盖"
  fi
  aws route53 change-resource-record-sets --hosted-zone-id "$ROUTE53_ZONE_ID" --change-batch "$(jq -n \
    --arg n "$DOMAIN_NAME" --arg z "$zone" --arg d "$1" \
    '{Changes: [{Action: "UPSERT", ResourceRecordSet: {Name: $n, Type: "A",
      AliasTarget: {HostedZoneId: $z, DNSName: $d, EvaluateTargetHealth: true}}}]}')" >/dev/null
  ok "Route 53: $DOMAIN_NAME → $1"
}

deploy_expose() {
  resolve_edge_resources
  validate_expose_config
  local scheme host
  case "$EXPOSE_MODE" in
    port-forward)
      kubectl -n "$K8S_NAMESPACE" delete ingress vllm --ignore-not-found >/dev/null
      [[ "$(kubectl -n "$K8S_NAMESPACE" get svc vllm -o jsonpath='{.spec.type}' 2>/dev/null)" == "LoadBalancer" ]] \
        && kubectl -n "$K8S_NAMESPACE" delete svc vllm >/dev/null
      render "$ROOT_DIR/k8s/vllm-service.yaml.tpl" K8S_NAMESPACE | kubectl apply -f -
      echo "http://127.0.0.1:8000/v1" > "$STATE_DIR/endpoint"
      warn "port-forward 只用于调试；客户端访问请使用 internal-nlb 或 alb" ;;
    internal-nlb)
      install_lbc
      kubectl -n "$K8S_NAMESPACE" delete ingress vllm --ignore-not-found >/dev/null
      [[ "$(kubectl -n "$K8S_NAMESPACE" get svc vllm -o jsonpath='{.spec.type}' 2>/dev/null)" == "ClusterIP" ]] \
        && kubectl -n "$K8S_NAMESPACE" delete svc vllm >/dev/null          # ClusterIP → LoadBalancer 需重建
      NLB_SOURCE_RANGES_YAML=$(tr ',' '\n' <<<"$NLB_SOURCE_RANGES" | sed 's/.*/"&"/' | paste -sd, -)
      if [[ -n "${NLB_ACM_CERT_ARN:-}" ]]; then
        NLB_PORT=443; scheme=https
        NLB_EXTRA_ANNOTATIONS="    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: ${NLB_ACM_CERT_ARN}
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: \"443\"
    service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy: ELBSecurityPolicy-TLS13-1-2-2021-06"
      else
        NLB_PORT=8000; scheme=http; NLB_EXTRA_ANNOTATIONS=""
        warn "NLB 未配置 TLS：API Key 在内网以明文传输；生产建议设置 NLB_ACM_CERT_ARN"
      fi
      export NLB_SOURCE_RANGES_YAML NLB_PORT NLB_EXTRA_ANNOTATIONS
      render "$ROOT_DIR/k8s/vllm-service-nlb.yaml.tpl" K8S_NAMESPACE NLB_SOURCE_RANGES_YAML NLB_PORT NLB_EXTRA_ANNOTATIONS | kubectl apply -f -
      host=$(lb_hostname svc); wait_lb_healthy "$host"; route53_upsert "$host"
      echo "${scheme}://${DOMAIN_NAME:-$host}:${NLB_PORT}/v1" | sed 's/:443\/v1$/\/v1/' > "$STATE_DIR/endpoint" ;;
    alb)
      install_lbc
      [[ "$(kubectl -n "$K8S_NAMESPACE" get svc vllm -o jsonpath='{.spec.type}' 2>/dev/null)" == "LoadBalancer" ]] \
        && kubectl -n "$K8S_NAMESPACE" delete svc vllm >/dev/null
      render "$ROOT_DIR/k8s/vllm-service.yaml.tpl" K8S_NAMESPACE | kubectl apply -f -
      ALB_EXTRA_ANNOTATIONS=""
      if [[ -n "${ALB_ACM_CERT_ARN:-}" ]]; then
        scheme=https
        ALB_EXTRA_ANNOTATIONS="    alb.ingress.kubernetes.io/listen-ports: '[{\"HTTPS\":443}]'
    alb.ingress.kubernetes.io/certificate-arn: ${ALB_ACM_CERT_ARN}
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06"
      else
        scheme=http
        ALB_EXTRA_ANNOTATIONS="    alb.ingress.kubernetes.io/listen-ports: '[{\"HTTP\":80}]'"
        warn "ALB 未配置证书：API Key 在内网以明文传输；生产建议设置 ALB_ACM_CERT_ARN"
      fi
      [[ -n "${ALB_WAF_ACL_ARN:-}" ]] && ALB_EXTRA_ANNOTATIONS+=$'\n'"    alb.ingress.kubernetes.io/wafv2-acl-arn: ${ALB_WAF_ACL_ARN}"
      if [[ -n "${DOMAIN_NAME:-}" ]]; then ALB_HOST_LINE="host: ${DOMAIN_NAME}"; else ALB_HOST_LINE="host: null"; fi
      export ALB_EXTRA_ANNOTATIONS ALB_HOST_LINE
      render "$ROOT_DIR/k8s/vllm-ingress-alb.yaml.tpl" K8S_NAMESPACE ALB_SCHEME ALB_INBOUND_CIDRS ALB_IDLE_TIMEOUT \
        NAME_PREFIX ALB_EXTRA_ANNOTATIONS ALB_HOST_LINE | kubectl apply -f -
      host=$(lb_hostname ingress); wait_lb_healthy "$host"; route53_upsert "$host"
      echo "${scheme}://${DOMAIN_NAME:-$host}/v1" > "$STATE_DIR/endpoint" ;;
  esac
  ok "客户端地址: $(cat "$STATE_DIR/endpoint")"
}
