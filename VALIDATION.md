# 验证记录 —— 2026-10-13 · us-east-1

## 1. 结论

| 项目 | 结果 |
|---|---|
| 实际部署 | **Qwen/Qwen3-30B-A3B-GPTQ-Int4** · 1 × **ml.g5.2xlarge**（1 × A10G 24 GB）· use1-az6 · vLLM 0.31.0（AWS DLC） |
| 原规划 | Qwen3.6-35B-A3B BF16 · ml.g5.12xlarge，**没有执行**：use1-az6 和 use1-az1 都报容量不足 |
| 备选 1 | Qwen3.6-35B-A3B-FP8 · ml.g6e.xlarge，**没有执行**：use1-az6 和 use1-az1 都报容量不足 |
| 备选 2 | Qwen3.6-35B-A3B-FP8 · ml.g7.12xlarge（TP=2），**等待配额**：已申请配额；方案见 `presets/2-qwen3.6-35b-fp8-g7.env` |
| 功能 | ✅ `/v1/models`、无 API Key 返回 401、思考模式（`reasoning_content` 单独返回）、非思考模式、流式、工具调用（含回填结果） |
| 压测 | ✅ 1/4/8 并发全部成功，见第 3 节 |
| 生产链路 | ✅ `install.sh deploy --yes` 全流程回归：系统节点组（t3.large）+ AWS Load Balancer Controller + **内网 NLB（IP 模式）**；从 VPC 内经 NLB 调用：401 鉴权、模型列表、思考/非思考、流式、工具调用全部通过；API Key 已同步到 Secrets Manager |
| 向导 | ✅ 交互式配置（默认值路径）、断点续跑、非交互模式失败即停止 |

## 2. 环境

| 组件 | 版本 / 值 |
|---|---|
| EKS | 1.35（节点 v1.35.2-eks），认证模式 API |
| HyperPod Helm Chart | sagemaker-hyperpod-cli @ `89b6a52`，Helm v3.22.0 |
| GPU 驱动 | 595.91.07（CUDA 13.2），满足 DLC 对 CUDA 13.0 的要求 |
| vLLM 参数 | TP=1，`max-model-len 16384`，`gpu-memory-utilization 0.92`，`max-num-seqs 8`，`--reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser hermes` |
| 显存 | 权重 15.68 GiB；KV Cache 3.73 GiB，即 **40,752 tokens**（16K 上下文下约 2.5 路满长度并发） |
| 耗时 | 拿到节点后约 3 分钟 Ready；HF 下载 16 GB 用时 50 秒；HF→S3 Job 共 7.5 分钟；vLLM 加载 79 秒，加编译和 CUDA Graph 共约 3 分钟 |

## 3. 压测（`vllm bench serve`，在 Pod 内执行，随机输入 1024 / 输出 256 tokens）

| 并发 | 请求数 | 吞吐（req/s） | 输出吞吐（tok/s） | TTFT 均值 / P99（ms） | TPOT 均值 / P99（ms） | E2E 均值（ms） |
|---|---|---|---|---|---|---|
| 1 | 16 | 0.47 | 119.9 | 170 / 173 | 7.7 / 7.7 | 2,134 |
| 4 | 32 | 1.15 | 293.9 | 225 / 564 | 12.8 / 14.2 | 3,482 |
| 8 | 64 | 1.67 | 426.9 | 389 / 1,162 | 17.3 / 20.3 | 4,793 |

## 4. 过程中发现的问题与处理（已反映到脚本中）

| # | 问题 | 处理 |
|---|---|---|
| 1 | g5.12xlarge 和 g6e.xlarge 在多个 AZ 报 `InsufficientCapacity`（HyperPod 每 3–4 分钟自动重试） | 新增 `04b-capacity-race.sh`：在「机型 × AZ」组合上并行申请，拿到第一台后把其余实例组缩到 0，并把获胜机型写回 config；CFN 新增 `EXTRA_AZ_IDS` 子网。这次第一轮就拿到了 g5.2xlarge |
| 2 | Helm 4 默认 server-side apply，与 Chart 里的 aggregated ClusterRole 冲突 | 工具链固定为 Helm 3 |
| 3 | 还没有节点时 `helm --wait` 一直卡住（operator Pod Pending） | 去掉 `--wait` |
| 4 | Chart 的 nvidia-device-plugin 机型白名单不含 `ml.g7.*` | 03 自动把 `INSTANCE_TYPE` 加进白名单（`lib/device_plugin_values.py`） |
| 5 | **g5.2xlarge 节点 maxPods=14**，系统组件加训练 operator 把槽位占满（“Too many pods”） | 可配置关闭训练 operator（`HYPERPOD_TRAINING_OPERATORS=false`），coredns 副本数可配置（`COREDNS_REPLICAS=1`）；新增 PriorityClass `llm-workload`（不抢占）让推理负载优先调度 |
| 6 | Service 名为 `vllm`，K8s 自动注入 `VLLM_PORT=tcp://…`，与 vLLM 的环境变量冲突，导致 EngineCore 启动失败 | Pod 设置 `enableServiceLinks: false` |
| 7 | Service Quotas API 限流 | AWS CLI 改为 `AWS_RETRY_MODE=adaptive` |
| 9 | NLB 注册 IP 目标约需 3–5 分钟，测试开始太早会失败 | 06 等待目标 healthy 后才算完成 |
| 10 | GPU 已被 vLLM 占用时，重新运行 nvidia-smi 检查的 Pod 一直 Pending | 改为复用 vLLM 容器执行 nvidia-smi |
| 11 | envsubst 会把列出变量的 `$VAR` 写法也展开（误改容器内脚本） | 改用 `lib/render.py`，只替换 `${VAR}`；CloudShell 也不再需要 gettext |
| 8 | 集群里出现 `amazon-sagemaker-hyperpod-observability` addon（04:54 创建，**不是本工具安装的**），在单节点上占 5 个 Pod | 未改动；小机型上建议评估是否需要 |

## 5. 公网入口与 NVMe 模型缓存（2026-10-14）

### 5.1 公网 HTTPS 入口 `https://llm.<your-domain>/v1`
- 架构：Route 53 Alias → internet-facing ALB（只有 HTTPS 443，TLS 1.3/1.2 策略）→ vLLM Pod（IP 模式）
- 证书：ACM 自动申请，Route 53 DNS 自动验证（`cfn/edge.yaml`，栈 `hp-qwen-edge`）
- WAF `hp-qwen-llm-api`：只放行 `/v1/*`，每 IP 每 5 分钟 300 次限流，AWS IP 信誉 / 已知恶意输入 / 通用规则集（`SizeRestrictions_BODY`、`CrossSiteScripting_BODY` 改为 Count，避免误拦长 prompt）
- API Key：K8s Secret → Secrets Manager `hp-qwen/vllm-api-key`；`client/public_demo.py` 用 boto3 读取后调用

| 安全边界检查 | 结果 |
|---|---|
| `/v1/models` 不带 Key | 401 ✅ |
| `/metrics` `/health` `/tokenize` `/docs` `/pause`（vLLM 不鉴权的管理接口） | 403（WAF）✅；ALB 也只转发 `/v1` |
| HTTP :80 | 连接失败（没有 80 监听）✅ |
| 用 ALB 原始 DNS 访问 | 404（Host 不匹配）✅ |
| 证书 | `CN=<your-domain>`，校验通过 ✅ |

功能测试（经公网 HTTPS）：鉴权、模型列表、思考/非思考、流式、工具调用、curl 全部通过；`public_demo.py`（Key 来自 Secrets Manager）非思考请求 0.29–0.36 s，流式首 token 62–117 ms（调用方 EC2 与服务同区域）。

### 5.2 NVMe 实例存储 vs EBS（ml.g5.2xlarge，每次测试前清空页缓存）

| 指标 | EBS `/opt/sagemaker`（XFS） | NVMe `/opt/dlami/nvme`（EXT4） |
|---|---|---|
| 裸顺序读（dd，16 GB 单文件） | 266 MB/s | **333 MB/s**（+25%） |
| vLLM 权重加载（15.68 GiB） | 80.9 s | **68.3 s**（−16%） |
| S3 → 节点同步 15.8 GiB | — | 94 s（约 172 MiB/s） |

结论：
- g5.2xlarge 的实例存储只有 450 GB，性能提升有限；大机型（g5.12xlarge 3.8 TB、p5 8 × 3.84 TB）的 NVMe 带宽高得多，收益会更明显
- 实例存储不额外计费；节点被替换后数据会丢，但会由 initContainer 自动从 S3 重新同步
- 默认 `MODEL_CACHE_DIR=auto`：机型有实例存储时用 NVMe，否则用 EBS

## 6. 当前计费资源

- HyperPod：1 × ml.g5.2xlarge（实例组 `q3-g52xl-use1-az6`）。其它实例组目标台数都是 0
- EKS 系统节点组：1 × t3.large；**公网 ALB** 1 个 + WAF `hp-qwen-llm-api`（Web ACL 加规则按月计费，另按请求数收费）；ACM 证书（免费）；Route 53 记录 `llm.<your-domain>`；Secrets Manager：`hp-qwen/vllm-api-key`
- EKS 控制面、NAT Gateway、S3（`models/Qwen3-30B-A3B-GPTQ-Int4`，15.8 GiB）
- 停用：`./99-cleanup.sh`（S3 保留）
