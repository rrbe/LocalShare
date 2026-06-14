#!/usr/bin/env bash
# 防回归冒烟测：token-302 清洗。浏览器首访经 ?t= 进入后，立刻 302 到去掉 ?t= 的干净 URL
# （token 不残留地址栏/浏览历史），同时种下 cookie；curl/脚本（Accept */*）不受影响、照旧直接拿内容。
# 用法： ./tools/smoke-token-302.sh    退出码 0=全过。
set -u
BIN="${BIN:-.build/debug/LocalShare}"
[ -x "$BIN" ] || { echo "找不到 $BIN，先跑 swift build"; exit 2; }

PORT=$(( (RANDOM % 10000) + 40000 )); TOK="tok302test"
ROOT="$(mktemp -d)"; echo hi > "$ROOT/a.txt"
PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }

LS_HEADLESS=1 LS_FOLDER="$ROOT" LS_TOKEN="$TOK" LS_PORT="$PORT" "$BIN" >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -rf "$ROOT"' EXIT
for _ in $(seq 1 50); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/?t=$TOK")" = "200" ] && break
  sleep 0.1
done
base="http://127.0.0.1:$PORT"

echo "── 浏览器导航（Accept: text/html）首访被 302 清洗"
H=$(curl -s -D - -o /dev/null -H 'Accept: text/html' "$base/?t=$TOK")
echo "$H" | head -1 | grep -qi ' 302 ' && ok "返回 302" || bad "非 302：$(echo "$H" | head -1)"
LOC=$(echo "$H" | grep -i '^Location:' | tr -d '\r')
echo "$LOC" | grep -q 't=' && bad "Location 仍含 token: ${LOC}" || ok "Location 去掉了 ?t=, 现为: ${LOC}"
echo "$H" | grep -qi '^Set-Cookie: *ls_token=' && ok "302 同时种下 cookie" || bad "302 未种 cookie"

echo "── 其它 query 参数保留、仅删 t"
H2=$(curl -s -D - -o /dev/null -H 'Accept: text/html' "$base/?t=$TOK&foo=bar")
echo "$H2" | grep -i '^Location:' | grep -q 'foo=bar' && ok "保留 foo=bar" || bad "未保留其它参数：$(echo "$H2" | grep -i '^Location:')"

echo "── curl/脚本（Accept: */*）不被重定向，直接拿内容"
C=$(curl -s -o /dev/null -w '%{http_code}' "$base/?t=$TOK")
[ "$C" = "200" ] && ok "Accept */* 直接 200（未 302）" || bad "应 200 实为 $C"

echo "── 跟随 302 后，带 cookie 能正常访问"
C2=$(curl -s -o /dev/null -w '%{http_code}' -b "ls_token=$TOK" "$base/")
[ "$C2" = "200" ] && ok "cookie 鉴权访问 200" || bad "cookie 访问应 200 实为 $C2"

echo
echo "结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
