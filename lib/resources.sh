#!/usr/bin/env bash
# 资源探测（不依赖 config.env）：HyperPod 配额、机型的 AZ 供应、可用的证书 / WAF / VPC 网段
# 用法：先设置 WZ_REGION，再调用各函数

# EKS 控制面不支持的 AZ（EKS 用户指南）
EKS_UNSUPPORTED_AZ_IDS=" use1-az3 usw1-az2 cac1-az3 "

wz_aws() { aws --region "$WZ_REGION" "$@"; }

load_quotas() {  # 缓存 SageMaker “for cluster usage” 配额：<机型>\t<值>
  WZ_QUOTAS=$(wz_aws service-quotas list-service-quotas --service-code sagemaker \
    --query "Quotas[?ends_with(QuotaName, ' for cluster usage')].[QuotaName,Value]" --output text \
    | sed -E 's/ for cluster usage\t/\t/')
}
quota_of() { awk -F'\t' -v t="$1" '$1==t{print int($2); f=1} END{if(!f) print 0}' <<<"$WZ_QUOTAS"; }
quota_code_of() {
  wz_aws service-quotas list-service-quotas --service-code sagemaker \
    --query "Quotas[?QuotaName=='$1 for cluster usage'].QuotaCode | [0]" --output text
}

azs_of() {  # 供应该机型的 AZ ID（空格分隔、排序）
  wz_aws ec2 describe-instance-type-offerings --location-type availability-zone-id \
    --filters Name=instance-type,Values="${1#ml.}" --query 'InstanceTypeOfferings[].Location' --output text \
    | tr '\t' '\n' | sort | paste -sd' ' -
}

gpu_spec_of() {  # “4 × A10G 22GB · 48 vCPU / 192 GiB”
  wz_aws ec2 describe-instance-types --instance-types "${1#ml.}" --query \
    'InstanceTypes[0].[GpuInfo.Gpus[0].Count,GpuInfo.Gpus[0].Name,GpuInfo.Gpus[0].MemoryInfo.SizeInMiB,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB]' \
    --output text 2>/dev/null | awk '{printf "%s × %s %dGB · %s vCPU / %d GiB", $1, $2, $(NF-2)/1024, $(NF-1), $NF/1024}'
}

# 打印一个 preset 中各机型的配额 / AZ；返回 0 表示至少一个机型可用（配额 ≥ 1 且有 AZ 供应）
preset_availability() {  # $1=preset 文件 $2=是否打印（true/false）
  local types t q azs usable=1
  types=$(grep -E '^RACE_INSTANCE_TYPES=' "$1" | cut -d= -f2)
  IFS=',' read -ra _ts <<<"$types"
  for t in "${_ts[@]}"; do
    q=$(quota_of "$t"); azs=$(azs_of "$t")
    if (( q >= 1 )) && [[ -n "$azs" ]]; then usable=0; [[ "$2" == true ]] && printf '      ✅ %-16s 配额 %-2s AZ: %s\n' "$t" "$q" "$azs"
    elif [[ -z "$azs" ]]; then [[ "$2" == true ]] && printf '      ❌ %-16s 本区域不供应\n' "$t"
    else [[ "$2" == true ]] && printf '      ⚠️  %-16s 配额 0（需申请）  AZ: %s\n' "$t" "$azs"; fi
  done
  return $usable
}

# 按机型供应情况挑选 AZ：输出 “主AZ 第二AZ 额外AZ1,额外AZ2,额外AZ3”
pick_azs() {  # $@=机型列表
  local t az all=() ranked
  for t in "$@"; do (( $(quota_of "$t") >= 1 )) || continue; for az in $(azs_of "$t"); do all+=("$az"); done; done
  ranked=$(printf '%s\n' "${all[@]}" | sort | uniq -c | sort -k1,1nr -k2 | awk '{print $2}' \
    | while read -r az; do [[ "$EKS_UNSUPPORTED_AZ_IDS" == *" $az "* ]] || echo "$az"; done)
  # 至少 2 个 AZ（EKS 控制面要求）；不足时补任意受支持 AZ
  if (( $(wc -w <<<"$ranked") < 2 )); then
    ranked=$(printf '%s\n%s\n' "$ranked" "$(wz_aws ec2 describe-availability-zones --query 'AvailabilityZones[?ZoneType==`availability-zone`].ZoneId' --output text | tr '\t' '\n' | sort)" \
      | awk 'NF && !seen[$0]++' | while read -r az; do [[ "$EKS_UNSUPPORTED_AZ_IDS" == *" $az "* ]] || echo "$az"; done)
  fi
  read -ra _r <<<"$(paste -sd' ' - <<<"$ranked")"
  echo "${_r[0]} ${_r[1]} $(IFS=,; echo "${_r[*]:2:3}")"
}

# 建议一个不与现有 VPC 冲突的 /16
suggest_vpc_cidr() {
  local used; used=$(wz_aws ec2 describe-vpcs --query 'Vpcs[].CidrBlockAssociationSet[].CidrBlock' --output text | tr '\t' ' ')
  python3 - "$used" <<'EOF'
import ipaddress, sys
used = [ipaddress.ip_network(c) for c in sys.argv[1].split()]
for second in range(60, 255):
    cand = ipaddress.ip_network(f"10.{second}.0.0/16")
    if not any(cand.overlaps(u) for u in used):
        print(cand); break
EOF
}
vpc_cidr_conflicts() {  # $1=CIDR → 输出冲突的 VPC
  local used; used=$(wz_aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,CidrBlock]' --output text)
  python3 - "$1" "$used" <<'EOF'
import ipaddress, sys
cand = ipaddress.ip_network(sys.argv[1], strict=False)
for line in sys.argv[2].splitlines():
    vpc, cidr = line.split()
    if cand.overlaps(ipaddress.ip_network(cidr)):
        print(f"{vpc}({cidr})")
EOF
}

list_acm_certs() { wz_aws acm list-certificates --certificate-statuses ISSUED --query 'CertificateSummaryList[].[CertificateArn,DomainName]' --output text; }
list_waf_acls()  { wz_aws wafv2 list-web-acls --scope REGIONAL --query 'WebACLs[].[ARN,Name]' --output text 2>/dev/null; }
