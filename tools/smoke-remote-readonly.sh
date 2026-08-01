#!/usr/bin/env bash
# 防回归冒烟测：远程模式只读、拒绝 POST、并只在受信任 HTTPS 转发请求上使用 Secure cookie。
set -u

BIN="${BIN:-.build/debug/LocalShare}"
[ -x "$BIN" ] || { echo "找不到 $BIN，先跑 swift build"; exit 2; }

PORT=$(( (RANDOM % 10000) + 44000 ))
TOK="remote-readonly-test"
ROOT="$(mktemp -d)"
echo hi > "$ROOT/a.txt"
PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }

LS_HEADLESS=1 LS_FOLDER="$ROOT" LS_REMOTE=1 LS_UPLOAD=1 LS_RECV=1 \
  LS_TOKEN="$TOK" LS_PORT="$PORT" "$BIN" >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -rf "$ROOT"' EXIT

base="http://127.0.0.1:$PORT"
for _ in $(seq 1 50); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$base/?t=$TOK")" != "000" ] && break
  sleep 0.1
done

echo "── 无 token 仍返回 403"
S=$(curl -s -o /dev/null -w '%{http_code}' "$base/")
[ "$S" = "403" ] && ok "无 token 403" || bad "应 403 实为 $S"

echo "── 远程模式拒绝上传与收文本"
S=$(curl -s -o /dev/null -w '%{http_code}' -X POST -F 'f=@/etc/hosts' "$base/?t=$TOK")
[ "$S" = "405" ] && ok "上传 405" || bad "上传应 405 实为 $S"
S=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary 'x' "$base/ls/text?t=$TOK")
[ "$S" = "405" ] && ok "收文本 405" || bad "收文本应 405 实为 $S"

echo "── 仅受信任 HTTPS 转发请求的 cookie 带 Secure"
H=$(curl -s -D - -o /dev/null -H 'Accept: text/html' \
  -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-For: 203.0.113.4' "$base/?t=$TOK")
echo "$H" | grep -qi '^Set-Cookie:.*Secure' && ok "Secure cookie" || bad "缺 Secure cookie"

echo
echo "结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
