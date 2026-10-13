"""同步调用：思考模式（默认）与非思考模式。"""
from _common import MODEL, NON_THINKING, THINKING_GENERAL, get_client, sampling


def main() -> None:
    client = get_client()

    r = client.chat.completions.create(
        model=MODEL,
        messages=[{"role": "user", "content": "一台 g5.12xlarge 能否部署 70B 模型？请简要分析"}],
        max_tokens=4096,
        **sampling(THINKING_GENERAL, thinking=True),
    )
    msg = r.choices[0].message
    reasoning = getattr(msg, "reasoning_content", None) or getattr(msg, "reasoning", None)
    print("=== 思考模式 ===")
    print("思考过程:", (reasoning or "")[:500], "..." if reasoning and len(reasoning) > 500 else "")
    print("回答:", msg.content)
    print("usage:", r.usage)

    r = client.chat.completions.create(
        model=MODEL,
        messages=[{"role": "user", "content": "把这句话翻译成英文：数据留在新加坡"}],
        max_tokens=512,
        **sampling(NON_THINKING, thinking=False),
    )
    print("\n=== 非思考模式 ===")
    print(r.choices[0].message.content)


if __name__ == "__main__":
    main()
