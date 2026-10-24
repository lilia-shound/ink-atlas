#!/usr/bin/env bash
# ============================================================
# Ink Atlas → GitHub Pages 一键发布
#
# 用法:
#   GITHUB_TOKEN=<PAT> ./deploy-github-pages.sh [owner] [repo]
#
# 需要的 PAT 权限:
#   classic token  → repo (含 workflow)
#   fine-grained   → Contents: Read & write  + Pages: Read & write
#
# 幂等:重复跑不会重复建仓库/Pages,只推新内容。
# ============================================================
set -euo pipefail

OWNER="${1:-${GH_OWNER:-}}"
REPO="${2:-${GH_REPO:-ink-atlas}}"
BRANCH="main"
API="https://api.github.com"
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
STAGE="$(mktemp -d)"

log() { printf '\033[36m▸\033[0m %s\n' "$*"; }
err() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "${GITHUB_TOKEN:-}" ] || err "缺少 GITHUB_TOKEN 环境变量"
[ -n "$OWNER" ] || err "缺少 owner(用第一个参数传,或设 GH_OWNER)"

# --- 沙箱缺 CA 证书,git 必须跳过 SSL 校验 ---
git_cfg() { git -c http.sslVerify=false "$@"; }

# 1. 确认 token 有效 + 拿到登录名
log "校验 token ..."

# ⚠️ 前置检查:index.html 里绝不能出现 markdown 粗体标记 ** **
# 2026-10-24 踩过:GitHub Pages legacy build 遇到 `**` + 中文字符紧跟时
# 会静默报 "Page build failed."(不提示原因,只 errored)。
# 现象:`**大 swab...**` 失败,而 `**Kelli 实测...**` 正常 —— 星号紧跟中文才是触发条件。
# 根因是 markdown 语法根本不该出现在 HTML 的 JS 字符串里。
if grep -q '\*\*' "$WORKDIR/index.html" 2>/dev/null; then
  n=$(grep -o '\*\*' "$WORKDIR/index.html" | wc -l)
  err "index.html 里发现 $n 个 '**' —— 会导致 GitHub Pages 构建失败,请改成普通文本或括号"
fi

# ⚠️ 前置检查:JS 语法必须合法(否则页面全白,build 却是成功的)
# 2026-10-24 踩过:summary 字符串里写了 "Noodler's Tokyo Gift",
# 单引号被提前闭合 → SyntaxError: Unexpected identifier 's'。
# GitHub Pages 构建完全不受影响(照样 built),但页面渲染不出来。
if command -v node >/dev/null 2>&1; then
  python3 - "$WORKDIR/index.html" << 'PYCHK' > /tmp/_app_blk.js
import re, sys
c = open(sys.argv[1], encoding='utf-8').read()
blocks = re.findall(r'<script(?![^>]*src=)[^>]*>(.*?)</script>', c, re.S)
sys.stdout.write(blocks[-1] if blocks else '')
PYCHK
  if [ -s /tmp/_app_blk.js ]; then
    if ! node --check /tmp/_app_blk.js 2>/tmp/_js_err.txt; then
      err "index.html 的 JS 有语法错误,会导致页面完全白屏:
$(head -8 /tmp/_js_err.txt | sed 's/^/    /')"
    fi
  fi
  rm -f /tmp/_app_blk.js /tmp/_js_err.txt /tmp/_blk0.js
fi

me=$(curl -sS -A "ink-atlas-deploy" -H "Authorization: Bearer $GITHUB_TOKEN" "$API/user")
login=$(printf '%s' "$me" | python3 -c "import sys,json; print(json.load(sys.stdin).get('login',''))" 2>/dev/null || true)
[ -n "$login" ] || err "token 无效: $(printf '%s' "$me" | head -c 200)"
log "认证成功,登录名: $login"
[ -z "$OWNER" ] && OWNER="$login"

# 2. 准备站点内容(仓库根 = 站点根,Pages 直接发 main 分支)
log "准备站点内容 ..."
cp "$WORKDIR/dist/index.html" "$STAGE/index.html"
# 顺手带上最新预览图
[ -f "$WORKDIR/preview-v30.png" ] && cp "$WORKDIR/preview-v30.png" "$STAGE/preview.png" 2>/dev/null || true

cat > "$STAGE/.nojekyll" <<'EOF'
EOF

# 把部署脚本一起收进仓库(换沙箱时能从 GitHub 取回)
cp "$WORKDIR/deploy-github-pages.sh" "$STAGE/deploy-github-pages.sh" 2>/dev/null || true

cat > "$STAGE/README.md" <<EOF
# Ink Atlas · 彩墨百科

基于 [Mountain of Ink](https://mountainofink.com) 真实评测的钢笔彩墨百科。

- 收录 **487 条**记录:墨水 312 / 钢笔 114 / 纸张 61
- 全部内容字段已翻译为中文,品牌与产品名保留英文原文
- 单文件静态站点,无构建步骤

> 由姜去自动发布 · $(date +%Y-%m-%d)
EOF

# 3. 建仓(已存在就跳过)
log "检查仓库 $OWNER/$REPO ..."
code=$(curl -sS -A "ink-atlas-deploy" -H "Authorization: Bearer $GITHUB_TOKEN" -o /dev/null -w "%{http_code}" "$API/repos/$OWNER/$REPO")
if [ "$code" = "404" ]; then
  log "仓库不存在,创建中(public)..."
  curl -sS -A "ink-atlas-deploy" -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$REPO\",\"description\":\"Ink Atlas · 彩墨百科\",\"private\":false,\"auto_init\":true}" \
    "$API/user/repos" | head -c 300
  echo
  sleep 2
else
  log "仓库已存在,复用"
fi

# 4. 推送内容 —— 走 Contents API 而非 git push
# 原因:沙箱到 github.com 的 git 端点会间歇性 503,api.github.com 却稳定。
log "通过 Contents API 推送文件 ..."
push_file() {
  local path="$1" file="$2"
  local sha="" b64
  # 已有文件则取 sha
  sha=$(curl -sS -A "ink-atlas-deploy" -H "Authorization: Bearer $GITHUB_TOKEN" \
    "$API/repos/$OWNER/$REPO/contents/$path" 2>/dev/null \
    | python3 -c "import sys,json
try:
    d=json.load(sys.stdin); print(d.get('sha','') if isinstance(d,dict) else '')
except Exception: print('')" 2>/dev/null || echo "")
  PAYLOAD_FILE="/tmp/_gh_payload.json"
  MSG="chore: update $(basename "$path") ($(date "+%Y-%m-%d %H:%M"))"
  # 大文件走 stdin,绝不过命令行(arg list too long)
  python3 -c "
import json,sys,base64
src,msg,branch,out,sha = sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4],sys.argv[5]
content = base64.b64encode(open(src,'rb').read()).decode()
payload = {'message':msg,'content':content,'branch':branch}
if sha: payload['sha']=sha
json.dump(payload, open(out,'w'))
" "$file" "$MSG" "$BRANCH" "$PAYLOAD_FILE" "$sha"
  code=$(curl -sS -A "ink-atlas-deploy" -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Content-Type: application/json" -X PUT \
    --data-binary "@$PAYLOAD_FILE" -o /tmp/_gh_put.json -w "%{http_code}" \
    "$API/repos/$OWNER/$REPO/contents/$path")
  rm -f "$PAYLOAD_FILE"
  if [ "$code" = "200" ] || [ "$code" = "201" ]; then
    log "  ✓ $path"
  else
    err "推送 $path 失败 (HTTP $code): $(head -c 300 /tmp/_gh_put.json)"
  fi
}

push_file "index.html" "$STAGE/index.html"
push_file "README.md"  "$STAGE/README.md"
push_file ".nojekyll"  "$STAGE/.nojekyll"
[ -f "$STAGE/preview.png" ] && push_file "preview.png" "$STAGE/preview.png"
[ -f "$WORKDIR/deploy-github-pages.sh" ] && push_file "deploy-github-pages.sh" "$WORKDIR/deploy-github-pages.sh"

# 5. 开启 Pages(main 分支根目录)
log "配置 GitHub Pages ..."
pages=$(curl -sS -A "ink-atlas-deploy" -H "Authorization: Bearer $GITHUB_TOKEN" "$API/repos/$OWNER/$REPO/pages")
has_pages=$(printf '%s' "$pages" | python3 -c "import sys,json;d=json.load(sys.stdin);print('yes' if d.get('html_url') else 'no')" 2>/dev/null || echo no)
if [ "$has_pages" = "yes" ]; then
  log "Pages 已开启,更新构建配置 ..."
  curl -sS -A "ink-atlas-deploy" -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Content-Type: application/json" -X PUT \
    -d "{\"source\":{\"branch\":\"$BRANCH\",\"path\":\"/\"}}" \
    "$API/repos/$OWNER/$REPO/pages" | head -c 200
  echo
else
  log "首次开启 Pages ..."
  curl -sS -A "ink-atlas-deploy" -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"source\":{\"branch\":\"$BRANCH\",\"path\":\"/\"}}" \
    "$API/repos/$OWNER/$REPO/pages" | head -c 300
  echo
fi

# 6. 等构建
URL="https://$OWNER.github.io/$REPO/"
log "等待 Pages 构建 ..."
for i in $(seq 1 20); do
  sleep 5
  sc=$(curl -sS -A "ink-atlas-deploy" -H "Authorization: Bearer $GITHUB_TOKEN" "$API/repos/$OWNER/$REPO/pages/builds/latest")
  state=$(printf '%s' "$sc" | python3 -c "import sys,json;print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
  log "  [$i/20] build status = ${state:-unknown}"
  [ "$state" = "built" ] && break
  [ "$state" = "errored" ] && err "Pages 构建失败,详见 $API/repos/$OWNER/$REPO/pages/builds/latest"
done

log "✅ 完成: $URL"
echo "$URL"
