# SageMaker HyperPod（EKS 编排）· vLLM 大模型推理部署工具

在 SageMaker HyperPod（EKS 编排）上用 vLLM 部署开源大模型，提供 **OpenAI 兼容 API**。
用 **AWS CloudShell** 运行交互式向导即可完成部署：环境检查 → 工具安装 → 方案选择（实时检查配额和供应）→ 部署 → 端到端验证 → 输出客户端接入指引。

- 已验证：us-east-1 · Qwen3-30B-A3B-GPTQ-Int4 · ml.g5.2xlarge · **经内网 NLB 生产链路**调用通过（见 [VALIDATION.md](VALIDATION.md)）
- 方案预设见 `presets/`，实测记录见 `VALIDATION.md`

## 1. 快速开始（CloudShell）

```bash
# 在目标区域打开 AWS CloudShell，上传或拉取本目录后：
cd hyperpod-eks-llm
./install.sh
```

菜单：

| 选项 | 作用 |
|---|---|
| 1 部署 | 新建，或**从中断处继续**（CloudShell 断开后重新打开，再选这一项） |
| 2 查看状态 | 栈、EKS、HyperPod 实例组和节点、vLLM、服务地址、已完成的步骤 |
| 3 重新验证 | 经服务入口做功能测试，可选压测 |
| 4 生成客户端接入指引 | 生成 `CLIENT_GUIDE.md`；可选把 API Key 同步到 Secrets Manager |
| 5 清理资源 | 按相反顺序删除，S3 模型默认保留 |

也可以直接运行子命令：`./install.sh deploy | status | verify | guide | cleanup`。非交互模式需要已有 `config.env`：`./install.sh deploy --yes`。

### 向导会检查和处理的内容

| 阶段 | 内容 |
|---|---|
| 运行环境 | 是否在 CloudShell、身份、架构、`$HOME` 剩余空间；缺少的 aws v2 / kubectl / helm3 / jq / PyYAML **装到 `~/.local/bin`，不需要 sudo**，跨会话保留 |
| 方案与资源 | 列出 `presets/` 中的方案，实时显示每个机型的 **HyperPod 配额**和**各 AZ 供应**；配额为 0 时可以直接提交配额申请 |
| 网络 | 按机型供应自动选 AZ（排除 EKS 不支持的 AZ）；建议一个不和现有 VPC 冲突的 /16；**新建时 VPC/IGW 配额已满会直接报错** |
| 访问方式 | internal-nlb / alb / port-forward；自动列出本区域的 ACM 证书和 WAF Web ACL 供选择 |
| 部署 | 每一步都可以重复执行，有日志（`.state/logs/`），失败后可选重试 / 跳过 / 退出；HyperPod 容量不足时自动在「机型 × AZ」之间竞速申请 |
| 验证 | 经服务入口测试：无 Key 返回 401、模型列表、思考和非思考模式、流式、工具调用；可选 `vllm bench` 1/4/8 并发 |
| 交付 | `CLIENT_GUIDE.md`：接入参数、网络说明、推荐参数，以及 curl / Python / Java / TypeScript / LangChain / LiteLLM / Dify 示例 |

> CloudShell 注意事项：
> - 空闲 20–30 分钟会断开。CFN 和 HyperPod 在服务端会继续运行，重新执行 `./install.sh` → 部署，就能从断点继续。
> - 每个会话的出口 IP 都不同。`EKS_PUBLIC_ACCESS_CIDRS=auto` 时，脚本会在连不上 EKS API 时**把当前 IP 追加进白名单**（交互模式下会先确认）。

## 2. 生产访问方式

| `EXPOSE_MODE` | 适用场景 | 能力 |
|---|---|---|
| **`internal-nlb`**（默认） | 业务系统在同一 VPC，或通过 TGW / Direct Connect / 对等连接接入 | 内网 NLB，IP 模式直连 Pod；`NLB_SOURCE_RANGES` 来源白名单；可选 `NLB_ACM_CERT_ARN`（443/TLS 1.3） |
| **`alb`** | 需要 HTTPS / 域名 / WAF；`ALB_SCHEME=internal` 或 `internet-facing` | ACM 证书、TLS 1.2+；`ALB_INBOUND_CIDRS` 来源白名单；`ALB_WAF_ACL_ARN`；空闲超时 900 秒（流式和思考模式需要）；可选 Route 53 Alias |
| `port-forward` | 仅调试 | 只能在运维终端访问 |

公网示例（已验证）：`ALB_SCHEME=internet-facing`、`DOMAIN_NAME=llm.example.com`、`ROUTE53_ZONE_ID=Z...`、`ALB_ACM_CERT_ARN=auto`、`ALB_WAF_ACL_ARN=auto`、`ALB_INBOUND_CIDRS=0.0.0.0/0`。
脚本会自动申请证书（DNS 验证）、创建专用 WAF、写入 Route 53 记录，并把 API Key 同步到 Secrets Manager。公网调用示例见 `client/public_demo.py`。

安全约束（脚本会强制检查）：
- internet-facing ALB **必须配置证书和 `DOMAIN_NAME`**；只转发 `/v1`（vLLM 只对 `/v1` 做 API Key 鉴权，`/metrics`、`/tokenize`、`/pause` 等管理接口不鉴权，**绝不能暴露**），其它路径返回 404；自动创建的 WAF 也只放行 `/v1/*`；
- 来源放开 `0.0.0.0/0` 时**必须挂本区域、本账号且实际存在的 WAF ACL**；
- CIDR 会做格式和范围校验；
- 没有配置 TLS 时会提示 API Key 以明文在内网传输。

为什么需要**系统节点组**（`SYSTEM_NODE_TYPE`，默认 t3.large × 1，生产建议 2）：
- HyperPod 节点的 EC2 实例不在客户账号内，NLB/ALB 只能用 IP 模式直连 Pod，所以必须运行 AWS Load Balancer Controller；
- 小 GPU 机型的 maxPods 很低（g5.2xlarge 只有 14），控制器和 CoreDNS 放在系统节点上，GPU 节点只跑推理。

## 3. 架构

```
业务系统（VPC / TGW / DX）──▶ 内网 NLB 或 ALB（HTTPS/WAF）──▶ vLLM Pod（HyperPod GPU 节点）
                                     ▲ AWS Load Balancer Controller（系统节点组）
CloudShell / 运维机 ──(EKS API，白名单)──▶ EKS 1.35 ──▶ HyperPod 集群（实例组按「机型 × AZ」竞速）
VPC: 私有子网 ×5（多 AZ，容量竞速）· 公有子网 ×2（NAT / internet-facing ALB）· S3 Gateway Endpoint
S3: sagemaker-hyperpod-<acct>-<region>/{lifecycle,models}/ · Secrets Manager: <prefix>/vllm-api-key
```

## 4. 目录

| 文件 | 作用 |
|---|---|
| **`install.sh`** | 交互式向导（入口） |
| `presets/*.env` | 部署方案（模型 × 机型 × vLLM 参数）；复制一份即可新增方案 |
| `config.env.example` | 全部参数和说明；向导生成 `config.env` |
| `00-install-tools.sh` | 用户级安装工具（含校验） |
| `01-preflight.sh` | 身份、区域、配额、VPC/IGW/EIP、机型供应、EKS 版本、DLC 镜像 |
| `02-infra.sh` + `cfn/infra.yaml` | VPC、NAT、子网、SG、EKS、系统节点组、IAM、S3、Pod Identity |
| `03-eks-bootstrap.sh` | Access Entry、CoreDNS、HyperPod Helm Chart（device plugin 白名单自动补充新机型）、PriorityClass |
| `04-hyperpod-cluster.sh` | 创建集群（`--create-only`）/ 等待节点并检查 GPU 和驱动（`--wait-nodes`） |
| `04b-capacity-race.sh` | 在「机型 × AZ」之间竞速申请容量，拿到 1 台后其余缩到 0，并把获胜机型写回 config |
| `05-stage-model.sh` | HF → 节点 → S3（幂等，可续跑）；节点缓存默认放 NVMe 实例存储（`MODEL_CACHE_DIR=auto`） |
| `cfn/edge.yaml` | 公网入口：ACM 证书（DNS 自动验证）+ 专用 WAF（`/v1` 白名单、限流、托管规则） |
| `06-deploy-vllm.sh` + `lib/expose.sh` | vLLM，以及 NLB/ALB 入口（等待目标健康后才算完成） |
| `07-test.sh` | 经入口做端到端测试；运维终端访问不到内网 LB 时，自动在 VPC 内的 vLLM Pod 中测试 |
| `client/` | `smoke.py`、`chat.py`、`stream.py`、`tools.py`、`curl_examples.sh` |
| `99-cleanup.sh` | 清理（LB → Secrets Manager → HyperPod → Helm → CFN；S3 可选） |

## 5. 排障

| 现象 | 处理 |
|---|---|
| 实例组 `CurrentCount` 一直为 0，事件中有 `insufficient capacity` | 04b 会自动竞速；也可以换方案（`presets/1` 最容易拿到容量），或改区域 |
| 方案显示“配额 0” | 向导里可以直接提交申请；审批后重新运行 |
| `Too many pods` | 确认系统节点组存在；小机型设置 `HYPERPOD_TRAINING_OPERATORS=false` |
| vLLM OOM | 降低 `MAX_MODEL_LEN` / `MAX_NUM_SEQS` → `VLLM_EXTRA_ARGS` 加 `--enforce-eager` → 换量化版本 |
| LB 目标一直 unhealthy | `kubectl -n llm describe svc,ingress vllm`；检查 Pod 是否就绪、`NLB_SOURCE_RANGES` |
| kubectl 超时 | 白名单会自动追加当前 IP；仍然不行时检查 `EKS_PUBLIC_ACCESS_CIDRS` 和网络代理 |

## 6. 安全

- EKS：认证模式 API；公网端点只放通白名单
- 模型加载：Pod Identity，只能读写 `S3_BUCKET/models/*`
- API Key：存放在 K8s Secret，通过环境变量注入 vLLM，不进入进程参数；可以同步到 Secrets Manager；轮换方法见 `CLIENT_GUIDE.md`
- S3：阻止公开访问、SSE、仅允许 TLS
- 供应链：Helm Chart 固定到 commit，LBC chart 固定版本，LBC IAM policy 有 sha256 校验
- 生产建议：入口使用 TLS；EKS Secrets 启用 KMS 加密；系统节点 ≥ 2

## 7. 费用

- 固定开销：EKS 控制面 0.10 美元/小时、NAT 约 0.045 美元/小时、系统节点（t3.large 约 0.083 美元/小时/台）、LB（NLB/ALB 按小时加 LCU）
- GPU：按所选机型的 SageMaker HyperPod 单价计费（https://aws.amazon.com/sagemaker/pricing/）
- **不用时执行 `./install.sh cleanup`**
