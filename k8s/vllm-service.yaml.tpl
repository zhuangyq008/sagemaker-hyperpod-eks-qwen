apiVersion: v1
kind: Service
metadata:
  name: vllm
  namespace: ${K8S_NAMESPACE}
  labels: { app: vllm }
spec:
  type: ClusterIP
  selector: { app: vllm }
  ports:
    - { name: http, port: 8000, targetPort: http }
