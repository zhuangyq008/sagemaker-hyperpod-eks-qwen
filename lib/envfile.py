"""env 配置文件工具：在保留注释和顺序的前提下设置 KEY=VALUE，或读取 preset 元数据。

用法:
  python3 lib/envfile.py set <file> KEY=VALUE [KEY=VALUE ...]   # 不存在的 KEY 追加到文件末尾
  python3 lib/envfile.py apply <file> <preset.env>              # 把 preset 中的 KEY=VALUE 写入 file
  python3 lib/envfile.py meta <preset.env> <TITLE|DESC|VERIFIED>
"""
import re
import shlex
import sys

LINE = re.compile(r"^([A-Z][A-Z0-9_]*)=")


def quote(value: str) -> str:
    """含空格等特殊字符时加双引号（值已经过白名单校验，不含双引号以外的危险字符）。"""
    if re.search(r"[$`\\]", value.strip('"')):
        sys.exit(f"envfile: 值中不允许出现 $、反引号或反斜杠: {value!r}")
    if value.startswith('"') and value.endswith('"'):
        return value
    return f'"{value}"' if re.search(r"[\s#$`'\\]", value) else value


def parse_pairs(items):
    pairs = {}
    for item in items:
        key, sep, value = item.partition("=")
        if not sep or not LINE.match(item):
            sys.exit(f"envfile: 非法参数 {item!r}")
        pairs[key] = value
    return pairs


def set_values(path: str, pairs: dict) -> None:
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    pending = dict(pairs)
    out = []
    for line in lines:
        m = LINE.match(line)
        if m and m.group(1) in pending:
            key = m.group(1)
            comment = ""
            rest = line[len(key) + 1:]
            if not rest.startswith('"') and "#" in rest:   # 保留行内注释
                comment = "  #" + rest.split("#", 1)[1]
            out.append(f"{key}={quote(pending.pop(key))}{comment}")
        else:
            out.append(line)
    out.extend(f"{k}={quote(v)}" for k, v in pending.items())
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")


def preset_pairs(preset: str) -> dict:
    pairs = {}
    with open(preset, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if LINE.match(line):
                key, _, value = line.partition("=")
                pairs[key] = " ".join(shlex.split(value)) if value else ""
    return pairs


def meta(preset: str, field: str) -> str:
    with open(preset, encoding="utf-8") as f:
        for line in f:
            if line.startswith(f"# {field}:"):
                return line.split(":", 1)[1].strip()
    return ""


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    if cmd == "set":
        set_values(sys.argv[2], parse_pairs(sys.argv[3:]))
    elif cmd == "apply":
        set_values(sys.argv[2], preset_pairs(sys.argv[3]))
    elif cmd == "meta":
        print(meta(sys.argv[2], sys.argv[3]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
