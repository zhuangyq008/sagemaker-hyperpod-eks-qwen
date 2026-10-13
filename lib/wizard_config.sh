#!/usr/bin/env bash
# 交互式生成 config.env：区域 → 方案（含配额/供应检查）→ 网络 → 访问方式 → 系统节点 → 写入
# 依赖 lib/ui.sh、lib/resources.sh；不依赖 lib/common.sh（此时还没有 config）

wz_region() {
  ui_title "1/6 部署区域"
  local def="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
  ask WZ_REGION "区域代码（CloudShell 默认使用控制台当前区域）" "$def" '^[a-z]{2}(-gov)?-[a-z]+-[0-9]$'
  aws ec2 describe-availability-zones --region "$WZ_REGION" --query 'length(AvailabilityZones)' >/dev/null 2>&1 \
    || die "区域 $WZ_REGION 不可用（未开通或无权限）"
  aws sagemaker list-clusters --region "$WZ_REGION" --max-results 1 >/dev/null 2>&1 \
    || die "区域 $WZ_REGION 无法调用 SageMaker HyperPod API（区域不支持或无权限）"
  ok "区域 $WZ_REGION 可用"
}

request_quota() {  # $1=机型
  local code; code=$(quota_code_of "$1")
  [[ -n "$code" && "$code" != "None" ]] || { warn "找不到 $1 的配额项"; return 1; }
  wz_aws service-quotas request-service-quota-increase --service-code sagemaker --quota-code "$code" --desired-value 1 \
    --query 'RequestedQuota.[Id,Status]' --output text && ok "已提交 $1 配额申请（在 Service Quotas 控制台查看进度）"
}

wz_preset() {
  ui_title "2/6 部署方案（实时检查 ${WZ_REGION} 的 HyperPod 配额与机型供应）"
  load_quotas
  local files=() labels=() p i def=0 title
  for p in "$ROOT_DIR"/presets/*.env; do files+=("$p"); done
  for i in "${!files[@]}"; do
    p="${files[$i]}"; title=$(python3 "$ROOT_DIR/lib/envfile.py" meta "$p" TITLE)
    printf '\n  %s%d) %s%s\n' "$C_B" "$((i+1))" "$title" "$C_0"
    ui_note "$(python3 "$ROOT_DIR/lib/envfile.py" meta "$p" DESC)"
    ui_note "验证: $(python3 "$ROOT_DIR/lib/envfile.py" meta "$p" VERIFIED)"
    if preset_availability "$p" true; then labels+=("$title"); (( def == 0 )) && def=$((i+1)); else labels+=("$title（当前不可用）"); fi
  done
  echo
  (( def > 0 )) || warn "所有方案在 ${WZ_REGION} 都没有可用配额"
  choose WZ_PRESET_IDX "选择方案" "${def:-1}" "${labels[@]}"
  WZ_PRESET="${files[$((WZ_PRESET_IDX-1))]}"
  if ! preset_availability "$WZ_PRESET" false; then
    local t; t=$(grep -E '^RACE_INSTANCE_TYPES=' "$WZ_PRESET" | cut -d= -f2 | cut -d, -f1)
    warn "该方案在 ${WZ_REGION} 没有可用配额（$t）"
    if confirm "现在为 $t 提交 HyperPod 配额申请（=1）？审批通常需要数小时到数天" n; then request_quota "$t"; fi
    die "配额批准后重新运行 ./install.sh；或选择其它方案"
  fi
  IFS=',' read -ra WZ_TYPES <<<"$(grep -E '^RACE_INSTANCE_TYPES=' "$WZ_PRESET" | cut -d= -f2)"
  local usable=(); for t in "${WZ_TYPES[@]}"; do (( $(quota_of "$t") >= 1 )) && [[ -n "$(azs_of "$t")" ]] && usable+=("$t"); done
  WZ_TYPES=("${usable[@]}")
  ok "方案: $(basename "$WZ_PRESET" .env) · 候选机型: ${WZ_TYPES[*]}"
  for t in "${WZ_TYPES[@]}"; do ui_note "$t: $(gpu_spec_of "$t")"; done
}

wz_network() {
  ui_title "3/6 命名与网络"
  ask WZ_PREFIX "资源名前缀（小写字母开头，2–21 位）" "hp-llm" '^[a-z][a-z0-9-]{1,20}$'
  if aws cloudformation describe-stacks --region "$WZ_REGION" --stack-name "${WZ_PREFIX}-infra" >/dev/null 2>&1; then
    warn "栈 ${WZ_PREFIX}-infra 已存在：将复用其 VPC（VPC_CIDR/AZ 需与原来一致）"
  fi
  local sug conflict; sug=$(suggest_vpc_cidr)
  while true; do
    ask WZ_VPC_CIDR "VPC 网段（/16，避开客户现有网段）" "$sug" '^10\.[0-9]{1,3}\.0\.0/16$|^172\.(1[6-9]|2[0-9]|3[01])\.0\.0/16$|^192\.168\.0\.0/16$'
    conflict=$(vpc_cidr_conflicts "$WZ_VPC_CIDR")
    [[ -z "$conflict" ]] && break
    warn "与本区域现有 VPC 重叠: $conflict（若后续要对等/TGW 互联会冲突）"
    confirm "仍然使用 $WZ_VPC_CIDR？" n && break
  done
  read -r WZ_AZ1 WZ_AZ2 WZ_EXTRA <<<"$(pick_azs "${WZ_TYPES[@]}")"
  ok "按机型供应自动选择 AZ：主 $WZ_AZ1 · 第二 $WZ_AZ2 · 额外 ${WZ_EXTRA:-无}（容量不足时在这些 AZ 间竞速）"
  if ! confirm "使用以上 AZ？" y; then
    ask WZ_AZ1 "主 AZ ID" "$WZ_AZ1" '^[a-z0-9]+-az[0-9]+$'
    ask WZ_AZ2 "第二 AZ ID" "$WZ_AZ2" '^[a-z0-9]+-az[0-9]+$'
    ask WZ_EXTRA "额外 AZ ID（逗号分隔，最多 3 个，可留空）" "$WZ_EXTRA" '^([a-z0-9]+-az[0-9]+(,[a-z0-9]+-az[0-9]+){0,2})?$'
  fi
  ui_note "EKS API 访问：CloudShell 每次会话出口 IP 不同，选 auto 时脚本会自动把当前 IP 加入白名单"
  ask WZ_EKS_CIDRS "EKS API 公网白名单（auto / 逗号分隔 CIDR / 留空=仅内网）" "auto" '^(auto|)$|^[0-9./,]+$'
}

pick_from_list() {  # $1=变量名 $2=提示 $3=列表（ARN\t名称）；可选择“不使用”
  local __name="$1" __prompt="$2" __list="$3" __opts=("不使用") __arns=("") __sel
  while IFS=$'\t' read -r __arn __label; do [[ -n "$__arn" ]] && { __opts+=("$__label  ${C_D}${__arn}${C_0}"); __arns+=("$__arn"); }; done <<<"$__list"
  __opts+=("手动输入 ARN")
  choose __sel "$__prompt" 1 "${__opts[@]}"
  if (( __sel == ${#__opts[@]} )); then ask "$__name" "ARN" "" '^arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:[A-Za-z0-9:/_.-]+$'
  else printf -v "$__name" '%s' "${__arns[$((__sel-1))]}"; fi
}

wz_expose() {
  ui_title "4/6 访问方式"
  WZ_NLB_CIDRS=""; WZ_NLB_CERT=""; WZ_ALB_SCHEME=internal; WZ_ALB_CIDRS=""; WZ_ALB_CERT=""; WZ_WAF=""; WZ_DOMAIN=""; WZ_ZONE=""
  choose WZ_EXPOSE_IDX "业务系统如何访问模型 API？" 1 \
    "internal-nlb · 内网 NLB（推荐：业务系统在同 VPC，或经 TGW/DX/对等连接接入）" \
    "alb · ALB HTTPS（internal 或 internet-facing；支持 WAF / 域名 / 来源白名单）" \
    "port-forward · 仅调试（kubectl port-forward，只能在运维终端访问）"
  case "$WZ_EXPOSE_IDX" in
    1) WZ_EXPOSE=internal-nlb
       ask WZ_NLB_CIDRS "允许访问的来源网段（逗号分隔；默认本 VPC，可追加客户 IDC/其它 VPC 网段）" "$WZ_VPC_CIDR" '^[0-9./,]+$'
       pick_from_list WZ_NLB_CERT "TLS 证书（ACM，${WZ_REGION}）：配置后 NLB 使用 443/TLS" "$(list_acm_certs)" ;;
    2) WZ_EXPOSE=alb
       choose _s "ALB 类型" 1 "internal（内网）" "internet-facing（公网，必须配置证书）"
       [[ "$_s" == 2 ]] && WZ_ALB_SCHEME=internet-facing
       pick_from_list WZ_ALB_CERT "HTTPS 证书（ACM，${WZ_REGION}）" "$(list_acm_certs)"
       [[ "$WZ_ALB_SCHEME" == internet-facing && -z "$WZ_ALB_CERT" ]] && die "internet-facing ALB 必须配置证书"
       pick_from_list WZ_WAF "WAF Web ACL（REGIONAL）" "$(list_waf_acls)"
       local def_cidr="$WZ_VPC_CIDR"; [[ "$WZ_ALB_SCHEME" == internet-facing ]] && def_cidr=""
       ask WZ_ALB_CIDRS "允许访问的来源网段（逗号分隔；公网填客户出口 IP；0.0.0.0/0 需配合 WAF）" "$def_cidr" '^[0-9./,]+$'
       ask WZ_DOMAIN "自定义域名（需与证书匹配，可留空）" "" '^(([a-z0-9-]+\.)+[a-z]{2,})?$'
       [[ -n "$WZ_DOMAIN" ]] && ask WZ_ZONE "Route 53 Hosted Zone ID（留空=手动配置 DNS）" "" '^(Z[A-Z0-9]+)?$' ;;
    3) WZ_EXPOSE=port-forward; warn "port-forward 只适合调试，业务系统无法使用" ;;
  esac
}

wz_system_nodes() {
  ui_title "5/6 系统节点组"
  ui_note "运行 Load Balancer Controller、CoreDNS 等控制器，避免占用 GPU 节点的 Pod 槽位（小 GPU 机型 maxPods 很低）"
  ask WZ_SYS_TYPE "机型（留空=不创建；生产 / 使用 NLB/ALB 时必需）" "t3.large" '^([a-z0-9]+\.[a-z0-9]+)?$'
  [[ -z "$WZ_SYS_TYPE" && "$WZ_EXPOSE" != port-forward ]] && die "internal-nlb / alb 需要系统节点组运行 Load Balancer Controller"
  WZ_SYS_COUNT=1; [[ -n "$WZ_SYS_TYPE" ]] && ask WZ_SYS_COUNT "节点数（生产建议 2）" "1" '^[1-5]$'
}

wz_write() {
  ui_title "6/6 写入配置"
  local cfg="$ROOT_DIR/config.env"
  [[ -f "$cfg" ]] && { cp -p "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)"; ok "已备份原 config.env"; }
  cp "$ROOT_DIR/config.env.example" "$cfg"; chmod 600 "$cfg"
  python3 "$ROOT_DIR/lib/envfile.py" apply "$cfg" "$WZ_PRESET"
  python3 "$ROOT_DIR/lib/envfile.py" set "$cfg" \
    REGION="$WZ_REGION" NAME_PREFIX="$WZ_PREFIX" VPC_CIDR="$WZ_VPC_CIDR" \
    HYPERPOD_AZ_ID="$WZ_AZ1" SECOND_AZ_ID="$WZ_AZ2" EXTRA_AZ_IDS="$WZ_EXTRA" EKS_PUBLIC_ACCESS_CIDRS="$WZ_EKS_CIDRS" \
    INSTANCE_TYPE="${WZ_TYPES[0]}" RACE_INSTANCE_TYPES="$(IFS=,; echo "${WZ_TYPES[*]}")" \
    EXPOSE_MODE="$WZ_EXPOSE" NLB_SOURCE_RANGES="$WZ_NLB_CIDRS" NLB_ACM_CERT_ARN="$WZ_NLB_CERT" \
    ALB_SCHEME="$WZ_ALB_SCHEME" ALB_INBOUND_CIDRS="$WZ_ALB_CIDRS" ALB_ACM_CERT_ARN="$WZ_ALB_CERT" \
    ALB_WAF_ACL_ARN="$WZ_WAF" DOMAIN_NAME="$WZ_DOMAIN" ROUTE53_ZONE_ID="$WZ_ZONE" \
    SYSTEM_NODE_TYPE="$WZ_SYS_TYPE" SYSTEM_NODE_COUNT="$WZ_SYS_COUNT"
  ok "已生成 $cfg（权限 600）"
}

wizard_config() {
  wz_region; wz_preset; wz_network; wz_expose; wz_system_nodes; wz_write
}
