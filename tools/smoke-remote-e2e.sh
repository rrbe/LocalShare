#!/usr/bin/env bash
# 真正贯通 Browser -> Go Server -> WebSocket -> Swift RemoteAgent -> FileServer。
set -u
curl(){ command curl --max-time 10 "$@"; }

CLIENT_BIN="${CLIENT_BIN:-.build/debug/LocalShare}"
[ -x "$CLIENT_BIN" ] || { echo "找不到 $CLIENT_BIN，先跑 swift build"; exit 2; }

TMP="$(mktemp -d)"
STATE="$TMP/state"
SHARE="$TMP/share"
SERVER_BIN="$TMP/localshare-server"
SERVER_PORT=$(( (RANDOM % 8000) + 36000 ))
LOCAL_PORT=$(( SERVER_PORT + 9000 ))
mkdir -p "$SHARE/sub folder"
# Random bytes keep macOS memory compression from hiding whole-file buffering.
dd if=/dev/urandom of="$SHARE/large.bin" bs=1048576 count=256 2>/dev/null
: > "$SHARE/empty.bin"
dd if=/dev/urandom of="$SHARE/check.bin" bs=1048576 count=8 2>/dev/null
printf 'hello remote\n' > "$SHARE/a.txt"
printf 'nested\n' > "$SHARE/sub folder/b.txt"
# A PNG fixture with an encoded filename exercises the mounted thumbnail endpoint.
python3 - "$SHARE/sub folder/中文 100%.png" <<'PYIMAGE'
import struct, sys, zlib
from pathlib import Path
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(b'\x00\xff\x00\x00\x00\xff\x00' * 2))
Path(sys.argv[1]).write_bytes(png + chunk(b'IEND', b''))
PYIMAGE

SERVER_PID=""
CLIENT_PID=""
cleanup(){
  [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null || true
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$CLIENT_PID" ] && wait "$CLIENT_PID" 2>/dev/null || true
  [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null || true
  if [ "${SMOKE_KEEP_TMP:-0}" = 1 ]; then echo "Debug artifacts: $TMP"; else rm -rf "$TMP"; fi
}
trap cleanup EXIT

(cd server && go build -o "$SERVER_BIN" .)
ENROLLMENT_KEY=$("$SERVER_BIN" key create --name smoke --state-dir "$STATE" | awk '/^key: /{print $2}')
[ -n "$ENROLLMENT_KEY" ] || { echo "未生成 Enrollment Key"; exit 1; }

SERVER_URL="http://127.0.0.1:$SERVER_PORT"
SHARED_TEXT=$'你好 <b>hello</b>\n第二行 "引号" % & </script><script>alert("x")</script>'
"$SERVER_BIN" serve --listen "127.0.0.1:$SERVER_PORT" --public-url "$SERVER_URL" \
  --state-dir "$STATE" --registration >"$TMP/server.log" 2>&1 &
SERVER_PID=$!

LS_HEADLESS=1 LS_FOLDER="$SHARE" LS_TOKEN=e2e-local-token LS_PORT="$LOCAL_PORT" LS_REMOTE=1 \
  LS_REMOTE_SERVER="$SERVER_URL" LS_REMOTE_REGISTER=1 LS_TEXT="$SHARED_TEXT" LS_REMOTE_RECV=1 LS_RECV_LOG="$TMP/received.txt" \
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

echo "── 远程媒体预览与只读边界"
printf '%s' "$NESTED_HTML" | grep -q 'var LS_BATCH_DOWNLOAD=false' && ok "远程隐藏批量下载" || bad "远程仍显示批量下载"
printf '%s' "$NESTED_HTML" | grep -q "LS_ROOT+'ls/thumbnail" && ok "缩略图使用挂载内端点" || bad "缩略图端点逃出分享"
THUMBNAIL_STATUS=$(curl -s -o "$TMP/thumbnail.jpg" -w '%{http_code}' --get --data-urlencode 'path=/sub folder/中文 100%.png' "${REMOTE_URL}ls/thumbnail")
[ "$THUMBNAIL_STATUS" = "200" ] && sips -g format "$TMP/thumbnail.jpg" | grep -q 'format: jpeg' && ok "嵌套中文百分号文件缩略图" || bad "缩略图返回 $THUMBNAIL_STATUS"
POST_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-urlencode 'paths=["/a.txt"]' "${REMOTE_URL}ls/download")
[ "$POST_STATUS" = "405" ] && ok "远程拒绝 POST 下载" || bad "远程 POST 返回 $POST_STATUS"

echo "── 远程读取、嵌套目录与 Range"
[ "$(curl -s "${REMOTE_URL}a.txt")" = "hello remote" ] && ok "读取文件" || bad "读取文件失败"
[ "$(curl -s "${REMOTE_URL}sub%20folder/b.txt")" = "nested" ] && ok "读取嵌套文件" || bad "读取嵌套文件失败"
RANGE=$(curl -s -H 'Range: bytes=0-4' "${REMOTE_URL}a.txt")
[ "$RANGE" = "hello" ] && ok "Range" || bad "Range 返回 $RANGE"

echo "── 远程文本与接收权限"
TEXT=$(curl -s "${REMOTE_URL}ls/text?raw=1")
[ "$TEXT" = "$SHARED_TEXT" ] && ok "读取中文文本原文" || bad "文本原文错误"
TEXT_HTML=$(curl -s -H 'Accept: text/html' -H 'Accept-Language: zh-CN' "${REMOTE_URL}ls/text")
printf '%s' "$TEXT_HTML" | grep -q 'copybtn' && ok "浏览器复制页面" || bad "文本页面缺少复制"
printf '%s' "$TEXT_HTML" | grep -q 'href="../"' && ok "文本返回分享根目录" || bad "文本返回链接错误"
printf '%s' "$TEXT_HTML" > "$TMP/text-page.html"
python3 - "$TMP/text-page.html" "$TEXT" <<'PYTEXT'
import json, re, sys
from pathlib import Path
html = Path(sys.argv[1]).read_text()
match = re.search(r'var LS_TEXT=("(?:[^"\\]|\\.)*");', html)
assert match and json.loads(match[1]) == sys.argv[2], 'viewer text differs from raw content'
assert '<' not in match[1], 'unescaped HTML in embedded text'
PYTEXT
[ "$?" -eq 0 ] && ok "文本转义并保留换行和特殊字符" || bad "文本转义错误"
EN_TEXT_HTML=$(curl -s -H 'Accept: text/html' -H 'Accept-Language: en-US' "${REMOTE_URL}ls/text")
printf '%s' "$TEXT_HTML" | grep -q '<html lang="zh-Hans"' && printf '%s' "$EN_TEXT_HTML" | grep -q '<html lang="en"' && ok "远程页面按浏览器语言显示" || bad "浏览器语言未生效"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary $'远程 + % 文本\n第二行' "${REMOTE_URL}ls/text")
[ "$STATUS" = "200" ] && grep -q '远程 + % 文本' "$TMP/received.txt" && ok "文本发回 Mac" || bad "接收失败 $STATUS"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary "@${SHARE}/large.bin" "${REMOTE_URL}ls/text")
[ "$STATUS" = "413" ] && ok "拒绝超大文本" || bad "超大文本返回 $STATUS"
[ "$(curl -s -o /dev/null -w '%{http_code}' "${REMOTE_URL}empty.bin")" = "200" ] && ok "空文件及时完成" || bad "空文件失败"
curl -s "${REMOTE_URL}check.bin" -o "$TMP/download.bin" && cmp -s "$SHARE/check.bin" "$TMP/download.bin" && ok "8 MiB 下载逐字一致" || bad "大文件下载截断"
echo "── HTML 及时完整结束"
for _ in $(seq 1 30); do
  curl -s --max-time 3 "$REMOTE_URL" -o "$TMP/page.html" || { bad "HTML 响应未及时结束"; break; }
  grep -q '</html>' "$TMP/page.html" || { bad "HTML 正文截断"; break; }
done
[ "$FAIL" -eq 0 ] && ok "30 次目录响应完成"
echo "── 慢下载与内存上限"
BASE_RSS=$(ps -o rss= -p "$CLIENT_PID" | tr -d ' ')
command curl -s --max-time 5 --limit-rate 64k "${REMOTE_URL}large.bin" -o /dev/null &
SLOW_PID=$!
PEAK_RSS=$BASE_RSS
for _ in $(seq 1 10); do
  sleep 0.3
  RSS=$(ps -o rss= -p "$CLIENT_PID" | tr -d ' ')
  [ "$RSS" -gt "$PEAK_RSS" ] && PEAK_RSS=$RSS
  [ "$(curl -sS --max-time 2 "${REMOTE_URL}a.txt")" = "hello remote" ] || { bad "慢下载影响其他请求"; break; }
done
wait "$SLOW_PID" 2>/dev/null || true
GROWTH=$((PEAK_RSS-BASE_RSS))
echo "  Client RSS growth: ${GROWTH} KiB (256 MiB random file)"
[ "$GROWTH" -lt 65536 ] && ok "慢下载内存有界" || bad "内存随文件增长"
[ "$(curl -sS --max-time 2 "${REMOTE_URL}a.txt")" = "hello remote" ] && ok "取消后可继续读取" || bad "取消后请求失败"
echo "── 在线撤销"
DEVICE_ID=$("$SERVER_BIN" device list --state-dir "$STATE" | awk 'NR==1{print $1}')
"$SERVER_BIN" device revoke --state-dir "$STATE" "$DEVICE_ID" >/dev/null
sleep 2
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$REMOTE_URL")
[ "$STATUS" = "404" ] && ok "撤销后公开链接失效" || bad "撤销后返回 $STATUS"
echo "── 纯文本和默认关闭的接收"
kill "$CLIENT_PID" 2>/dev/null; wait "$CLIENT_PID" 2>/dev/null || true
LS_HEADLESS=1 LS_TEXT='text only' LS_TOKEN=text-only LS_PORT="$LOCAL_PORT" LS_REMOTE=1 \
  LS_REMOTE_SERVER="$SERVER_URL" LS_REMOTE_KEY="$ENROLLMENT_KEY" \
  "$CLIENT_BIN" >"$TMP/text-client.log" 2>&1 &
CLIENT_PID=$!
TEXT_URL=""
for _ in $(seq 1 100); do
  TEXT_URL=$(awk '/^LS_REMOTE_URL /{print $2;exit}' "$TMP/text-client.log")
  [ -n "$TEXT_URL" ] && break
  sleep 0.1
done
[ -n "$TEXT_URL" ] && [ "$(curl -s "${TEXT_URL}ls/text?raw=1")" = "text only" ] && ok "纯文本远程分享" || bad "纯文本连接失败"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary test "${TEXT_URL}ls/text")
[ "$STATUS" = "403" ] && ok "远程收文本默认关闭" || bad "默认接收返回 $STATUS"
echo
echo "结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
