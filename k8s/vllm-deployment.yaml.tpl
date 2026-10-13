apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm
  namespace: ${K8S_NAMESPACE}
  labels: { app: vllm }
spec:
  replicas: 1
  # 单节点 GPU 数 = TP_SIZE，滚动更新会因为 GPU 不足卡住，所以先删后建
  strategy: { type: Recreate }
  selector:
    matchLabels: { app: vllm }
  template:
    metadata:
      labels: { app: vllm }
    spec:
      serviceAccountName: ${MODEL_LOADER_SA}
      priorityClassName: llm-workload
      # Service 名为 vllm 时 K8s 会注入 VLLM_PORT=tcp://... 等变量，与 vLLM 自身的环境变量冲突
      enableServiceLinks: false
      nodeSelector:
        node.kubernetes.io/instance-type: ${INSTANCE_TYPE}
      terminationGracePeriodSeconds: 60
      securityContext: { seccompProfile: { type: RuntimeDefault } }
      volumes:
        - name: models
          hostPath: { path: /opt/sagemaker/models, type: DirectoryOrCreate }
        - name: dshm
          emptyDir: { medium: Memory, sizeLimit: ${SHM_SIZE} }
      initContainers:
        - name: model-sync
          image: public.ecr.aws/aws-cli/aws-cli:2.37.13
          env:
            - { name: MODEL_SOURCE, value: "${MODEL_SOURCE}" }
            - { name: MODEL_DIR, value: "/models/${MODEL_NAME}" }
            - { name: S3_URI, value: "s3://${S3_BUCKET}/${MODEL_S3_PREFIX}" }
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail
              if [[ "$MODEL_SOURCE" != "s3" ]]; then echo "MODEL_SOURCE=$MODEL_SOURCE，跳过 S3 同步"; exit 0; fi
              if [[ -f "$MODEL_DIR/.complete" ]]; then echo "节点缓存已存在: $MODEL_DIR"; exit 0; fi
              aws s3 ls "$S3_URI/_SUCCESS" >/dev/null || { echo "S3 上没有 _SUCCESS，请先执行 05-stage-model.sh"; exit 1; }
              aws configure set default.s3.max_concurrent_requests 32
              aws s3 sync "$S3_URI/" "$MODEL_DIR/" --exclude "_SUCCESS" --only-show-errors
              touch "$MODEL_DIR/.complete"
          resources:
            requests: { cpu: 500m, memory: 1Gi }
          volumeMounts: [{ name: models, mountPath: /models }]
      containers:
        - name: vllm
          image: ${VLLM_IMAGE}
          # API Key 通过环境变量 VLLM_API_KEY 生效（不放进进程参数，避免 /proc/*/cmdline 泄露）
          command: ["/bin/bash", "-c"]
          args:
            - |
              exec vllm serve ${MODEL_PATH} \
                --served-model-name ${SERVED_MODEL_NAME} \
                --tensor-parallel-size ${TP_SIZE} \
                --max-model-len ${MAX_MODEL_LEN} \
                --gpu-memory-utilization ${GPU_MEM_UTIL} \
                --max-num-seqs ${MAX_NUM_SEQS} \
                --host 0.0.0.0 --port 8000 \
                ${VLLM_EXTRA_ARGS}
          env:
            - name: VLLM_API_KEY
              valueFrom: { secretKeyRef: { name: vllm-api-key, key: key } }
            - name: HF_TOKEN
              valueFrom: { secretKeyRef: { name: hf-token, key: token, optional: true } }
            - { name: HF_HOME, value: /models/hf-cache }
          securityContext: { allowPrivilegeEscalation: false }
          ports:
            - { name: http, containerPort: 8000 }
          resources:
            requests: { cpu: "${VLLM_CPU_REQUEST}", memory: ${VLLM_MEM_REQUEST}, nvidia.com/gpu: "${TP_SIZE}" }
            limits: { memory: ${VLLM_MEM_LIMIT}, nvidia.com/gpu: "${TP_SIZE}" }
          volumeMounts:
            - { name: models, mountPath: /models, readOnly: ${MODELS_READONLY} }
            - { name: dshm, mountPath: /dev/shm }
          # 加载 + torch.compile + CUDA Graph 捕获耗时较长，startupProbe 最长等 30 分钟
          startupProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 10
            failureThreshold: 180
          readinessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 20
            failureThreshold: 6
