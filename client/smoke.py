"""冒烟测试：鉴权（无 Key 应 401）+ /v1/models 返回期望的模型名。"""
import os
import sys
import urllib.error
import urllib.request

from _common import MODEL, get_client


def unauthorized_status(base_url: str) -> int:
    try:
        urllib.request.urlopen(f"{base_url}/models", timeout=15)  # noqa: S310 - 地址来自部署输出
        return 200
    except urllib.error.HTTPError as e:
        return e.code


def main() -> None:
    base_url = os.environ["OPENAI_BASE_URL"].rstrip("/")
    code = unauthorized_status(base_url)
    print(f"无 API Key 访问 /models → HTTP {code}", "✔" if code == 401 else "✘ 期望 401")
    models = [m.id for m in get_client().models.list().data]
    print("可用模型:", models, "✔" if MODEL in models else f"✘ 缺少 {MODEL}")
    if code != 401 or MODEL not in models:
        sys.exit(1)


if __name__ == "__main__":
    main()
