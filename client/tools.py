"""工具调用（Function Calling）：模型发起调用 → 本地执行 → 回填结果 → 模型给出最终回答。"""
import json

from _common import MODEL, NON_THINKING, get_client, sampling

TOOLS = [{
    "type": "function",
    "function": {
        "name": "get_device_status",
        "description": "查询数据采集设备的在线状态",
        "parameters": {
            "type": "object",
            "properties": {"device_id": {"type": "string", "description": "设备编号，如 SG-001"}},
            "required": ["device_id"],
        },
    },
}]


def get_device_status(device_id: str) -> dict:
    """模拟设备状态查询；实际场景替换为 IoT Core / SiteWise 查询。"""
    return {"device_id": device_id, "online": True, "last_seen": "2026-10-13T08:00:00Z"}


def main() -> None:
    client = get_client()
    messages = [{"role": "user", "content": "设备 SG-001 现在在线吗？"}]
    params = sampling(NON_THINKING, thinking=False)

    r = client.chat.completions.create(model=MODEL, messages=messages, tools=TOOLS, tool_choice="auto", **params)
    msg = r.choices[0].message
    if not msg.tool_calls:
        raise SystemExit(f"模型没有发起工具调用: {msg.content}")
    print("tool_calls:", [(c.function.name, c.function.arguments) for c in msg.tool_calls])

    messages.append(msg.model_dump(exclude_none=True))
    for call in msg.tool_calls:
        result = get_device_status(**json.loads(call.function.arguments))
        messages.append({"role": "tool", "tool_call_id": call.id, "content": json.dumps(result, ensure_ascii=False)})

    r = client.chat.completions.create(model=MODEL, messages=messages, tools=TOOLS, **params)
    print("最终回答:", r.choices[0].message.content)


if __name__ == "__main__":
    main()
