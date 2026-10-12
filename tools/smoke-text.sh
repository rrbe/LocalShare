#!/usr/bin/env bash
# 防回归冒烟测：传递文本（Mac→手机，v1）。覆盖纯文本分享与文本+文件共存两形态：
#  · /ls/text 保留端点：导航发预览壳页、?raw=1/curl 发 text/plain 原文、无 token 被 403；
#  · 文本里的 < 被转义成 <（挡 </script> 注入），壳页带复制按钮 + execCommand 回退；
#  · 纯文本分享 URL 直指 /ls/text；文本+文件时虚拟根列出指向 /ls/text 的文本行；
#  · 未分享文本时 /ls/text 返回 404。
# 用法： ./tools/smoke-text.sh    退出码 0=全过。
set -u
BIN="${BIN:-.build/debug/LocalShare}"
[ -x "$BIN" ] || { echo "找不到 $BIN，先跑 swift build"; exit 2; }

PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }

wait_up(){ # $1=port $2=path
  for _ in $(seq 1 50); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1$2?t=$TOK")" != "000" ] && return 0
    sleep 0.1
  done
}

TOK="toktext"

# ── 1. 纯文本分享 ─────────────────────────────────────────────
PORT=$(( (RANDOM % 10000) + 41000 ))
TEXT=$'Hello 你好 <b>x</b>\nsecond line https://example.com/p?q=1 end'
LS_HEADLESS=1 LS_TEXT="$TEXT" LS_TOKEN="$TOK" LS_PORT="$PORT" "$BIN" >/tmp/ls_text_url.$$ 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -f /tmp/ls_text_url.$$' EXIT
wait_up "$PORT" "/ls/text"
base="http://127.0.0.1:$PORT"

echo "── 纯文本：headless URL 直指 /ls/text"
grep -q "LS_URL .*/ls/text?t=$TOK" /tmp/ls_text_url.$$ && ok "URL 指向 /ls/text" || bad "URL 未指向 /ls/text：$(cat /tmp/ls_text_url.$$)"

echo "── /ls/text?raw=1（curl）发 text/plain 原文"
RAW=$(curl -s "$base/ls/text?t=$TOK&raw=1")
[ "$RAW" = "$TEXT" ] && ok "原文逐字一致" || bad "原文不一致：$RAW"
H=$(curl -s -D - -o /dev/null "$base/ls/text?t=$TOK&raw=1")
echo "$H" | grep -qi '^Content-Type: *text/plain; *charset=utf-8' && ok "Content-Type text/plain" || bad "类型错：$(echo "$H" | grep -i content-type)"
echo "$H" | grep -qi '^X-Content-Type-Options: *nosniff' && ok "带 nosniff" || bad "缺 nosniff"

echo "── 导航（Accept text/html）首访 302 清洗 token"
S=$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: text/html' "$base/ls/text?t=$TOK")
[ "$S" = "302" ] && ok "302 清洗" || bad "应 302 实为 $S"

echo "── 壳页（cookie）含复制按钮 + execCommand 回退，且 < 被转义"
P=$(curl -s -H 'Accept: text/html' -b "ls_token=$TOK" "$base/ls/text")
echo "$P" | grep -q 'id="copybtn"' && ok "含复制按钮" || bad "缺复制按钮"
echo "$P" | grep -q 'execCommand' && ok "含 execCommand 回退" || bad "缺 execCommand 回退"
echo "$P" | grep -q 'var LS_TEXT="Hello 你好 \\u003cb' && ok "文本里的 < 转义为 \\u003c" || bad "< 未正确转义"
echo "$P" | grep -q '<script>var LS_TEXT=.*<b>x</b>' && bad "页面内出现未转义的 <b>（注入风险）" || ok "无未转义 <b> 注入"

echo "── 无 token → 403"
S=$(curl -s -o /dev/null -w '%{http_code}' "$base/ls/text")
[ "$S" = "403" ] && ok "无 token 403" || bad "应 403 实为 $S"

kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

# ── 2. 文本 + 文件 ────────────────────────────────────────────
PORT=$(( (RANDOM % 10000) + 42000 ))
ROOT="$(mktemp -d)"; echo hi > "$ROOT/a.txt"
LS_HEADLESS=1 LS_FOLDER="$ROOT" LS_TEXT="snippet preview line" LS_TOKEN="$TOK" LS_PORT="$PORT" "$BIN" >/dev/null 2>&1 &
SRV=$!
wait_up "$PORT" "/"
base="http://127.0.0.1:$PORT"

echo "── 文本+文件：虚拟根列出文本行（指向 /ls/text）"
L=$(curl -s -H 'Accept: text/html' -b "ls_token=$TOK" "$base/")
echo "$L" | grep -q 'class="row txtentry' && ok "含文本行" || bad "缺文本行"
echo "$L" | grep -q 'href="ls/text"' && ok "文本行相对链接解析到 /ls/text" || bad "文本行未使用相对 ls/text 链接"
echo "$L" | grep -q 'snippet preview line' && ok "显示首行预览" || bad "缺预览"
S=$(curl -s -o /dev/null -w '%{http_code}' "$base/ls/text?t=$TOK&raw=1")
[ "$S" = "200" ] && ok "/ls/text 仍可取文本" || bad "/ls/text 应 200 实为 $S"

kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -rf "$ROOT"

# ── 3. 仅文件、无文本 → /ls/text 404 ─────────────────────────
PORT=$(( (RANDOM % 10000) + 43000 ))
ROOT="$(mktemp -d)"; echo hi > "$ROOT/a.txt"
LS_HEADLESS=1 LS_FOLDER="$ROOT" LS_TOKEN="$TOK" LS_PORT="$PORT" "$BIN" >/dev/null 2>&1 &
SRV=$!
wait_up "$PORT" "/"
base="http://127.0.0.1:$PORT"

echo "── 仅文件、未分享文本 → /ls/text 404"
S=$(curl -s -o /dev/null -w '%{http_code}' "$base/ls/text?t=$TOK")
[ "$S" = "404" ] && ok "无文本时 404" || bad "应 404 实为 $S"

kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -rf "$ROOT"

echo
echo "结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
