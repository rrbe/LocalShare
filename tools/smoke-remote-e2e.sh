#!/usr/bin/env bash
# 真正贯通 Browser -> Go Server -> WebSocket -> Swift RemoteAgent -> FileServer。
set -u

CLIENT_BIN="${CLIENT_BIN:-.build/debug/LocalShare}"
[ -x "$CLIENT_BIN" ] || { echo "找不到 $CLIENT_BIN，先跑 swift build"; exit 2; }

TMP="$(mktemp -d)"
STATE="$TMP/state"
SHARE="$TMP/share"
SERVER_BIN="$TMP/localshare-server"
SERVER_PORT=$(( (RANDOM % 8000) + 36000 ))
LOCAL_PORT=$(( SERVER_PORT + 9000 ))
mkdir -p "$SHARE/sub folder"
printf 'hello remote\n' > "$SHARE/a.txt"
printf 'nested\n' > "$SHARE/sub folder/b.txt"

SERVER_PID=""
CLIENT_PID=""
cleanup(){
  [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null || true
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$CLIENT_PID" ] && wait "$CLIENT_PID" 2>/dev/null || true
  [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

(cd server && go build -o "$SERVER_BIN" .)
ENROLLMENT_KEY=$("$SERVER_BIN" key create --name smoke --state-dir "$STATE" | awk '/^key: /{print $2}')
[ -n "$ENROLLMENT_KEY" ] || { echo "未生成 Enrollment Key"; exit 1; }

SERVER_URL="http://127.0.0.1:$SERVER_PORT"
"$SERVER_BIN" serve --listen "127.0.0.1:$SERVER_PORT" --public-url "$SERVER_URL" \
  --state-dir "$STATE" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!

LS_HEADLESS=1 LS_FOLDER="$SHARE" LS_TOKEN=e2e-local-token LS_PORT="$LOCAL_PORT" LS_REMOTE=1 \
  LS_REMOTE_SERVER="$SERVER_URL" LS_REMOTE_KEY="$ENROLLMENT_KEY" \
  "$CLIENT_BIN" >"$TMP/client.log" 2>&1 &
CLIENT_PID=$!

REMOTE_URL=""
for _ in $(seq 1 100); do
  REMOTE_URL=$(awk '/^LS_REMOTE_URL /{print $2; exit}' "$TMP/client.log")
  [ -n "$REMOTE_URL" ] && break
  if ! kill -0 "$CLIENT_PID" 2>/dev/null; then
    cat "$TMP/client.log"
    exit 1
  fi
  sleep 0.1
done
[ -n "$REMOTE_URL" ] || { cat "$TMP/server.log"; cat "$TMP/client.log"; exit 1; }

PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "── 公开 URL 规范化并保留 share 前缀"
NO_SLASH=${REMOTE_URL%/}
LOCATION=$(curl -s -o /dev/null -w '%{redirect_url}' "$NO_SLASH")
[ "$LOCATION" = "$REMOTE_URL" ] && ok "无斜杠入口重定向" || bad "重定向为 $LOCATION"

echo "── 目录 HTML 使用相对导航"
HTML=$(curl -s "$REMOTE_URL")
printf '%s' "$HTML" | grep -q 'href="a.txt"' && ok "文件链接相对" || bad "缺少相对文件链接"
printf '%s' "$HTML" | grep -q 'var LS_ROOT=""' && ok "页面根相对" || bad "页面根仍为绝对路径"
NESTED_HTML=$(curl -s "${REMOTE_URL}sub%20folder/")
printf '%s' "$NESTED_HTML" | grep -q 'href="b.txt"' && ok "嵌套目录链接相对" || bad "嵌套目录链接错误"
printf '%s' "$NESTED_HTML" | grep -q 'href="../"' && ok "面包屑保留挂载前缀" || bad "面包屑根链接错误"

echo "── 远程读取、嵌套目录与 Range"
[ "$(curl -s "${REMOTE_URL}a.txt")" = "hello remote" ] && ok "读取文件" || bad "读取文件失败"
[ "$(curl -s "${REMOTE_URL}sub%20folder/b.txt")" = "nested" ] && ok "读取嵌套文件" || bad "读取嵌套文件失败"
RANGE=$(curl -s -H 'Range: bytes=0-4' "${REMOTE_URL}a.txt")
[ "$RANGE" = "hello" ] && ok "Range" || bad "Range 返回 $RANGE"

echo
echo "结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
