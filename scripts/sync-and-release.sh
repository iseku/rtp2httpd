#!/bin/bash
# =============================================================================
# sync-and-release.sh - 同步上游并准备一次个人 release
#
# 用途：
#   这个 fork 保留了上游代码 + 两个个人改动：
#     1. src/m3u.c          - udpxy 风格 URL 按 HTTP 代理处理（修复）
#     2. .github/workflows/release.yaml - 精简为只构建 aarch64_cortex-a53 /
#        mipsel_24kc（个人使用）
#
# 本脚本把个人改动 rebase 到上游最新代码之上，验证改动仍在，然后提示
# 打 tag 并在网页上创建 release。
#
# 执行环境：在克隆了本 fork 的任意 Linux/macOS 机器上运行。
#   cd <fork 目录> && ./scripts/sync-and-release.sh
#
# 依赖：
#   - git、curl、jq
#   - 已配置 origin（本 fork）与 upstream（作者仓库）两个 remote
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 颜色输出
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# 检查依赖与 remote
# ---------------------------------------------------------------------------
for cmd in git curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    error "缺少依赖命令: $cmd（请先安装）"
    exit 1
  fi
done

if [ ! -d .git ]; then
  error "请在本仓库根目录下运行（当前目录不是 git 仓库）"
  exit 1
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  error "缺少 origin remote（本 fork）"
  exit 1
fi
if ! git remote get-url upstream >/dev/null 2>&1; then
  error "缺少 upstream remote（作者仓库）。执行: git remote add upstream https://github.com/stackia/rtp2httpd.git"
  exit 1
fi

# 工作区必须干净（有未提交改动时拒绝 rebase）
if [ -n "$(git status --porcelain)" ]; then
  error "工作区有未提交的改动，请先 commit 或 stash"
  git status --short
  exit 1
fi

# 当前分支
BRANCH="$(git symbolic-ref --short HEAD)"
if [ "$BRANCH" != "main" ]; then
  warn "当前分支是 '$BRANCH'，建议在 main 上执行（脚本将处理 main）"
fi

# ---------------------------------------------------------------------------
# 1. 拉取上游
# ---------------------------------------------------------------------------
echo
info "拉取上游（upstream）..."
git fetch upstream --prune --tags

# ---------------------------------------------------------------------------
# 2. 计算个人改动（fork 相对上游的差异）
# ---------------------------------------------------------------------------
UPSTREAM_BASE="upstream/main"
if ! git rev-parse --verify "$UPSTREAM_BASE" >/dev/null 2>&1; then
  error "无法找到 $UPSTREAM_BASE，请确认 upstream remote 正确"
  exit 1
fi

echo
info "检查当前 main 相对 $UPSTREAM_BASE 的改动..."
git --no-pager log --oneline --left-right "$UPSTREAM_BASE...HEAD" || true

# ---------------------------------------------------------------------------
# 3. Rebase 到上游最新
# ---------------------------------------------------------------------------
echo
info "Rebase 到 $UPSTREAM_BASE ..."
if ! git rebase "$UPSTREAM_BASE"; then
  error "Rebase 冲突！请手动解决后执行："
  error "  git add <文件> && git rebase --continue"
  error "然后重新运行本脚本"
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. 验证个人改动仍然存在
# ---------------------------------------------------------------------------
echo
info "验证个人改动是否保留..."

# 4.1 m3u.c 修复：extract_wrapped_url 应只解包 http 协议
if ! grep -q 'Only unwrap http://\.\.\./http/\.\.\. wrapped URLs' src/m3u.c; then
  error "【检查失败】src/m3u.c 的 udpxy 修复标记未找到！"
  error "上游可能重构了 extract_wrapped_url，需要重新应用补丁："
  error "  git apply rtp2httpd-m3u-udpxy-fix.patch"
  exit 1
fi
info "  ✓ src/m3u.c udpxy 修复仍在"

# 4.2 release.yaml 精简：只应包含目标 arch
ARCH_COUNT=$(grep -cE '^\s+- (aarch64_cortex-a53|mipsel_24kc)$' .github/workflows/release.yaml || true)
if [ "$ARCH_COUNT" -lt 2 ]; then
  error "【检查失败】release.yaml 中找不到 aarch64_cortex-a53 或 mipsel_24kc！"
  error "上游更新可能覆盖了精简配置，需要重新精简 release.yaml"
  exit 1
fi
if grep -qE '^\s+- (x86_64|arm_cortex|mips_24kc|mips_mips32|mipsel_74kc|mipsel_mips32)$' .github/workflows/release.yaml; then
  warn "  ⚠ release.yaml 中似乎有多余的 arch（上游可能合并回来了），请检查"
fi
info "  ✓ release.yaml 仍包含目标 arch"

# ---------------------------------------------------------------------------
# 5. 汇总 & 提示推送 + 打 tag
# ---------------------------------------------------------------------------
echo
info "Rebase 完成！当前 HEAD: $(git rev-parse --short HEAD)"
echo
echo "====================== 下一步（手动） ======================"
echo "  1. 推送到 fork:"
echo "       git push --force-with-lease origin main"
echo "  2. 打新 tag（版本号递增，例如）:"
echo "       git tag v3.16.0-iseku.2 && git push origin v3.16.0-iseku.2"
echo "  3. 在网页创建 release 触发构建:"
echo "       https://github.com/iseku/rtp2httpd/releases/new"
echo "     - Choose a tag: 选刚推的 tag"
echo "     - Title: 同 tag 名"
echo "     - Publish release"
echo "=============================================================="

# 若远端落后于本地，提醒推送
if git status -sb | grep -q '^## .*\[ahead'; then
  echo
  warn "本地 main 领先 origin/main，记得执行: git push --force-with-lease origin main"
fi
