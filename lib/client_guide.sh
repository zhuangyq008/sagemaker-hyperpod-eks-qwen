#!/usr/bin/env bash
# 生成客户端接入指引 CLIENT_GUIDE.md（不含 API Key 明文）；依赖 lib/common.sh

network_section() {
  case "$EXPOSE_MODE" in
    internal-nlb) cat <<EOF
- 访问方式：**内网 NLB**（L4$( [[ -n "${NLB_ACM_CERT_ARN:-}" ]] && echo "，TLS 443" || echo "，HTTP 8000（未配置 TLS，API Key 明文传输）" )）
- 允许来源：\`${NLB_SOURCE_RANGES}\`（修改 config 中的 \`NLB_SOURCE_RANGES\` 后重新执行 \`./06-deploy-vllm.sh\`）
- 业务系统需在本 VPC（\`${VPC_CIDR}\`）内，或通过 Transit Gateway / Direct Connect / VPC Peering 接入，并放通上述来源网段
- 建议在客户 DNS 中为 NLB 地址配置 CNAME（例如 \`llm.internal.example.com\`）
EOF
;;
    alb) cat <<EOF
- 访问方式：**ALB（${ALB_SCHEME}）**$( [[ -n "${ALB_ACM_CERT_ARN:-}" ]] && echo "，HTTPS 443（TLS 1.2+）" || echo "，HTTP 80（未配置证书，API Key 明文传输）" )
- 允许来源：\`${ALB_INBOUND_CIDRS}\`$( [[ -n "${ALB_WAF_ACL_ARN:-}" ]] && echo "；WAF：\`${ALB_WAF_ACL_ARN##*/webacl/}\`" )
- 空闲超时：${ALB_IDLE_TIMEOUT}s（思考模式和长输出需要；客户端超时建议 ≥ 该值）
$( [[ -n "${DOMAIN_NAME:-}" ]] && echo "- 域名：\`${DOMAIN_NAME}\`$( [[ -n "${ROUTE53_ZONE_ID:-}" ]] && echo "（Route 53 Alias 已自动创建）" || echo "（请在 DNS 中把该域名 CNAME 到 ALB 地址）" )" )
EOF
;;
    port-forward) cat <<'EOF'
- 访问方式：**port-forward（仅调试）**，只能在执行 `kubectl port-forward` 的终端访问；业务系统请改用 `internal-nlb` 或 `alb`
EOF
;;
  esac
}

generate_client_guide() {
  local endpoint key_cmd out="$ROOT_DIR/CLIENT_GUIDE.md"
  endpoint=$(cat "$STATE_DIR/endpoint" 2>/dev/null || echo "http://<endpoint>/v1")
  key_cmd="kubectl -n ${K8S_NAMESPACE} get secret vllm-api-key -o jsonpath='{.data.key}' | base64 -d"
  if aws secretsmanager describe-secret --secret-id "${NAME_PREFIX}/vllm-api-key" >/dev/null 2>&1; then
    key_cmd="aws secretsmanager get-secret-value --region ${REGION} --secret-id ${NAME_PREFIX}/vllm-api-key --query SecretString --output text"
  fi
  cat > "$out" <<EOF
# 客户端接入指引 —— ${SERVED_MODEL_NAME}

> 生成时间：$(date '+%Y-%m-%d %H:%M %Z') · 区域 ${REGION} · 集群 ${HP_CLUSTER_NAME} · 机型 ${INSTANCE_TYPE}

## 1. 接入参数

| 参数 | 值 |
|---|---|
| Base URL | \`${endpoint}\` |
| Model | \`${SERVED_MODEL_NAME}\`（底层权重 \`${MODEL_ID}\`） |
| 鉴权 | HTTP Header \`Authorization: Bearer <API_KEY>\` |
| API Key 获取 | \`${key_cmd}\` |
| 协议 | OpenAI Chat Completions 兼容（\`/v1/chat/completions\`、\`/v1/completions\`、\`/v1/models\`），支持 stream、tools |
| 上下文上限 | ${MAX_MODEL_LEN} tokens（输入 + 输出） |

## 2. 网络与安全

$(network_section)
- API Key 请保存在业务系统的密钥管理服务中（如 AWS Secrets Manager），不要写进代码或镜像

## 3. 推荐参数（来自模型卡）

| 场景 | temperature | top_p | top_k | presence_penalty | 额外参数 |
|---|---|---|---|---|---|
| 思考模式（默认，复杂推理） | 0.6–1.0 | 0.95 | 20 | 0–1.5 | 无 |
| 非思考模式（问答 / 抽取 / 翻译，低延迟） | 0.7 | 0.8 | 20 | 1.5 | \`chat_template_kwargs: {"enable_thinking": false}\` |

思考模式下推理过程在 \`message.reasoning_content\`（或 \`reasoning\`）字段，最终回答在 \`message.content\`。

## 4. 示例

环境变量（下面所有示例共用）：
\`\`\`bash
export OPENAI_BASE_URL=${endpoint}
export OPENAI_API_KEY=\$(${key_cmd})
export MODEL=${SERVED_MODEL_NAME}
\`\`\`

### 4.1 curl
\`\`\`bash
curl -s \$OPENAI_BASE_URL/chat/completions \\
  -H "Authorization: Bearer \$OPENAI_API_KEY" -H "Content-Type: application/json" \\
  -d '{"model":"${SERVED_MODEL_NAME}","messages":[{"role":"user","content":"用三句话介绍 SageMaker HyperPod"}],
       "max_tokens":512,"temperature":0.7,"top_p":0.8,"top_k":20,
       "chat_template_kwargs":{"enable_thinking":false}}'
\`\`\`

### 4.2 Python（OpenAI SDK，\`pip install openai\`）
\`\`\`python
from openai import OpenAI
client = OpenAI(timeout=600)          # 读取 OPENAI_BASE_URL / OPENAI_API_KEY

# 非思考模式
r = client.chat.completions.create(
    model="${SERVED_MODEL_NAME}",
    messages=[{"role": "user", "content": "把这句话翻译成英文：数据留在新加坡"}],
    max_tokens=512, temperature=0.7, top_p=0.8,
    extra_body={"top_k": 20, "chat_template_kwargs": {"enable_thinking": False}},
)
print(r.choices[0].message.content)

# 流式
for chunk in client.chat.completions.create(
        model="${SERVED_MODEL_NAME}", stream=True, max_tokens=512,
        messages=[{"role": "user", "content": "写一段 100 字的产品介绍"}],
        extra_body={"chat_template_kwargs": {"enable_thinking": False}}):
    if chunk.choices and chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)
\`\`\`
完整示例（思考模式、工具调用含结果回填）：\`client/chat.py\`、\`client/stream.py\`、\`client/tools.py\`

### 4.3 Java（JDK 11+ HttpClient，无第三方依赖）
\`\`\`java
var body = """
  {"model":"${SERVED_MODEL_NAME}","max_tokens":512,
   "messages":[{"role":"user","content":"设备 SG-001 的告警如何处理？"}],
   "chat_template_kwargs":{"enable_thinking":false}}""";
var req = java.net.http.HttpRequest.newBuilder(java.net.URI.create(System.getenv("OPENAI_BASE_URL") + "/chat/completions"))
    .header("Authorization", "Bearer " + System.getenv("OPENAI_API_KEY"))
    .header("Content-Type", "application/json")
    .timeout(java.time.Duration.ofMinutes(10))
    .POST(java.net.http.HttpRequest.BodyPublishers.ofString(body)).build();
var resp = java.net.http.HttpClient.newHttpClient().send(req, java.net.http.HttpResponse.BodyHandlers.ofString());
System.out.println(resp.body());
\`\`\`
Spring AI：\`spring.ai.openai.base-url=${endpoint%/v1}\`、\`spring.ai.openai.api-key=\${OPENAI_API_KEY}\`、\`spring.ai.openai.chat.options.model=${SERVED_MODEL_NAME}\`

### 4.4 TypeScript（\`npm i openai\`）
\`\`\`ts
import OpenAI from "openai";
const client = new OpenAI({ timeout: 600_000 });   // 读取 OPENAI_BASE_URL / OPENAI_API_KEY
const r = await client.chat.completions.create({
  model: "${SERVED_MODEL_NAME}",
  messages: [{ role: "user", content: "总结一下今天的产线异常" }],
  // @ts-expect-error vLLM 扩展参数
  chat_template_kwargs: { enable_thinking: false },
});
console.log(r.choices[0].message.content);
\`\`\`

### 4.5 框架接入
| 框架 | 配置 |
|---|---|
| LangChain | \`ChatOpenAI(model="${SERVED_MODEL_NAME}", base_url=OPENAI_BASE_URL, api_key=OPENAI_API_KEY)\` |
| LiteLLM | \`model: openai/${SERVED_MODEL_NAME}\`，\`api_base: ${endpoint}\`，\`api_key: os.environ/OPENAI_API_KEY\` |
| Dify / Open WebUI | 模型供应商选 “OpenAI-API-compatible”，填 Base URL、API Key、模型名 \`${SERVED_MODEL_NAME}\` |

## 5. 运维

\`\`\`bash
./install.sh            # 菜单：状态 / 重新验证 / 清理
./07-test.sh            # 重新验证（功能 + 压测）
# 轮换 API Key（业务方同步更新后执行）
kubectl -n ${K8S_NAMESPACE} create secret generic vllm-api-key --from-file=key=<(python3 -c 'import secrets;print("sk-"+secrets.token_hex(24),end="")') --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ${K8S_NAMESPACE} rollout restart deploy/vllm
\`\`\`
EOF
  ok "已生成 $out"
}

# 可选：把 API Key 同步到 Secrets Manager（业务系统按 IAM 权限读取）
sync_key_to_secrets_manager() {
  local name="${NAME_PREFIX}/vllm-api-key" tmp
  tmp=$(umask 077; mktemp); trap 'rm -f "$tmp"' RETURN
  kubectl -n "$K8S_NAMESPACE" get secret vllm-api-key -o jsonpath='{.data.key}' | base64 -d > "$tmp"
  if aws secretsmanager describe-secret --secret-id "$name" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --secret-id "$name" --secret-string "file://$tmp" >/dev/null
  else
    aws secretsmanager create-secret --name "$name" --description "vLLM API key (${HP_CLUSTER_NAME})" \
      --secret-string "file://$tmp" --tags Key=Project,Value="$NAME_PREFIX" >/dev/null
  fi
  ok "API Key 已保存到 Secrets Manager: $name"
}
