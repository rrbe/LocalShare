#!/usr/bin/env bash
# 防回归冒烟测：多选虚拟根路由（LS_FOLDERS）。多选无共同磁盘根，合成一个虚拟根列出选中项，
# 其余请求拆首段 key 映射到真实 URL。验：① 空根列出选中项；② 文件项按 key 取内容；
# ③ 目录项进子树（含嵌套）；④ 未知 key → 404；⑤ 文件项带子路径 → 404；⑥ 跨目录重名 key 以
# -2 兜底且各自可达；⑦ 每项各自为根，子目录项内 ../ 逃不出该项（per-item 防穿越）。
# 用法：./tools/smoke-multiselect.sh   退出码 0=全过。
set -u
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8   # 断言含中文，统一 UTF-8 locale（见 smoke-filenames.sh）
BIN="${BIN:-.build/debug/LocalShare}"
[ -x "$BIN" ] || { echo "找不到 $BIN，先跑 swift build"; exit 2; }

TOK="multitest"
BASE="$(mktemp -d)"
echo AAA        > "$BASE/fileA.txt"
mkdir -p "$BASE/dirB/sub"
echo BBB-INSIDE > "$BASE/dirB/inside.txt"
echo DEEP       > "$BASE/dirB/sub/deep.txt"
mkdir -p "$BASE/d1" "$BASE/d2"
echo DUP1       > "$BASE/d1/dup.txt"          # 与 d2/dup.txt 同名，验 key 去重
echo DUP2       > "$BASE/d2/dup.txt"
echo ESCAPED    > "$BASE/escape-target.txt"   # 未分享，验 per-item 防穿越

PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }

PORT=$(( (RANDOM % 10000) + 40000 ))
LS_HEADLESS=1 LS_FOLDERS="$BASE/fileA.txt:$BASE/dirB:$BASE/d1/dup.txt:$BASE/d2/dup.txt" \
  LS_TOKEN="$TOK" LS_PORT="$PORT" "$BIN" >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -rf "$BASE"' EXIT
base="http://127.0.0.1:$PORT"
for _ in $(seq 1 50); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$base/?t=$TOK")" = "200" ] && break
  sleep 0.1
done

code(){ curl -s -o /dev/null -w '%{http_code}' --path-as-is "$base/$1?t=$TOK"; }
body(){ curl -s  --path-as-is "$base/$1?t=$TOK"; }

echo "── 虚拟根列出选中项"
R=$(curl -s "$base/?t=$TOK")
echo "$R" | grep -q "分享内容" && ok "根标题为「分享内容」" || bad "根标题缺「分享内容」"
for k in "fileA.txt" "dirB" "dup.txt"; do
  echo "$R" | grep -q "$k" && ok "根列出 ${k}" || bad "根缺 ${k}"
done

echo "── 文件项按 key 取内容"
[ "$(body fileA.txt)" = "AAA" ] && ok "/fileA.txt → AAA" || bad "/fileA.txt 应 AAA"

echo "── 目录项进子树（含嵌套）"
curl -sL --path-as-is "$base/dirB/?t=$TOK" | grep -q "inside.txt" && ok "/dirB/ 列出 inside.txt" || bad "/dirB/ 未列 inside.txt"
[ "$(body dirB/inside.txt)" = "BBB-INSIDE" ] && ok "/dirB/inside.txt → BBB-INSIDE" || bad "/dirB/inside.txt 应 BBB-INSIDE"
[ "$(body dirB/sub/deep.txt)" = "DEEP" ] && ok "/dirB/sub/deep.txt → DEEP" || bad "/dirB/sub/deep.txt 应 DEEP"

echo "── 未知 key / 文件项带子路径 → 404"
[ "$(code nope.txt)" = "404" ] && ok "未知 key → 404" || bad "未知 key 应 404，实为 $(code nope.txt)"
[ "$(code fileA.txt/extra)" = "404" ] && ok "文件项带子路径 → 404" || bad "文件项带子路径应 404，实为 $(code fileA.txt/extra)"

echo "── 跨目录重名 key 以 -2 兜底，各自可达"
[ "$(body dup.txt)" = "DUP1" ]   && ok "/dup.txt → DUP1（首个）" || bad "/dup.txt 应 DUP1"
[ "$(body dup-2.txt)" = "DUP2" ] && ok "/dup-2.txt → DUP2（兜底 key）" || bad "/dup-2.txt 应 DUP2"

echo "── per-item 防穿越：子目录项内 ../ 逃不出该项、不泄露未分享文件"
c=$(code "dirB/..%2fescape-target.txt"); b=$(body "dirB/..%2fescape-target.txt")
if [ "$c" = "403" ] && ! echo "$b" | grep -q ESCAPED; then
  ok "/dirB/..%2fescape-target.txt → 403、未泄露"
else
  bad "应 403 且不泄露，实为 ${c}"
fi

echo
echo "结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
