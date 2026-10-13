# ALB（AWS Load Balancer Controller，IP 模式直连 Pod）：HTTPS / WAF / 来源 CIDR / 长连接超时（流式输出）
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vllm
  namespace: ${K8S_NAMESPACE}
  labels: { app: vllm }
  annotations:
    alb.ingress.kubernetes.io/scheme: ${ALB_SCHEME}
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/inbound-cidrs: ${ALB_INBOUND_CIDRS}
    alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=${ALB_IDLE_TIMEOUT},routing.http.drop_invalid_header_fields.enabled=true
    alb.ingress.kubernetes.io/target-group-attributes: deregistration_delay.timeout_seconds=30
    alb.ingress.kubernetes.io/tags: Project=${NAME_PREFIX}
${ALB_EXTRA_ANNOTATIONS}
spec:
  ingressClassName: alb
  rules:
    - ${ALB_HOST_LINE}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: vllm, port: { number: 8000 } }
