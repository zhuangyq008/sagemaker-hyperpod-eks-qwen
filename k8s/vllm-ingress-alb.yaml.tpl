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
    alb.ingress.kubernetes.io/actions.default-404: '{"type":"fixed-response","fixedResponseConfig":{"contentType":"text/plain","statusCode":"404","messageBody":"not found"}}'
${ALB_EXTRA_ANNOTATIONS}
spec:
  ingressClassName: alb
  defaultBackend:
    service: { name: default-404, port: { name: use-annotation } }
  rules:
    - ${ALB_HOST_LINE}
      http:
        # 只转发 /v1（vLLM 仅对 /v1 前缀做 API Key 鉴权；/metrics、/tokenize、/pause 等管理接口不鉴权，不能暴露）
        # 其它路径由 ALB 直接返回 404；健康检查直连 Pod /health，不经过监听规则
        paths:
          - path: /v1
            pathType: Prefix
            backend:
              service: { name: vllm, port: { number: 8000 } }
