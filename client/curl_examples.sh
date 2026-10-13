#!/usr/bin/env bash
# curl 示例；需要先设置 OPENAI_BASE_URL / OPENAI_API_KEY（见 README）
set -euo pipefail
: "${OPENAI_BASE_URL:?}" "${OPENAI_API_KEY:?}"
MODEL="${MODEL:-qwen3.6-35b-a3b}"
# API Key 写入仅本人可读的临时文件，用 -H @file 传给 curl，避免出现在进程列表中
HDR=$(umask 077; mktemp); trap 'rm -f "$HDR"' EXIT
printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$OPENAI_API_KEY" > "$HDR"
AUTH=(-H "@$HDR")

echo "== /models"; curl -sf "$OPENAI_BASE_URL/models" "${AUTH[@]}" | jq -r '.data[].id'

echo "== 非思考模式"
curl -sf "$OPENAI_BASE_URL/chat/completions" "${AUTH[@]}" -d "{
  \"model\": \"$MODEL\",
  \"messages\": [{\"role\":\"user\",\"content\":\"用三句话介绍 SageMaker HyperPod\"}],
  \"max_tokens\": 512, \"temperature\": 0.7, \"top_p\": 0.8, \"top_k\": 20, \"presence_penalty\": 1.5,
  \"chat_template_kwargs\": {\"enable_thinking\": false}
}" | jq -r '.choices[0].message.content'

echo "== 思考模式（reasoning 与 content 分开返回）"
curl -sf "$OPENAI_BASE_URL/chat/completions" "${AUTH[@]}" -d "{
  \"model\": \"$MODEL\",
  \"messages\": [{\"role\":\"user\",\"content\":\"9.11 和 9.9 哪个大？\"}],
  \"max_tokens\": 2048, \"temperature\": 1.0, \"top_p\": 0.95, \"top_k\": 20, \"presence_penalty\": 1.5
}" | jq '{reasoning: ((.choices[0].message.reasoning_content // .choices[0].message.reasoning // "")[:300]), content: .choices[0].message.content, usage}'

echo "== 流式"
curl -sfN "$OPENAI_BASE_URL/chat/completions" "${AUTH[@]}" -d "{
  \"model\": \"$MODEL\", \"stream\": true, \"max_tokens\": 128,
  \"messages\": [{\"role\":\"user\",\"content\":\"数到十\"}],
  \"chat_template_kwargs\": {\"enable_thinking\": false}
}" | sed -n 's/^data: //p' | grep -v '^\[DONE\]' | jq -rj '.choices[0].delta.content // empty'; echo
