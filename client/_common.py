"""客户端公共配置：从环境变量读取 OPENAI_BASE_URL / OPENAI_API_KEY / MODEL。"""
import os
import sys

from openai import OpenAI

MODEL = os.environ.get("MODEL", "qwen3.6-35b-a3b")

# 推荐采样参数（来自模型卡）
THINKING_GENERAL = {"temperature": 1.0, "top_p": 0.95, "presence_penalty": 1.5, "top_k": 20}
THINKING_CODING = {"temperature": 0.6, "top_p": 0.95, "presence_penalty": 0.0, "top_k": 20}
NON_THINKING = {"temperature": 0.7, "top_p": 0.8, "presence_penalty": 1.5, "top_k": 20}


def get_client() -> OpenAI:
    missing = [k for k in ("OPENAI_BASE_URL", "OPENAI_API_KEY") if not os.environ.get(k)]
    if missing:
        sys.exit(f"缺少环境变量: {', '.join(missing)}（见 README 第 5 节）")
    return OpenAI(timeout=600)


def sampling(params: dict, thinking: bool) -> dict:
    """把采样参数拆成 OpenAI SDK 标准参数和 extra_body（top_k、chat_template_kwargs）。"""
    std = {k: v for k, v in params.items() if k != "top_k"}
    extra = {"top_k": params["top_k"]}
    if not thinking:
        extra["chat_template_kwargs"] = {"enable_thinking": False}
    return {**std, "extra_body": extra}
