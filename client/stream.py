"""流式输出（非思考模式）。"""
from _common import MODEL, NON_THINKING, get_client, sampling


def main() -> None:
    client = get_client()
    stream = client.chat.completions.create(
        model=MODEL,
        stream=True,
        messages=[{"role": "user", "content": "写一段 100 字的工业数据采集平台产品介绍"}],
        max_tokens=512,
        **sampling(NON_THINKING, thinking=False),
    )
    for chunk in stream:
        if chunk.choices and chunk.choices[0].delta.content:
            print(chunk.choices[0].delta.content, end="", flush=True)
    print()


if __name__ == "__main__":
    main()
