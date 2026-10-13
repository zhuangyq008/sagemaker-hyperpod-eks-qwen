# 一次性 Job：HF → 节点缓存（/opt/sagemaker/models）→ S3，S3 已有 _SUCCESS 则跳过
apiVersion: batch/v1
kind: Job
metadata:
  name: stage-model
  namespace: ${K8S_NAMESPACE}
  annotations:
    model-id: "${MODEL_ID}"
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels: { app: stage-model }
    spec:
      restartPolicy: Never
      securityContext: { seccompProfile: { type: RuntimeDefault } }
      serviceAccountName: ${MODEL_LOADER_SA}
      priorityClassName: llm-workload
      nodeSelector:
        node.kubernetes.io/instance-type: ${INSTANCE_TYPE}
      volumes:
        - name: models
          hostPath: { path: /opt/sagemaker/models, type: DirectoryOrCreate }
      initContainers:
        - name: hf-download
          image: public.ecr.aws/docker/library/python:3.12-slim
          env:
            - { name: MODEL_ID, value: "${MODEL_ID}" }
            - { name: MODEL_DIR, value: "/models/${MODEL_NAME}" }
            - { name: HF_HUB_ENABLE_HF_TRANSFER, value: "1" }
            - name: HF_TOKEN
              valueFrom: { secretKeyRef: { name: hf-token, key: token, optional: true } }
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail
              if [[ -f "$MODEL_DIR/.complete" ]]; then echo "节点缓存已存在，跳过下载"; exit 0; fi
              pip install -q --no-cache-dir "huggingface_hub[hf_xet]==2.2.0" "hf_transfer==0.1.9"
              hf download "$MODEL_ID" --local-dir "$MODEL_DIR" --max-workers 16
              touch "$MODEL_DIR/.complete"
              du -sh "$MODEL_DIR"
          resources:
            requests: { cpu: "1", memory: 4Gi }
          volumeMounts: [{ name: models, mountPath: /models }]
      containers:
        - name: s3-upload
          image: public.ecr.aws/aws-cli/aws-cli:2.37.13
          env:
            - { name: MODEL_DIR, value: "/models/${MODEL_NAME}" }
            - { name: S3_URI, value: "s3://${S3_BUCKET}/${MODEL_S3_PREFIX}" }
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail
              if aws s3 ls "$S3_URI/_SUCCESS" >/dev/null 2>&1; then echo "S3 已有 _SUCCESS，跳过上传"; exit 0; fi
              aws configure set default.s3.max_concurrent_requests 32
              aws s3 sync "$MODEL_DIR/" "$S3_URI/" --exclude ".cache/*" --exclude ".complete" --only-show-errors
              date -u +%FT%TZ | aws s3 cp - "$S3_URI/_SUCCESS"
              aws s3 ls "$S3_URI/" --summarize --human-readable | tail -2
          resources:
            requests: { cpu: 500m, memory: 1Gi }
          volumeMounts: [{ name: models, mountPath: /models, readOnly: true }]
