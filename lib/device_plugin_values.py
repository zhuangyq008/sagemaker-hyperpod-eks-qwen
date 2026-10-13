"""生成 Helm values 覆盖：在 Chart 默认的 nvidia-device-plugin 机型白名单中追加目标机型。

用法: python3 lib/device_plugin_values.py <chart values.yaml> <instance-type> <output.yaml>
新机型（如 ml.g7.*）还没进 Chart 白名单时，device plugin 不会调度到节点，nvidia.com/gpu 不出现。
"""
import sys

import yaml


def main(values_path: str, instance_type: str, out_path: str) -> None:
    with open(values_path, encoding="utf-8") as f:
        values = yaml.safe_load(f)
    terms = values["nvidia-device-plugin"]["affinity"]["nodeAffinity"][
        "requiredDuringSchedulingIgnoredDuringExecution"]["nodeSelectorTerms"]
    expr = next(e for e in terms[0]["matchExpressions"] if e["key"] == "node.kubernetes.io/instance-type")
    types = list(expr["values"])
    added = instance_type not in types
    new_types = types + [instance_type] if added else types
    override = {"nvidia-device-plugin": {"affinity": {"nodeAffinity": {
        "requiredDuringSchedulingIgnoredDuringExecution": {"nodeSelectorTerms": [{"matchExpressions": [
            {"key": "node.kubernetes.io/instance-type", "operator": "In", "values": new_types}]}]}}}}}
    with open(out_path, "w", encoding="utf-8") as f:
        yaml.safe_dump(override, f, sort_keys=False)
    print(f"{instance_type}: {'已追加到' if added else '已在'} nvidia-device-plugin 白名单（共 {len(new_types)} 个机型）")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
