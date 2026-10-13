#!/usr/bin/env bash
# Step 7 · 验证：鉴权 / 模型列表 / 思考与非思考 / 流式 / 工具调用 / vllm bench serve（1/4/8 并发）
# 生产模式（internal-nlb / alb）经负载均衡器测试：运维终端能直连就在本地跑，否则在 VPC 内的 vLLM Pod 中跑
# 用法: ./07-test.sh [--skip-bench]
source "$(dirname "$0")/lib/common.sh"
source "$ROOT_DIR/lib/eks_access.sh"
ensure_eks_access
SKIP_BENCH=false; [[ "${1:-}" == "--skip-bench" ]] && SKIP_BENCH=true
LOCAL_PORT="${LOCAL_PORT:-8000}"

OPENAI_API_KEY=$(kubectl -n "$K8S_NAMESPACE" get secret vllm-api-key -o jsonpath='{.data.key}' | base64 -d)
export OPENAI_API_KEY MODEL="$SERVED_MODEL_NAME"
[[ -s "$STATE_DIR/endpoint" ]] || die "缺少 $STATE_DIR/endpoint，请先执行 06-deploy-vllm.sh"
OPENAI_BASE_URL=$(cat "$STATE_DIR/endpoint"); export OPENAI_BASE_URL

RUN_IN_POD=false
if [[ "$EXPOSE_MODE" == "port-forward" ]]; then
  kubectl -n "$K8S_NAMESPACE" port-forward svc/vllm "${LOCAL_PORT}:8000" >/dev/null 2>&1 &
  PF_PID=$!; trap 'kill $PF_PID 2>/dev/null || true' EXIT
  OPENAI_BASE_URL="http://127.0.0.1:${LOCAL_PORT}/v1"
  for _ in $(seq 1 30); do curl -sf -m 2 "http://127.0.0.1:${LOCAL_PORT}/health" >/dev/null && break; sleep 1; done
elif ! curl -s -o /dev/null -m 8 "${OPENAI_BASE_URL%/v1}/health"; then
  RUN_IN_POD=true
fi
log "Endpoint: $OPENAI_BASE_URL（$($RUN_IN_POD && echo "运维终端无法直连，在 VPC 内的 vLLM Pod 中测试" || echo "从运维终端直连测试")）"

if $RUN_IN_POD; then
  POD=$(kubectl -n "$K8S_NAMESPACE" get pod -l app=vllm -o jsonpath='{.items[0].metadata.name}')
  kubectl -n "$K8S_NAMESPACE" exec "$POD" -c vllm -- rm -rf /tmp/client
  kubectl -n "$K8S_NAMESPACE" cp "$ROOT_DIR/client" "$POD:/tmp/client" -c vllm
  run_client() {  # vLLM 镜像自带 openai SDK；key 通过 stdin 传入，不出现在进程参数里
    printf '%s' "$OPENAI_API_KEY" | kubectl -n "$K8S_NAMESPACE" exec -i "$POD" -c vllm -- \
      env OPENAI_BASE_URL="$OPENAI_BASE_URL" MODEL="$MODEL" \
      bash -c 'read -r OPENAI_API_KEY; export OPENAI_API_KEY; cd /tmp/client && python3 '"$1"'.py'
  }
else
  VENV="$STATE_DIR/venv"
  [[ -x "$VENV/bin/python" ]] || python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q -r "$ROOT_DIR/client/requirements.txt"
  run_client() { (cd "$ROOT_DIR/client" && "$VENV/bin/python" "$1.py"); }
fi

FAIL=0
for s in smoke chat stream tools; do
  echo "---------- client/$s.py"
  run_client "$s" || { warn "client/$s.py 失败"; FAIL=1; }
done
if ! $RUN_IN_POD; then echo "---------- client/curl_examples.sh"; "$ROOT_DIR/client/curl_examples.sh" || FAIL=1; fi
(( FAIL == 0 )) && ok "功能验证通过" || die "功能验证有失败项"

$SKIP_BENCH && exit 0
log "压测 vllm bench serve（Pod 内直连 vLLM，random 输入 1024 / 输出 256）"
TOKENIZER="/models/${MODEL_NAME}"; [[ "$MODEL_SOURCE" == "s3" ]] || TOKENIZER="$MODEL_ID"
for C in 1 4 8; do
  N=$(( C * 8 )); (( N < 16 )) && N=16
  echo "========== 并发 $C（$N 个请求）"
  kubectl -n "$K8S_NAMESPACE" exec deploy/vllm -c vllm -- \
    env B_MODEL="$SERVED_MODEL_NAME" B_TOKENIZER="$TOKENIZER" B_N="$N" B_C="$C" bash -c '
    OPENAI_API_KEY=$VLLM_API_KEY vllm bench serve \
      --backend openai-chat --base-url http://127.0.0.1:8000 --endpoint /v1/chat/completions \
      --model "$B_MODEL" --tokenizer "$B_TOKENIZER" \
      --dataset-name random --random-input-len 1024 --random-output-len 256 \
      --num-prompts "$B_N" --max-concurrency "$B_C" --ignore-eos \
      --percentile-metrics ttft,tpot,e2el --metric-percentiles 50,99 2>&1' \
    | sed -n '/Serving Benchmark Result/,/^====*$/p' | tee "$STATE_DIR/bench-c${C}.txt"
done
ok "验证完成；压测结果在 $STATE_DIR/bench-c*.txt"
