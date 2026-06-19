#!/usr/bin/env bash
# 防回归冒烟测：网页逐请求语言（Accept-Language）。同一 server 按浏览器 Accept-Language 头各自
# 决定语言，与 app 设置无关。验：① 带 en 头出英文列表页（html lang=en + 英文文案）；② 带 zh 头
# 出中文页；③ 不带头回退中文基准；④ 同一 server 背靠背两种头拿到不同语言（逐请求独立）；
# ⑤ 403 页随头本地化；⑥ 多选虚拟根名随头（en=Shared items / zh=分享内容）。
# 用法：./tools/smoke-accept-language.sh   退出码 0=全过。
set -u
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8   # 断言含中文，统一 UTF-8 locale
BIN="${BIN:-.build/debug/LocalShare}"
[ -x "$BIN" ] || { echo "找不到 $BIN，先跑 swift build"; exit 2; }

TOK="langtest"
BASE="$(mktemp -d)"
echo hi > "$BASE/a.txt"
mkdir -p "$BASE/sub"
M1="$(mktemp -d)"; echo one > "$M1/one.txt"
M2="$(mktemp -d)"; echo two > "$M2/two.txt"

PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }

PORT=$(( (RANDOM % 10000) + 40000 ))
LS_HEADLESS=1 LS_FOLDER="$BASE" LS_TOKEN="$TOK" LS_PORT="$PORT" "$BIN" >/dev/null 2>&1 &
SRV=$!
PORT2=$(( (RANDOM % 10000) + 40000 ))
LS_HEADLESS=1 LS_FOLDERS="$M1/one.txt:$M2/two.txt" LS_TOKEN="$TOK" LS_PORT="$PORT2" "$BIN" >/dev/null 2>&1 &
SRV2=$!
trap 'kill $SRV $SRV2 2>/dev/null; wait $SRV $SRV2 2>/dev/null; rm -rf "$BASE" "$M1" "$M2"' EXIT

for p in "$PORT" "$PORT2"; do
  for _ in $(seq 1 50); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p/?t=$TOK")" = "200" ] && break
    sleep 0.1
  done
done
base="http://127.0.0.1:$PORT"
base2="http://127.0.0.1:$PORT2"

# 列表页（Accept */* 不触发 token-302，直接拿内容）。
get(){ curl -s -H "Accept-Language: $2" "$1/?t=$TOK"; }

echo "── 英文 Accept-Language → 英文列表页"
EN="$(get "$base" 'en-US,en;q=0.9')"
echo "$EN" | grep -q 'html lang="en"'          && ok "html lang=en"            || bad "缺 html lang=en"
echo "$EN" | grep -q 'Served by <b>LocalShare</b>' && ok "英文署名"             || bad "缺英文署名"
echo "$EN" | grep -q 'Search this folder'       && ok "英文搜索占位"            || bad "缺英文搜索占位"
echo "$EN" | grep -q 'Read-only'                && ok "英文「Read-only」"        || bad "缺英文 Read-only"

echo "── 中文 Accept-Language → 中文列表页"
ZH="$(get "$base" 'zh-CN,zh;q=0.9')"
echo "$ZH" | grep -q 'html lang="zh-Hans"'      && ok "html lang=zh-Hans"        || bad "缺 html lang=zh-Hans"
echo "$ZH" | grep -q '搜索此文件夹'              && ok "中文搜索占位"            || bad "缺中文搜索占位"
echo "$ZH" | grep -q '只读'                      && ok "中文「只读」"            || bad "缺中文 只读"

echo "── 不带 Accept-Language → 中文基准"
NB="$(curl -s "$base/?t=$TOK")"
echo "$NB" | grep -q 'html lang="zh-Hans"'      && ok "缺头回退 zh-Hans"         || bad "缺头未回退中文"

echo "── 逐请求独立：同一 server 背靠背两种语言"
A="$(get "$base" 'en' | grep -c 'html lang="en"')"
B="$(get "$base" 'zh' | grep -c 'html lang="zh-Hans"')"
[ "$A" = "1" ] && [ "$B" = "1" ] && ok "同 server 两请求各得其语" || bad "逐请求语言未独立（en=$A zh=$B）"

echo "── 403 页随头本地化"
F_EN="$(curl -s -H 'Accept-Language: en' "$base/")"   # 无 token
echo "$F_EN" | grep -q 'No access'               && ok "403 英文"                || bad "403 未英文"
F_ZH="$(curl -s -H 'Accept-Language: zh' "$base/")"
echo "$F_ZH" | grep -q '无法访问'                 && ok "403 中文"                || bad "403 未中文"

echo "── 多选虚拟根名随头"
M_EN="$(get "$base2" 'en')"; M_ZH="$(get "$base2" 'zh')"
echo "$M_EN" | grep -q 'Shared items' && ok "多选根 en=Shared items" || bad "多选根缺 Shared items"
echo "$M_ZH" | grep -q '分享内容'      && ok "多选根 zh=分享内容"     || bad "多选根缺 分享内容"

echo
echo "结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
