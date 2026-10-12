#!/usr/bin/env bash
# 防回归冒烟测：可信转发请求只读，局域网上传和文本权限保持独立。
set -u
curl(){ command curl --max-time 5 -H 'X-LocalShare-Client-IP: 203.0.113.10' "$@"; }

BIN="${BIN:-.build/debug/LocalShare}"
[ -x "$BIN" ] || { echo "找不到 $BIN，先跑 swift build"; exit 2; }

PORT=$(( (RANDOM % 10000) + 44000 ))
TOK="remote-readonly-test"
ROOT="$(mktemp -d)"
echo hi > "$ROOT/a.txt"
printf '# Preview\n' > "$ROOT/preview.md"
printf '{"preview":true}\n' > "$ROOT/preview.json"
printf 'name,value\npreview,1\n' > "$ROOT/preview.csv"
PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }

LS_HEADLESS=1 LS_FOLDER="$ROOT" LS_TEXT=secret LS_REMOTE_AUTH=relay-secret LS_UPLOAD=1 LS_RECV=1 \
  LS_TOKEN="$TOK" LS_PORT="$PORT" "$BIN" >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -rf "$ROOT"' EXIT

base="http://127.0.0.1:$PORT"
share_file_path="/a.txt"
for _ in $(seq 1 50); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$base/?t=$TOK")" != "000" ] && break
  sleep 0.1
done

echo "── 无 token 仍返回 403"
S=$(curl -s -o /dev/null -w '%{http_code}' "$base/")
[ "$S" = "403" ] && ok "无 token 403" || bad "应 403 实为 $S"

echo "── 远程模式拒绝上传与收文本"
S=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-LocalShare-Relay: relay-secret' -X POST -F 'f=@/etc/hosts' "$base/?t=$TOK")
[ "$S" = "405" ] && ok "上传 405" || bad "上传应 405 实为 $S"
S=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-LocalShare-Relay: relay-secret' -X POST --data-binary 'x' "$base/ls/text?t=$TOK")
[ "$S" = "405" ] && ok "收文本 405" || bad "收文本应 405 实为 $S"
S=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-LocalShare-Relay: relay-secret' "$base/ls/text?t=$TOK&raw=1")
[ "$S" = "200" ] && ok "远程共享文本可读" || bad "共享文本应 200 实为 $S"
echo "── 网页权限标识反映访问范围"
for locale in zh-CN en-US; do
  if [ "$locale" = zh-CN ]; then remote_label='互联网 · 只读分享'; local_label='局域网 ·';
  else remote_label='Internet · read-only share'; local_label='LAN ·'; fi
  for path in / /ls/text /preview.md /preview.json /preview.csv; do
    remote_html=$(curl -fs -H 'Accept: text/html' -H "Accept-Language: $locale" \
      -H "Cookie: ls_token=$TOK" -H 'X-LocalShare-Relay: relay-secret' "$base$path")
    local_html=$(curl -fs -H 'Accept: text/html' -H "Accept-Language: $locale" \
      -H "Cookie: ls_token=$TOK" "$base$path")
    if printf '%s' "$remote_html" | grep -Fq "$remote_label" && \
       printf '%s' "$local_html" | grep -Fq "$local_label"; then
      ok "$locale $path 区分互联网与局域网权限"
    else bad "$locale $path 的访问范围标识错误"; fi
  done
done
echo "── 局域网权限独立"
S=$(curl -s -o /dev/null -w '%{http_code}' -X POST -F 'f=@/etc/hosts' "$base/?t=$TOK")
[ "$S" = "200" ] && ok "局域网上传仍可用" || bad "局域网上传应 200 实为 $S"
S=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary 'local text' "$base/ls/text?t=$TOK")
[ "$S" = "200" ] && ok "局域网收文本仍可用" || bad "局域网收文本应 200 实为 $S"
S=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-LocalShare-Relay: visitor-forged' -X POST --data-binary 'local text' "$base/ls/text?t=$TOK")
[ "$S" = "200" ] && ok "伪造身份头不改变局域网权限" || bad "身份边界错误 $S"

echo "── 远程模式仍可读取并支持 Range"
S=$(curl -s -o /dev/null -w '%{http_code}' "$base$share_file_path?t=$TOK")
[ "$S" = "200" ] && ok "读取 200" || bad "读取应 200 实为 $S"
S=$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=0-1' "$base$share_file_path?t=$TOK")
[ "$S" = "206" ] && ok "Range 206" || bad "Range 应 206 实为 $S"

echo
echo "结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
