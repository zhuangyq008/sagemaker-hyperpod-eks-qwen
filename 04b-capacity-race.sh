#!/usr/bin/env bash
# Step 4b（可选）· 容量竞速：在「机型 × AZ」多个组合上同时申请，第一台节点出现后把其余实例组缩到 0
# 前提：集群已由 04 创建；多 AZ 需在 config 设置 EXTRA_AZ_IDS 并重新执行 02-infra.sh
# 机型：RACE_INSTANCE_TYPES（逗号分隔，默认 INSTANCE_TYPE）；拿到后把获胜机型写回 CONFIG_FILE 的 INSTANCE_TYPE
# 用法: [RACE_PARALLEL=3] [RACE_ROUND_MIN=10] ./04b-capacity-race.sh
source "$(dirname "$0")/lib/common.sh"
source "$ROOT_DIR/lib/eks_access.sh"
RACE_PARALLEL="${RACE_PARALLEL:-3}"
RACE_ROUND_MIN="${RACE_ROUND_MIN:-10}"
RACE_MAX_HOURS="${RACE_MAX_HOURS:-6}"
RACE_INSTANCE_TYPES="${RACE_INSTANCE_TYPES:-$INSTANCE_TYPE}"
(( INSTANCE_COUNT == 1 )) || die "容量竞速只支持 INSTANCE_COUNT=1"

SG_ID=$(stack_output SecurityGroupId)
EXEC_ROLE=$(stack_output HyperPodExecutionRoleArn)
LC_URI="s3://${S3_BUCKET}/lifecycle/"

# 子网：<子网ID> <AZ ID>
SUBNETS=("$(stack_output PrivateSubnetA) ${HYPERPOD_AZ_ID}" "$(stack_output PrivateSubnetB) ${SECOND_AZ_ID}")
IFS=',' read -ra _extra <<<"${EXTRA_AZ_IDS:-}"
for i in "${!_extra[@]}"; do SUBNETS+=("$(stack_output "ExtraPrivateSubnet$((i+1))") ${_extra[$i]}"); done

# 候选：<实例组名> <机型> <子网> <AZ>；机型在各 AZ 间交错排列，让每一批覆盖不同机型和 AZ
IFS=',' read -ra TYPES <<<"$RACE_INSTANCE_TYPES"
QUOTAS=$(aws service-quotas list-service-quotas --service-code sagemaker --query 'Quotas[].[QuotaName,Value]' --output text)
CANDIDATES=()
for si in "${!SUBNETS[@]}"; do
  for ti in "${!TYPES[@]}"; do
    t="${TYPES[$(( (ti + si) % ${#TYPES[@]} ))]}"
    read -r subnet az <<<"${SUBNETS[$si]}"
    q=$(awk -F'\t' -v n="$t for cluster usage" '$1==n{print int($2)}' <<<"$QUOTAS")
    if (( ${q:-0} < 1 )); then (( si == 0 )) && warn "$t 没有 HyperPod 配额，跳过"; continue; fi
    aws ec2 describe-instance-type-offerings --location-type availability-zone-id \
      --filters Name=instance-type,Values="${t#ml.}" Name=location,Values="$az" \
      --query 'length(InstanceTypeOfferings)' --output text | grep -q '^1$' || continue
    short=$(sed -E 's/^ml\.//; s/\.//; s/xlarge$/xl/' <<<"$t")          # ml.g5.8xlarge → g58xl
    CANDIDATES+=("${INSTANCE_GROUP_NAME}-${short}-${az} ${t} ${subnet} ${az}")
  done
done
(( ${#CANDIDATES[@]} > 0 )) || die "没有可用的「机型 × AZ」组合"
(( RACE_PARALLEL > ${#CANDIDATES[@]} )) && RACE_PARALLEL=${#CANDIDATES[@]}
log "候选 ${#CANDIDATES[@]} 个组合，每轮并行 $RACE_PARALLEL 个（同一机型同一时刻只申请 1 台）"

group_spec() {  # $1=name $2=type $3=subnet $4=count
  jq -n --arg n "$1" --arg t "$2" --arg sb "$3" --argjson c "$4" \
    --arg lc "$LC_URI" --arg r "$EXEC_ROLE" --arg sg "$SG_ID" --argjson ebs "$EBS_VOLUME_GB" '
    { InstanceGroupName: $n, InstanceType: $t, InstanceCount: $c,
      LifeCycleConfig: { SourceS3Uri: $lc, OnCreate: "on_create.sh" }, ExecutionRole: $r,
      InstanceStorageConfigs: [ { EbsVolumeConfig: { VolumeSizeInGB: $ebs } } ],
      OverrideVpcConfig: { SecurityGroupIds: [ $sg ], Subnets: [ $sb ] } }'
}

# $@ = 设为 1 的候选下标；本脚本创建过的其余组设为 0
apply_counts() {
  local active=" $* " specs=() idx name type subnet az count existing
  existing=$(aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" \
    --query 'InstanceGroups[].InstanceGroupName' --output text | tr '\t' ' ')
  for idx in "${!CANDIDATES[@]}"; do
    read -r name type subnet az <<<"${CANDIDATES[$idx]}"
    count=0; [[ "$active" == *" $idx "* ]] && count=1
    [[ $count -eq 0 && " $existing " != *" $name "* ]] && continue
    specs+=("$(group_spec "$name" "$type" "$subnet" "$count")")
  done
  local names=" "; for idx in "${!CANDIDATES[@]}"; do names+="${CANDIDATES[$idx]%% *} "; done
  local others
  others=$(aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" --output json | jq -c --arg names "$names" '
    .InstanceGroups[] | .InstanceGroupName as $g | select(.TargetCount > 0 and ($names | contains(" " + $g + " ") | not))
    | {InstanceGroupName, InstanceType, InstanceCount: 0, LifeCycleConfig, ExecutionRole, InstanceStorageConfigs}
      + (if .OverrideVpcConfig then {OverrideVpcConfig} else {} end)')
  [[ -n "$others" ]] && while IFS= read -r o; do specs+=("$o"); done <<<"$others"
  printf '%s\n' "${specs[@]}" | jq -s --arg c "$HP_CLUSTER_NAME" '{ClusterName: $c, InstanceGroups: .}' \
    > "$STATE_DIR/update_cluster_race.json"
  for _ in $(seq 1 30); do   # 集群 Updating 时会拒绝新的更新
    [[ "$(hp_cluster_status)" == "InService" ]] \
      && { aws sagemaker update-cluster --cli-input-json "file://$STATE_DIR/update_cluster_race.json" >/dev/null 2>"$STATE_DIR/race.err" \
           || grep -q 'no changes' "$STATE_DIR/race.err"; } \
      && return 0
    sleep 20
  done
  cat "$STATE_DIR/race.err" >&2; die "update-cluster 失败"
}

live_node() {  # 已拿到容量的节点：<实例组> <实例ID> <状态>
  aws sagemaker list-cluster-nodes --cluster-name "$HP_CLUSTER_NAME" \
    --query "ClusterNodeSummaries[?InstanceStatus.Status!='Failure' && InstanceStatus.Status!='ShuttingDown'].[InstanceGroupName,InstanceId,InstanceStatus.Status]" \
    --output text | head -1
}

pick_batch() {  # 从 $1 开始挑 RACE_PARALLEL 个候选，同一机型只取一个（每个机型配额只有 1）
  local start=$1 n=${#CANDIDATES[@]} k idx type used=" " picked=()
  for (( k=0; k<n && ${#picked[@]}<RACE_PARALLEL; k++ )); do
    idx=$(( (start + k) % n )); read -r _ type _ _ <<<"${CANDIDATES[$idx]}"
    [[ "$used" == *" $type "* ]] && continue
    picked+=("$idx"); used+="$type "
  done
  echo "${picked[@]}"
}

finish() {  # $1=节点行
  local WIN_GROUP WIN_ID WIN_STATUS WIN_IDX="" idx WIN_TYPE WIN_AZ
  read -r WIN_GROUP WIN_ID WIN_STATUS <<<"$1"
  for idx in "${!CANDIDATES[@]}"; do [[ "${CANDIDATES[$idx]%% *}" == "$WIN_GROUP" ]] && WIN_IDX=$idx; done
  [[ -n "$WIN_IDX" ]] || die "节点 $WIN_ID 属于非候选实例组 $WIN_GROUP；请确认后手动处理"
  read -r _ WIN_TYPE _ WIN_AZ <<<"${CANDIDATES[$WIN_IDX]}"
  ok "拿到容量: $WIN_TYPE @ $WIN_AZ（$WIN_GROUP / $WIN_ID，$WIN_STATUS），其余实例组缩到 0"
  apply_counts "$WIN_IDX"
  sed -i -E "s|^INSTANCE_TYPE=[^ #]*|INSTANCE_TYPE=${WIN_TYPE}|" "$CONFIG_FILE"
  ok "已把 INSTANCE_TYPE=${WIN_TYPE} 写回 $CONFIG_FILE"
  sleep 60   # 并发窗口内可能多拿到节点：缩容后确认只剩 1 台
  aws sagemaker list-cluster-nodes --cluster-name "$HP_CLUSTER_NAME" \
    --query 'ClusterNodeSummaries[].[InstanceGroupName,InstanceType,InstanceId,InstanceStatus.Status]' --output table
  echo "$WIN_GROUP $WIN_TYPE" > "$STATE_DIR/race_winner"
  ok "完成；接着执行 ./04-hyperpod-cluster.sh --wait-nodes"
  exit 0
}

EXISTING=$(live_node)
[[ -n "$EXISTING" ]] && { log "已有节点（上次竞速/会话中断前拿到的）"; finish "$EXISTING"; }

DEADLINE=$(( $(date +%s) + RACE_MAX_HOURS * 3600 ))
START=0
while (( $(date +%s) < DEADLINE )); do
  read -ra BATCH <<<"$(pick_batch "$START")"
  log "本轮申请: $(for b in "${BATCH[@]}"; do read -r _ t _ a <<<"${CANDIDATES[$b]}"; printf '%s@%s ' "$t" "$a"; done)"
  apply_counts "${BATCH[@]}"
  ROUND_END=$(( $(date +%s) + RACE_ROUND_MIN * 60 ))
  while (( $(date +%s) < ROUND_END )); do
    NODE=$(live_node)
    [[ -n "$NODE" ]] && finish "$NODE"
    printf '  %s  等待容量...\n' "$(date +%H:%M:%S)"; sleep 30
  done
  START=$(( (START + RACE_PARALLEL) % ${#CANDIDATES[@]} ))
done
die "超过 ${RACE_MAX_HOURS} 小时仍未拿到容量；考虑 Flexible Training Plans 预留或更换机型/区域"
