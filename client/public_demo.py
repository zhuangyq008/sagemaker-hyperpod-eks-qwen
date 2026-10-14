"""公网调用示例：从 Secrets Manager 读取 API Key，经 HTTPS（ALB + WAF）调用模型。

环境变量:
  OPENAI_BASE_URL     例如 https://llm.example.com/v1
  API_KEY_SECRET_ID   Secrets Manager 密钥名，例如 hp-qwen/vllm-api-key
  AWS_REGION          密钥所在区域
  MODEL               模型名，例如 qwen3-30b-a3b
调用方需要 secretsmanager:GetSecretValue 权限（仅限该密钥）。
"""
import os
import sys
import time

import boto3
from openai import OpenAI


def load_api_key(secret_id: str, region: str) -> str:
    resp = boto3.client("secretsmanager", region_name=region).get_secret_value(SecretId=secret_id)
    return resp["SecretString"].strip()


def main() -> None:
    base_url = os.environ.get("OPENAI_BASE_URL", "")
    secret_id = os.environ.get("API_KEY_SECRET_ID", "")
    region = os.environ.get("AWS_REGION", "us-east-1")
    model = os.environ.get("MODEL", "qwen3-30b-a3b")
    if not base_url.startswith("https://") or not secret_id:
        sys.exit("需要设置 OPENAI_BASE_URL（https://...）和 API_KEY_SECRET_ID")

    client = OpenAI(base_url=base_url, api_key=load_api_key(secret_id, region), timeout=600)
    print(f"Endpoint: {base_url} · Model: {model} · Key: Secrets Manager {secret_id}")

    t0 = time.time()
    r = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": "用一句话说明工业设备预测性维护的价值"}],
        max_tokens=256, temperature=0.7, top_p=0.8,
        extra_body={"top_k": 20, "chat_template_kwargs": {"enable_thinking": False}},
    )
    print(f"[非思考 · {time.time() - t0:.2f}s] {r.choices[0].message.content}")

    t0, first = time.time(), None
    print("[流式] ", end="", flush=True)
    for chunk in client.chat.completions.create(
            model=model, stream=True, max_tokens=128,
            messages=[{"role": "user", "content": "列出三个 IoT 数据采集协议"}],
            extra_body={"chat_template_kwargs": {"enable_thinking": False}}):
        if chunk.choices and chunk.choices[0].delta.content:
            first = first or time.time()
            print(chunk.choices[0].delta.content, end="", flush=True)
    print(f"\n[流式 · 首 token {((first or time.time()) - t0) * 1000:.0f} ms]")


if __name__ == "__main__":
    main()
