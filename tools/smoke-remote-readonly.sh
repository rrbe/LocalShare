#!/usr/bin/env bash
# 防回归冒烟测：远程模式只读，并验证文件流支持 Range。
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

LS_HEADLESS=1 LS_FOLDER="$ROOT" LS_TEXT=secret LS_REMOTE=1 LS_UPLOAD=1 LS_RECV=1 \
  LS_TOKEN="$TOK" LS_PORT="$PORT" "$BIN" >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -rf "$ROOT"' EXIT

base="http://127.0.0.1:$PORT"
share_file_path="/$(basename "$ROOT")/a.txt"
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
S=$(curl -s -o /dev/null -w '%{http_code}' "$base/ls/text?t=$TOK")
[ "$S" = "404" ] && ok "共享文本不公开" || bad "共享文本应 404 实为 $S"

echo "── 远程模式仍可读取并支持 Range"
S=$(curl -s -o /dev/null -w '%{http_code}' "$base$share_file_path?t=$TOK")
[ "$S" = "200" ] && ok "读取 200" || bad "读取应 200 实为 $S"
S=$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=0-1' "$base$share_file_path?t=$TOK")
[ "$S" = "206" ] && ok "Range 206" || bad "Range 应 206 实为 $S"

echo
echo "结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
