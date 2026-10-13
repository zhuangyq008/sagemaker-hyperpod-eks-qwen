"""按显式变量列表渲染模板中的 ${VAR}（替代 envsubst，CloudShell 无需安装 gettext）。

用法: python3 lib/render.py <模板文件> VAR1 VAR2 ...
只替换列出的变量，其余 ${...} / $(...) 原样保留；列出的变量未设置时报错退出。
"""
import os
import re
import sys

PATTERN = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def render(text: str, names: set) -> str:
    missing = sorted(n for n in names if n not in os.environ)
    if missing:
        sys.exit(f"render: 以下变量未设置: {', '.join(missing)}")
    return PATTERN.sub(lambda m: os.environ[m.group(1)] if m.group(1) in names else m.group(0), text)


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    with open(sys.argv[1], encoding="utf-8") as f:
        sys.stdout.write(render(f.read(), set(sys.argv[2:])))


if __name__ == "__main__":
    main()
