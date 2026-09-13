#!/bin/bash
# =============================================================================
# release.sh —— rtp2httpd fork 发布一条龙（同步上游 + 应用个人改动 + 推送 + 打 tag）
#
# 个人改动只有两处（全部内嵌在本文件里，不依赖仓库中任何其它文件）：
#   A. src/m3u.c
#      udpxy 风格节目源（http://host:port/rtp|udp|rtsp/...）按普通 HTTP 源转发，
#      不再被解包成 rtp:// udp:// rtsp://（那会错误地在本地拉起组播/RTSP 服务）。
#   B. .github/workflows/release.yaml
#      只构建 x86_64 / aarch64_cortex-a53 / mipsel_24kc；
#      删掉 versioned / docker / linux-static-bin / macos-static-bin / freebsd-bin 五个 job。
#   （另外顺带保证 .gitignore 含 rtp2httpd-openwrt-*，避免本地二进制被 git 看见）
#
# 原理：不用 rebase、不用 cherry-pick。每次都以「上游基线」为起点**重新生成**：
#         main = 基线 + 1 个个人化提交（含本脚本自己）
#       所以永远不会出现合并冲突；失败会自动回退，不留半成品。
#
# 默认基线 = 最新**正式版 tag**（如 v3.17.1）。tag 的源码与它自带的
# src/embedded_web_data.h 天然一致，workflow 里 "Check frontend pages are up-to-date"
# 必然通过。想用上游开发分支见 --from。
#
# 用法：
#   ./scripts/release.sh              # 完整流程（推送前会问你一次）
#   ./scripts/release.sh --dry-run    # 只演练：在临时目录跑完整流程并打印结果，不动你的仓库
#   ./scripts/release.sh --yes        # 不询问，直接推送
#   ./scripts/release.sh --from upstream/main   # 换基线（会提示 frontend 校验风险）
#   ./scripts/release.sh --help
#
# 结束后只需要去网页点一下 Publish release 即可触发构建。
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

DRY_RUN=0
ASSUME_YES=0
FROM_REF=""

usage() {
  cat <<'EOF'
用法: ./scripts/release.sh [选项]

  -n, --dry-run      演练模式：克隆到临时目录跑完整流程（含推送前的全部校验），
                     结束时打印将要推送的内容；不改动你当前的仓库，也不推送。
  -y, --yes          跳过“是否推送到 origin”的确认。
      --from <ref>   指定基线（默认 = 最新正式版 tag，例如 v3.17.1）。
                     常用值：upstream/main。注意：若该基线的 frontend 源码与
                     正式版 tag 不一致，GitHub Actions 的 frontend 校验可能失败。
  -h, --help         显示本帮助。

流程：拉取上游 → main 重置到基线 → 应用个人改动（m3u 补丁 + release.yaml 精简 + .gitignore）
      → 校验（含幂等自检）→ 提交 → 推送 main → 重打并推送 tag → 提示去网页建 release。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    --from)       shift; [ $# -gt 0 ] || die "--from 后面需要跟一个 ref"; FROM_REF="$1" ;;
    --from=*)     FROM_REF="${1#*=}" ;;
    -h|--help)    usage; exit 0 ;;
    *)            error "未知参数: $1"; echo; usage; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# 0. 定位仓库 + 组装工作区
# ---------------------------------------------------------------------------
command -v git >/dev/null 2>&1     || die "缺少命令: git"
command -v python3 >/dev/null 2>&1 || die "缺少命令: python3（用它做 release.yaml 的文本变换）"

SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
[ -r "$SELF" ] || die "无法读取本脚本自身: $SELF"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "请在 rtp2httpd 仓库内运行（当前目录不是 git 仓库）"
cd "$REPO_ROOT"

git remote get-url origin >/dev/null 2>&1 || die "缺少 origin remote（你的 fork）"
git remote get-url upstream >/dev/null 2>&1 || die "缺少 upstream remote。执行:
      git remote add upstream https://github.com/stackia/rtp2httpd.git"

ORIGIN_URL="$(git remote get-url origin)"
UPSTREAM_URL="$(git remote get-url upstream)"

TMP_ROOT="$(mktemp -d)"
WORK="$REPO_ROOT"
ROLLBACK=0
OLD_HEAD=""
CLEANUP_DIR=""

cleanup() {
  rc=$?
  if [ "$ROLLBACK" = 1 ] && [ -n "$OLD_HEAD" ]; then
    error "出错，正在把 main 回退到运行前状态 ($(git -C "$WORK" rev-parse --short "$OLD_HEAD" 2>/dev/null)) ..."
    if git -C "$WORK" checkout -f -q -B main "$OLD_HEAD" 2>/dev/null; then
      error "已回退，仓库与运行前完全一致。失败原因见上方日志。"
    else
      error "自动回退失败，请手动执行: git -C $WORK checkout -f main $BACKUP_TAG"
    fi
  fi
  [ -n "$CLEANUP_DIR" ] && rm -rf "$CLEANUP_DIR" 2>/dev/null
  rm -rf "$TMP_ROOT" 2>/dev/null
  exit $rc
}
trap cleanup EXIT

if [ "$DRY_RUN" = 1 ]; then
  CLEANUP_DIR="$TMP_ROOT"
  WORK="$TMP_ROOT/rtp2httpd"
  [ -n "$(git status --porcelain)" ] && warn "演练模式只克隆已提交的内容；你工作区里的未提交改动不会参与演练"
  git clone --no-hardlinks -q -b main . "$WORK" || die "克隆到临时目录失败"
  git -C "$WORK" remote set-url origin "$ORIGIN_URL"
  git -C "$WORK" remote remove upstream >/dev/null 2>&1 || true
  git -C "$WORK" remote add upstream "$UPSTREAM_URL"
  info "演练模式：全部改动只发生在临时目录 $WORK（你的仓库不会被改，也不会推送）"
else
  if [ -n "$(git status --porcelain)" ]; then
    error "工作区有未提交的改动，请先 commit 或 stash"
    git status --short
    exit 1
  fi
fi
cd "$WORK"

# ---------------------------------------------------------------------------
# 1. 拉取上游（分两步：分支失败=致命，tag 同名冲突=预期噪音）
# ---------------------------------------------------------------------------
echo
info "拉取上游 ..."
# 分支：失败=致命（先重试 3 次，容器/网络抖动很常见），并把 git 原始报错打出来
BR_OUT=""; BR_RC=1
for attempt in 1 2 3; do
  set +e
  BR_OUT="$(git fetch upstream --prune 2>&1)"; BR_RC=$?
  set -e
  [ "$BR_RC" -eq 0 ] && break
  if [ "$attempt" -lt 3 ]; then
    warn "拉取上游失败（第 $attempt 次）: $(printf '%s' "$BR_OUT" | tail -1)"
    sleep 2
  fi
done
if [ "$BR_RC" -ne 0 ]; then
  error "拉取上游分支失败（网络/DNS/认证），已中止，不会用旧数据继续。git 的报错："
  printf '%s\n' "$BR_OUT" | sed 's/^/      /'
  exit 1
fi
[ -n "$BR_OUT" ] && printf '%s\n' "$BR_OUT" | sed 's/^/      /' || true

# tag：与本地同名 tag 冲突（fork 重建过 vN.N.N）是预期噪音，其余错误照旧致命
TAG_OUT=""; TAG_RC=1
for attempt in 1 2 3; do
  set +e
  TAG_OUT="$(git fetch upstream --tags 2>&1)"; TAG_RC=$?
  set -e
  [ "$TAG_RC" -eq 0 ] && break
  printf '%s' "$TAG_OUT" | grep -q 'would clobber existing tag' && break
  [ "$attempt" -lt 3 ] && sleep 2 || true
done
if printf '%s' "$TAG_OUT" | grep -q 'would clobber existing tag'; then
  warn "取上游 tag 时与本地同名 tag 冲突（预期）——已忽略，其余 tag 已正常更新"
elif [ "$TAG_RC" -ne 0 ]; then
  error "拉取上游 tag 失败："; printf '%s\n' "$TAG_OUT" | sed 's/^/      /'; exit 1
fi

# 上游最新「正式版」tag：直接问服务器，并且排除 -beta/-rc 等预发布。
# 注意：不能只看本地 tag —— 本脚本第一次运行后会把同名本地 tag 重指到自己的 main，
# 那样第二次运行就会把「自己的 main」当成基线。
latest_stable_tag() {
  local out="" attempt
  for attempt in 1 2 3; do
    out="$(git ls-remote --tags --refs upstream 2>/dev/null | sed 's#.*refs/tags/##' \
             | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    sleep 2
  done
  return 1
}

VERSION="$(latest_stable_tag)"
[ -n "$VERSION" ] || die "无法从 upstream 取到最新正式版 tag（检查网络 / upstream remote）"

# 把上游 tag 拉到我们自己的命名空间，避免被本地同名 tag 遮蔽
UP_TAG_REF="refs/upstream-tags/$VERSION"
git fetch upstream "+refs/tags/$VERSION:$UP_TAG_REF" >/dev/null 2>&1 \
  || die "无法拉取上游 tag $VERSION（upstream 上不存在该 tag？）"

if [ -n "$FROM_REF" ]; then
  git rev-parse --verify --quiet "$FROM_REF^{commit}" >/dev/null || die "找不到基线 ref: $FROM_REF"
  BASE="$FROM_REF"
else
  BASE="$UP_TAG_REF"
fi
BASE_SHA="$(git rev-parse --short "$BASE^{commit}")"
BASE_SUBJECT="$(git log -1 --format='%s' "$BASE^{commit}")"
info "基线 : $BASE  ($BASE_SHA  $BASE_SUBJECT)"
info "版本 : $VERSION  (上游正式版 tag)"
info "当前 : main = $(git rev-parse --short HEAD)  $(git log -1 --format='%s' HEAD)"

if [ -n "$FROM_REF" ] && ! git diff --quiet "$UP_TAG_REF^{commit}" "$BASE^{commit}" -- src/embedded_web_data.h web-ui 2>/dev/null; then
  warn "基线 $BASE 的 frontend 源码与 tag $VERSION 不一致："
  warn "  workflow 里 'Check frontend pages are up-to-date' 有失败风险。"
  warn "  建议等上游发布新的正式版 tag 后再发 release（即不加 --from）。"
fi

# ---------------------------------------------------------------------------
# 2. 备份现场（本地 tag，回退/追溯用）
# ---------------------------------------------------------------------------
OLD_HEAD="$(git rev-parse HEAD)"
BACKUP_TAG="fork-backup-$(date +%Y%m%d-%H%M%S)"
git tag -f "$BACKUP_TAG" "$OLD_HEAD" >/dev/null
info "旧 main 已备份为本地 tag: $BACKUP_TAG ($(git rev-parse --short "$OLD_HEAD"))"

# ---------------------------------------------------------------------------
# 3. 准备个人化载荷（全部写到临时目录，重置 main 之后再用）
# ---------------------------------------------------------------------------
# 本脚本自身也要回到仓库里（否则重生成后 main 上就没有这个脚本了）
cp -p "$SELF" "$TMP_ROOT/release.sh" || die "无法把本脚本复制到临时目录"

# 3.1 m3u 补丁：内嵌在下面这段 heredoc 里（保持可读，方便上游重构时修改）
PATCH_FILE="$TMP_ROOT/m3u-udpxy-fix.patch"
cat > "$PATCH_FILE" <<'PATCH_EOF'
diff --git a/src/m3u.c b/src/m3u.c
index cab4a68..3a945af 100644
--- a/src/m3u.c
+++ b/src/m3u.c
@@ -678,10 +678,12 @@ static int build_appended_catchup_url(const char *base_url, const char *catchup_
   return 0;
 }
 
-/* Extract actual URL from http://host:port/protocol/actual_url format
- * Example: http://router.ccca.cc:5140/rtp/239.253.64.120:5140 ->
- * rtp://239.253.64.120:5140
- */
+/* Extract actual URL from http://host:port/http/actual_url format
+ * Example: http://router.ccca.cc:5140/http/server/path ->
+ * http://server/path
+ *
+ * Note: udpxy-style URLs (http://host:port/rtp|udp|rtsp/...) are NOT
+ * unwrapped — they are treated as plain HTTP proxy sources. */
 static int extract_wrapped_url(const char *url, char *extracted, size_t extracted_size) {
   const char *scheme_end;
   const char *host_start;
@@ -727,7 +729,7 @@ static int extract_wrapped_url(const char *url, char *extracted, size_t extracte
     }
   }
 
-  /* Extract protocol (rtp, udp, rtsp) */
+  /* Extract protocol (only http is unwrapped; see note below) */
   protocol_end = strchr(path_start, '/');
   if (!protocol_end) {
     return -1; /* No protocol separator */
@@ -741,9 +743,16 @@ static int extract_wrapped_url(const char *url, char *extracted, size_t extracte
   memcpy(protocol, path_start, protocol_len);
   protocol[protocol_len] = '\0';
 
-  /* Check if protocol is supported */
-  if (strcasecmp(protocol, "rtp") != 0 && strcasecmp(protocol, "udp") != 0 && strcasecmp(protocol, "rtsp") != 0 &&
-      strcasecmp(protocol, "http") != 0) {
+  /* Only unwrap http://.../http/... wrapped URLs.
+   *
+   * udpxy-style URLs such as http://host:port/rtp/multicast_addr:port,
+   * http://host:port/udp/multicast_addr:port and
+   * http://host:port/rtsp/server:port/path look identical to rtp2httpd's own
+   * proxied paths, but they point to an upstream unicast server (e.g. udpxy).
+   * Unwrapping them into rtp:// / udp:// / rtsp:// would wrongly create a
+   * local multicast/RTSP service instead of an HTTP reverse proxy. They must
+   * be treated as plain HTTP sources and proxied as-is. */
+  if (strcasecmp(protocol, "http") != 0) {
     return -1; /* Unsupported protocol */
   }
 
@@ -818,7 +827,9 @@ static int is_url_recognizable(const char *url) {
   strncpy(test_url, url, sizeof(test_url) - 1);
   test_url[sizeof(test_url) - 1] = '\0';
 
-  /* Try to extract wrapped URL (supports rtp, udp, rtsp, http) */
+  /* Try to extract wrapped HTTP URL (supports http only; udpxy-style
+   * http://host:port/rtp|udp|rtsp/... URLs are left intact and recognized as
+   * plain HTTP sources below) */
   if (extract_wrapped_url(test_url, extracted, sizeof(extracted)) == 0) {
     /* Wrapped URL extracted - always recognizable since extract_wrapped_url
      * only succeeds for supported protocols */
@@ -989,8 +1000,10 @@ static char *create_service_from_url(const char *service_name, const char *url,
   strncpy(normalized_url, url, sizeof(normalized_url) - 1);
   normalized_url[sizeof(normalized_url) - 1] = '\0';
 
-  /* Try to extract wrapped URL (e.g., http://router:5140/rtp/239.x.x.x ->
-   * rtp://239.x.x.x) */
+  /* Try to extract wrapped HTTP URL (e.g., http://router:5140/http/server/path
+   * -> http://server/path). udpxy-style URLs (http://host:port/rtp/...) are
+   * intentionally NOT unwrapped: they are upstream HTTP unicast sources and
+   * must stay as HTTP proxy URLs. */
   if (extract_wrapped_url(normalized_url, extracted_url, sizeof(extracted_url)) == 0) {
     /* Use the extracted URL */
     strncpy(normalized_url, extracted_url, sizeof(normalized_url) - 1);
PATCH_EOF
[ -s "$PATCH_FILE" ] || die "内嵌补丁为空（本文件可能被截断）"
info "内嵌 m3u 补丁: $(wc -c < "$PATCH_FILE") 字节"

# 3.2 release.yaml 变换：写成 python 脚本（内嵌）
PAYLOAD="$TMP_ROOT/personalize_release.py"
cat > "$PAYLOAD" <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""release.sh 内嵌：把上游 release.yaml 精简成个人版（幂等纯文本变换）。

用法: personalize_release.py <repo_root> [--check]
"""
import argparse
import os
import re
import sys

REL_PATH = ".github/workflows/release.yaml"

# 保留/删除的 job；目标架构（x86_64 用于产出架构无关的 luci 包）
KEEP_JOBS = ["frontend", "openwrt-packages"]
DROP_JOBS = ["versioned", "docker", "linux-static-bin", "macos-static-bin", "freebsd-bin"]
ARCHES = ["aarch64_cortex-a53", "mipsel_24kc", "x86_64"]
PACKAGES_COMMENT = "          # Only x86_64 also builds the architecture-independent luci web UI\n"

PACKAGES_LINE_RE = re.compile(r"^( *)PACKAGES:.*$", re.M)
RENAME_COMMENT_RE = re.compile(r"^( *# e\.g\., (\S+)\.apk -> )\S+\.apk\s*$", re.M)
ARCH_LINE_RE = re.compile(r"^          - \S+\n$")
ARCH_HEADER_RE = re.compile(r"^        arch:\n$")
JOB_RE = re.compile(r"^  ([A-Za-z0-9_-]+):[ ]*(#.*)?\n$")


def die(msg):
    print("[ERROR] " + msg, file=sys.stderr)
    sys.exit(1)


def split_jobs(text):
    lines = text.splitlines(keepends=True)
    idx = None
    for i, line in enumerate(lines):
        if line.rstrip("\n") == "jobs:":
            idx = i
            break
    if idx is None:
        die("release.yaml 里找不到顶层 `jobs:` 行")

    prefix = "".join(lines[: idx + 1])
    blocks, cur_name, cur = [], None, []
    for line in lines[idx + 1:]:
        m = JOB_RE.match(line)
        if m:
            if cur_name is not None:
                blocks.append((cur_name, "".join(cur)))
            cur_name, cur = m.group(1), [line]
        else:
            cur.append(line)
    if cur_name is not None:
        blocks.append((cur_name, "".join(cur)))
    if not blocks:
        die("release.yaml 的 jobs: 下没有解析到任何 job")
    return prefix, blocks


def rewrite_arches(block):
    lines = block.splitlines(keepends=True)
    out, i, replaced = [], 0, False
    while i < len(lines):
        out.append(lines[i])
        if ARCH_HEADER_RE.match(lines[i]):
            j = i + 1
            while j < len(lines) and ARCH_LINE_RE.match(lines[j]):
                j += 1
            out.extend("          - %s\n" % a for a in ARCHES)
            replaced = True
            i = j
            continue
        i += 1
    if not replaced:
        die("openwrt-packages 里找不到 `matrix.arch:` 清单（上游改了结构？）")
    return "".join(out)


def personalize(text):
    if "<<<<<<<" in text or ">>>>>>>" in text:
        die("release.yaml 里有冲突标记，请先解决冲突")

    prefix, blocks = split_jobs(text)
    names = [n for n, _ in blocks]

    unknown = [n for n in names if n not in KEEP_JOBS + DROP_JOBS]
    if unknown:
        die("上游新增了脚本不认识的 job: " + ", ".join(unknown) +
            "\n        确认是否要保留后，更新 release.sh 里的 KEEP_JOBS / DROP_JOBS")
    missing = [n for n in KEEP_JOBS if n not in names]
    if missing:
        die("缺少预期保留的 job: " + ", ".join(missing))

    by_name = dict(blocks)
    out = prefix + "".join(by_name[n] for n in KEEP_JOBS)

    head, sep, _ = out.partition("  openwrt-packages:\n")
    if not sep:
        die("找不到 openwrt-packages job 块")
    out = head + rewrite_arches(sep + out[len(head) + len(sep):])

    m = PACKAGES_LINE_RE.search(out)
    if not m:
        die("openwrt-packages 里找不到 PACKAGES: 行（上游改了结构？）")
    if not out[: m.start()].endswith(PACKAGES_COMMENT):
        out = out[: m.start()] + PACKAGES_COMMENT + out[m.start():]

    # 示例注释里的架构名：由左值推导，天然幂等
    out = RENAME_COMMENT_RE.sub(lambda mm: mm.group(1) + mm.group(2) + "_" + ARCHES[0] + ".apk", out)

    out = out.rstrip("\n") + "\n"

    bad = [a for a in re.findall(r"^          - (\S+)$", out, re.M) if a not in ARCHES]
    if bad:
        die("精简后仍存在非目标架构: " + ", ".join(sorted(set(bad))))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--check", action="store_true", help="只校验（不写盘）")
    args = ap.parse_args()

    os.chdir(args.root)
    if not os.path.isfile(REL_PATH):
        die("找不到 %s（基线不对？）" % REL_PATH)
    with open(REL_PATH, encoding="utf-8") as fh:
        src = fh.read()

    dst = personalize(src)
    if args.check:
        if src == dst:
            print("[OK] release.yaml 已是个人精简版（幂等）")
            return 0
        print("[ERROR] release.yaml 不是个人精简版", file=sys.stderr)
        return 1
    if src == dst:
        print("[OK] release.yaml 无需改动（已是个人精简版）")
        return 0
    with open(REL_PATH, "w", encoding="utf-8") as fh:
        fh.write(dst)
    print("[OK] release.yaml 已重写 (jobs=%s, arch=%s)" % (",".join(KEEP_JOBS), ",".join(ARCHES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$PAYLOAD" \
  || die "内嵌的 python 载荷语法错误（本文件可能被破坏）"

# ---------------------------------------------------------------------------
# 4. 重生成 main = 基线
# ---------------------------------------------------------------------------
echo
info "把 main 重置到基线 $BASE ..."
ROLLBACK=1
git checkout -B main "$BASE^{commit}" >/dev/null 2>&1 || die "无法把 main 重置到 $BASE"
git branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true

# 脚本自身回到仓库（否则下次就没法再跑了）
mkdir -p scripts
cp -p "$TMP_ROOT/release.sh" scripts/release.sh

# ---------------------------------------------------------------------------
# 5. 应用个人改动（幂等）
# ---------------------------------------------------------------------------
echo
info "应用个人改动 ..."

# 5.1 src/m3u.c：udpxy 风格源按 HTTP 转发
M3U_MARKER='Only unwrap http://\.\.\./http/\.\.\. wrapped URLs'
if grep -q "$M3U_MARKER" src/m3u.c; then
  info "  src/m3u.c: 补丁已在位"
elif git apply --check "$PATCH_FILE" 2>/dev/null; then
  git apply "$PATCH_FILE"
  info "  src/m3u.c: 补丁已应用"
elif git apply --3way "$PATCH_FILE" 2>/dev/null; then
  warn "  src/m3u.c: 用三方合并应用（上游改了上下文，建议核对一眼）"
else
  die "  src/m3u.c: 补丁无法应用 —— 上游很可能重构了 extract_wrapped_url。
        请人工对照 src/m3u.c 打上改动，然后更新本脚本里 PATCH_EOF 那段补丁后重试。"
fi
grep -q "$M3U_MARKER" src/m3u.c || die "  src/m3u.c: 补丁校验标记不存在，个人化不完整"
info "  src/m3u.c: ✓"

# 5.2 .gitignore：忽略个人 OpenWrt 二进制产物
if grep -qxF 'rtp2httpd-openwrt-*' .gitignore 2>/dev/null; then
  info "  .gitignore: 规则已在位"
else
  printf '\n# Personal OpenWrt binary artifacts\nrtp2httpd-openwrt-*\n' >> .gitignore
  info "  .gitignore: 已追加 rtp2httpd-openwrt-*"
fi

# 5.3 release.yaml：精简构建矩阵
python3 "$PAYLOAD" "$(pwd)"

# ---------------------------------------------------------------------------
# 6. 校验
# ---------------------------------------------------------------------------
echo
info "校验 ..."
python3 - "$(pwd)" <<'VERIFY_EOF'
import re, sys, os
os.chdir(sys.argv[1])
p = ".github/workflows/release.yaml"
with open(p, encoding="utf-8") as fh:
    s = fh.read()
lines = s.splitlines()
if "jobs:" not in lines:
    sys.exit("【校验失败】release.yaml 里找不到顶层 jobs:")
body = "\n".join(lines[lines.index("jobs:") + 1:])   # 只看 jobs: 之后，避免把 on: release: 当 job
jobs = re.findall(r"^  ([a-z0-9-]+):$", body, re.M)
arch = re.findall(r"^          - (\S+)$", body, re.M)
expect_jobs = ["frontend", "openwrt-packages"]
expect_arch = ["aarch64_cortex-a53", "mipsel_24kc", "x86_64"]
if jobs != expect_jobs:
    sys.exit("【校验失败】release.yaml 的 job 列表是 %s，期望 %s" % (jobs, expect_jobs))
if arch != expect_arch:
    sys.exit("【校验失败】release.yaml 的架构列表是 %s，期望 %s" % (arch, expect_arch))
pk = s.split("PACKAGES:", 1)[1].split("\n")[0] if "PACKAGES:" in s else ""
if "x86_64" not in pk or "luci-app-rtp2httpd" not in pk:
    sys.exit("【校验失败】release.yaml 的 PACKAGES 条件被改坏了: %r" % pk)
try:
    import yaml
    yaml.safe_load(s)
    print("  ✓ release.yaml 语法合法（PyYAML 解析通过）")
except ImportError:
    print("  ✓ release.yaml 结构检查通过（未装 PyYAML，跳过语法解析）")
except Exception as e:
    sys.exit("【校验失败】release.yaml 不是合法 YAML: %s" % e)
print("  ✓ release.yaml job=%s arch=%s" % (",".join(jobs), " ".join(arch)))
VERIFY_EOF

grep -qxF 'rtp2httpd-openwrt-*' .gitignore || die "【校验失败】.gitignore 缺少 rtp2httpd-openwrt-* 规则"
info "  ✓ .gitignore 含 rtp2httpd-openwrt-*"

[ -x scripts/release.sh ] || chmod +x scripts/release.sh
[ -x scripts/release.sh ] || die "【校验失败】scripts/release.sh 不可执行"
info "  ✓ scripts/release.sh 已在仓库内（下次可以直接再跑）"

python3 "$PAYLOAD" "$(pwd)" --check >/dev/null || die "【校验失败】release.yaml 幂等自检不通过"
info "  ✓ 幂等自检通过（重复运行不会再改动 release.yaml）"

CHANGED="$(git status --porcelain | awk '{print $2}' | sort | tr '\n' ' ')"
info "  ✓ 本次改动文件: $CHANGED"

# ---------------------------------------------------------------------------
# 7. 提交
# ---------------------------------------------------------------------------
echo
if [ -z "$(git status --porcelain)" ]; then
  warn "个人化没有产生任何改动（基线内容已符合个人版），不创建新提交"
else
  git add -A
  git -c user.name="${GIT_AUTHOR_NAME:-iseku}" -c user.email="${GIT_AUTHOR_EMAIL:-iseku@users.noreply.github.com}" \
    commit -q -m "chore(fork): personalization on $VERSION ($BASE_SHA)" \
    -m "个人改动：src/m3u.c udpxy 风格源按 HTTP 转发 + release.yaml 只构建 x86_64 / aarch64_cortex-a53 / mipsel_24kc"
  info "已提交: $(git rev-parse --short HEAD)  $(git log -1 --format='%s')"
fi

# ---------------------------------------------------------------------------
# 8. 推送 + 打 tag
# ---------------------------------------------------------------------------
echo
echo "====================== 将要推送 ======================"
echo "  分支 : main            $(git rev-parse --short HEAD)   (force-with-lease → origin/main)"
echo "  标签 : $VERSION     → $(git rev-parse --short HEAD)   (force → origin)"
echo "  父提交: $BASE_SHA  $BASE_SUBJECT"
echo "  个人化: $(git --no-pager diff --shortstat "$BASE^{commit}" HEAD)"
echo "======================================================"
echo

if [ "$DRY_RUN" = 1 ]; then
  ROLLBACK=0
  echo "【演练模式】以下命令已在临时目录演练完毕，未真正执行："
  echo "    git push --force-with-lease origin main"
  echo "    git tag -f $VERSION && git push origin $VERSION --force"
  echo
  info "演练成功。确认无误后，去掉 --dry-run 再跑一次即可真正发布。"
  exit 0
fi

DO_PUSH=1
if [ "$ASSUME_YES" != 1 ]; then
  printf "是否现在推送到 origin(%s) 并打 tag %s？[y/N] " "$ORIGIN_URL" "$VERSION"
  read -r ans || ans=""
  case "$ans" in y|Y|yes|YES) DO_PUSH=1 ;; *) DO_PUSH=0 ;; esac
fi

if [ "$DO_PUSH" != 1 ]; then
  ROLLBACK=0
  warn "已跳过推送。本地 main 与 tag 都已就绪，随时可以手动执行："
  echo "    git push --force-with-lease origin main"
  echo "    git tag -f $VERSION && git push origin $VERSION --force"
  exit 0
fi

info "推送 main ..."
git push --force-with-lease origin main

info "重打并推送 tag $VERSION ..."
git tag -f "$VERSION" >/dev/null
git push origin "$VERSION" --force

ROLLBACK=0

# ---------------------------------------------------------------------------
# 9. 收尾提示
# ---------------------------------------------------------------------------
SLUG="$(printf '%s' "$ORIGIN_URL" | sed -nE 's#^.*github\.com[:/]##p')"
SLUG="${SLUG%.git}"
SLUG="${SLUG%/}"

echo
echo "================== 最后一步：网页建 release =================="
if [ -n "$SLUG" ]; then
  echo "  https://github.com/$SLUG/releases/new"
else
  echo "  打开你 fork 的 GitHub 页面 → Releases → Draft a new release"
  echo "  （origin = $ORIGIN_URL）"
fi
echo "    - Choose a tag: $VERSION"
echo "    - Title       : $VERSION"
echo "    - Publish release"
echo
echo "  构建矩阵（release.yaml 精简体）："
echo "    frontend            → 编译嵌入式 Web UI"
echo "    aarch64_cortex-a53  → rtp2httpd（IPK + APK）"
echo "    mipsel_24kc         → rtp2httpd（IPK + APK）"
echo "    x86_64              → luci-app-rtp2httpd（IPK + APK）"
echo
echo "  回退用（本次运行前的 main）: $BACKUP_TAG"
echo "=============================================================="
