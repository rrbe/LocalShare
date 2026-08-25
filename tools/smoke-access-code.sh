#!/usr/bin/env bash
# 短访问码：浏览器无 token 得加入页；正确码换 Cookie；错误码限流；其它无 token 请求仍保持 403。
set -u
BIN="${BIN:-.build/debug/LocalShare}"
[ -x "$BIN" ] || { echo "找不到 $BIN，先跑 swift build"; exit 2; }

PORT=$(( (RANDOM % 8000) + 42000 )); TOK="access-token"; CODE="K7M-PQ2"
ROOT="$(mktemp -d)"; echo hi > "$ROOT/a.txt"
COOKIE="$(mktemp)"; PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }

LS_HEADLESS=1 LS_FOLDER="$ROOT" LS_TOKEN="$TOK" LS_ACCESS_CODE="$CODE" LS_PORT="$PORT" "$BIN" >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -rf "$ROOT" "$COOKIE"' EXIT
for _ in $(seq 1 50); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/?t=$TOK")" = "200" ] && break
  sleep 0.1
done
base="http://127.0.0.1:$PORT"

echo "── 浏览器手输网址显示加入页"
H=$(curl -s -D - -H 'Accept: text/html' -H 'Accept-Language: en' "$base/")
echo "$H" | head -1 | grep -qi ' 200 ' && echo "$H" | grep -q 'Enter Access Code' && ok "无 token 导航显示英文加入页" || bad "加入页缺失"
C=$(curl -s -o /dev/null -w '%{http_code}' "$base/")
[ "$C" = "403" ] && ok "非浏览器请求仍为 403" || bad "非浏览器请求应为 403，实为 $C"

echo "── 错误码拒绝，正确码换取 Cookie"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data 'code=WRONG2' "$base/ls/join")
[ "$C" = "401" ] && ok "错误访问码返回 401" || bad "错误访问码应为 401，实为 $C"
H=$(curl -s -D - -o /dev/null -c "$COOKIE" -X POST --data 'code=k7m+pq2' "$base/ls/join")
echo "$H" | head -1 | grep -qi ' 302 ' && echo "$H" | grep -qi '^Set-Cookie: *ls_token=' && ok "正确访问码返回 302 并种 Cookie" || bad "正确访问码未换取 Cookie"
C=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE" "$base/")
[ "$C" = "200" ] && ok "访问码 Cookie 可读取分享" || bad "Cookie 访问应为 200，实为 $C"

echo "── 连续错误触发限流"
for _ in 1 2 3 4 5; do curl -s -o /dev/null -X POST --data 'code=BADBAD' "$base/ls/join"; done
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data 'code=BADBAD' "$base/ls/join")
[ "$C" = "429" ] && ok "第六次错误被限流" || bad "第六次错误应为 429，实为 $C"

echo
echo "结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
