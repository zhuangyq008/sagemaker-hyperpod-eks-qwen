# 内网 NLB（AWS Load Balancer Controller，IP 模式直连 Pod），只允许 NLB_SOURCE_RANGES 访问
apiVersion: v1
kind: Service
metadata:
  name: vllm
  namespace: ${K8S_NAMESPACE}
  labels: { app: vllm }
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: /health
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: HTTP
    service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: preserve_client_ip.enabled=false,deregistration_delay.timeout_seconds=30
${NLB_EXTRA_ANNOTATIONS}
spec:
  type: LoadBalancer
  selector: { app: vllm }
  loadBalancerSourceRanges: [${NLB_SOURCE_RANGES_YAML}]
  ports:
    - { name: http, port: ${NLB_PORT}, targetPort: http }
