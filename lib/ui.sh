#!/usr/bin/env bash
# 交互组件：标题 / 提问 / 确认 / 单选；ASSUME_YES=true 时全部取默认值（非交互模式）
ASSUME_YES="${ASSUME_YES:-false}"

if [[ -t 1 ]]; then C_B=$'\033[1m'; C_C=$'\033[1;36m'; C_D=$'\033[2m'; C_0=$'\033[0m'; else C_B=; C_C=; C_D=; C_0=; fi

ui_banner() {
  printf '\n%s══════════════════════════════════════════════════════════════════%s\n' "$C_C" "$C_0"
  printf '%s  %s%s\n' "$C_C" "$1" "$C_0"
  printf '%s══════════════════════════════════════════════════════════════════%s\n' "$C_C" "$C_0"
}
ui_title() { printf '\n%s━━ %s ━━%s\n' "$C_C" "$*" "$C_0"; }
ui_note()  { printf '%s  %s%s\n' "$C_D" "$*" "$C_0"; }

# ask <变量名> <提示> [默认值] [校验正则]
ask() {
  local __name="$1" __prompt="$2" __def="${3:-}" __re="${4:-}" __v
  while true; do
    if $ASSUME_YES; then __v="$__def"
    else read -r -p "  ${__prompt}${__def:+ [${__def}]}: " __v || exit 1; __v="${__v:-$__def}"; fi
    if [[ -z "$__re" || "$__v" =~ $__re ]]; then printf -v "$__name" '%s' "$__v"; return 0; fi
    $ASSUME_YES && die "默认值不合法: $__prompt = $__v"
    warn "格式不正确，请重新输入"
  done
}

# confirm <提示> [默认 y|n]；返回 0 表示“是”
confirm() {
  local __a __d="${2:-y}"
  if $ASSUME_YES; then [[ "$__d" == y ]]; return; fi
  read -r -p "  $1 [$([[ $__d == y ]] && echo Y/n || echo y/N)]: " __a || exit 1
  [[ "${__a:-$__d}" =~ ^[Yy] ]]
}

# choose <变量名> <提示> <默认序号> <选项1> <选项2> ...；变量得到 1 起的序号
choose() {
  local __name="$1" __prompt="$2" __def="$3" __i __v; shift 3
  echo "  ${C_B}${__prompt}${C_0}"
  for __i in $(seq 1 $#); do printf '    %s%2d)%s %s\n' "$C_B" "$__i" "$C_0" "${!__i}"; done
  while true; do
    if $ASSUME_YES; then __v="$__def"; else read -r -p "  请选择 [${__def}]: " __v || exit 1; __v="${__v:-$__def}"; fi
    if [[ "$__v" =~ ^[0-9]+$ ]] && (( __v >= 1 && __v <= $# )); then printf -v "$__name" '%s' "$__v"; return 0; fi
    warn "请输入 1–$#"
  done
}

pause() { $ASSUME_YES || read -r -p "  按回车继续..." _ || true; }
