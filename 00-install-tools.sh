#!/usr/bin/env bash
# 安装运维工具到 ~/.local/bin（无需 sudo；CloudShell 只有 $HOME 在会话间保留）
# 工具：aws cli v2 / kubectl（跟随 EKS_VERSION）/ helm v3 / jq；检查 git、python3、curl、tar、unzip
# 自动识别 x86_64 / aarch64；已满足要求的工具会跳过
set -euo pipefail
cd "$(dirname "$0")"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$INSTALL_DIR"
export PATH="$INSTALL_DIR:$PATH"

cfg_value() {  # 从 config.env（或模板）读取一个值，去掉行内注释与引号
  local f; for f in config.env config.env.example; do
    [[ -f $f ]] && grep -E "^$1=" "$f" | head -1 | cut -d= -f2- | sed -E 's/[[:space:]]+#.*//; s/^"//; s/"$//' && return
  done
}
EKS_VERSION="$(cfg_value EKS_VERSION)"; EKS_VERSION="${EKS_VERSION:-1.35}"
JQ_VERSION="${JQ_VERSION:-1.7.1}"

case "$(uname -m)" in
  x86_64)  ARCH=amd64; AWS_ARCH=x86_64 ;;
  aarch64) ARCH=arm64; AWS_ARCH=aarch64 ;;
  *) echo "不支持的架构: $(uname -m)"; exit 1 ;;
esac
echo "架构 $(uname -m) · 安装目录 $INSTALL_DIR · kubectl 目标版本 ${EKS_VERSION}.x"

# 必须由系统提供的基础命令
for c in curl tar unzip git python3 sha256sum base64; do
  command -v "$c" >/dev/null || { echo "✘ 缺少 $c，请先安装（Amazon Linux: sudo dnf install -y $c）"; exit 1; }
done
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' || { echo "✘ 需要 Python ≥ 3.8"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

if ! aws --version 2>/dev/null | grep -q 'aws-cli/2'; then
  echo "→ 安装 AWS CLI v2"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o "$TMP/awscli.zip"
  unzip -q "$TMP/awscli.zip" -d "$TMP"
  "$TMP/aws/install" --update --install-dir "$HOME/.local/aws-cli" --bin-dir "$INSTALL_DIR"
fi

if ! kubectl version --client 2>/dev/null | grep -q "v${EKS_VERSION}\."; then
  echo "→ 安装 kubectl ${EKS_VERSION}.x"
  KVER=$(curl -fsSL "https://dl.k8s.io/release/stable-${EKS_VERSION}.txt")
  curl -fsSL "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl" -o "$TMP/kubectl"
  curl -fsSL "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl.sha256" -o "$TMP/kubectl.sha256"
  (cd "$TMP" && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c - >/dev/null)
  install -m 0755 "$TMP/kubectl" "$INSTALL_DIR/kubectl"
fi

# HyperPod Helm Chart 按 Helm 3 验证；Helm 4 默认 server-side apply 会与 aggregated ClusterRole 冲突
if ! helm version --short 2>/dev/null | grep -q '^v3\.'; then
  echo "→ 安装 Helm 3"
  HVER=$(curl -fsSL https://get.helm.sh/helm3-latest-version)
  curl -fsSL "https://get.helm.sh/helm-${HVER}-linux-${ARCH}.tar.gz" -o "$TMP/helm.tgz"
  curl -fsSL "https://get.helm.sh/helm-${HVER}-linux-${ARCH}.tar.gz.sha256sum" -o "$TMP/helm.sha256"
  (cd "$TMP" && sed "s#helm-.*#helm.tgz#" helm.sha256 | sha256sum -c - >/dev/null)
  tar -xzf "$TMP/helm.tgz" -C "$TMP" && install -m 0755 "$TMP/linux-${ARCH}/helm" "$INSTALL_DIR/helm"
fi

if ! jq --version >/dev/null 2>&1; then
  echo "→ 安装 jq ${JQ_VERSION}"
  base="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}"
  curl -fsSL "$base/jq-linux-${ARCH}" -o "$TMP/jq-linux-${ARCH}"
  curl -fsSL "$base/sha256sum.txt" -o "$TMP/sha256sum.txt"
  (cd "$TMP" && grep " jq-linux-${ARCH}\$" sha256sum.txt | sha256sum -c - >/dev/null)
  install -m 0755 "$TMP/jq-linux-${ARCH}" "$INSTALL_DIR/jq"
fi

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "→ 安装 PyYAML（用户目录）"
  python3 -m pip install --user --quiet pyyaml
fi

# 让新开的 shell 也能找到 ~/.local/bin
if ! grep -qs 'hyperpod-eks-llm: PATH' "$HOME/.bashrc"; then
  printf '\nexport PATH="%s:$PATH"  # hyperpod-eks-llm: PATH\n' "$INSTALL_DIR" >> "$HOME/.bashrc"
fi

echo "✔ 工具就绪"
printf '  %-8s %s\n' aws "$(aws --version 2>&1 | cut -d' ' -f1)" kubectl "$(kubectl version --client 2>/dev/null | head -1 | awk '{print $3}')" \
  helm "$(helm version --short)" jq "$(jq --version)" git "$(git --version | awk '{print $3}')" python3 "$(python3 -V | awk '{print $2}')"
