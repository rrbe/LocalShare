#!/usr/bin/env bash
# 防回归冒烟测：收文本（手机→Mac，v2）。收发已并入 /ls/text 一页一码。覆盖只收模式、闸门关、共存：
#  · 只收模式 URL 直指 /ls/text；无共享文本时该页退化成发送表单（textarea + 发送钮），首访 302 清洗 token；
#  · POST /ls/text 收原文（text/plain），LOG 回读逐字一致（含 UTF-8 与 < 不被破坏）；
#  · 无 token → 403；空白 → 400；超 64KB → 413；
#  · 旧 /ls/send 仍 302 兼容跳 /ls/text；
#  · 闸门关、无文本（仅文件夹）时 /ls/text 404、POST /ls/text 403、列表页不出发送表单；
#  · 文件夹 + 开收件箱：列表页内嵌发送表单（与上传表单同条件）。
# 用法： ./tools/smoke-text-receive.sh    退出码 0=全过。
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

TOK="tokrecv"

# ── 1. 只收文本模式（无任何分享内容）──────────────────────────
PORT=$(( (RANDOM % 10000) + 41000 ))
LOG="$(mktemp)"
LS_HEADLESS=1 LS_RECV=1 LS_RECV_LOG="$LOG" LS_TOKEN="$TOK" LS_PORT="$PORT" "$BIN" >/tmp/ls_recv_url.$$ 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -f /tmp/ls_recv_url.$$ "$LOG"' EXIT
wait_up "$PORT" "/ls/text"
base="http://127.0.0.1:$PORT"

echo "── 只收模式：headless URL 直指 /ls/text"
grep -q "LS_URL .*/ls/text?t=$TOK" /tmp/ls_recv_url.$$ && ok "URL 指向 /ls/text" || bad "URL 未指向 /ls/text：$(cat /tmp/ls_recv_url.$$)"

echo "── 导航（Accept text/html）首访 302 清洗 token"
S=$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: text/html' "$base/ls/text?t=$TOK")
[ "$S" = "302" ] && ok "302 清洗" || bad "应 302 实为 $S"

echo "── GET /ls/text（cookie，无共享文本）退化成发送表单"
P=$(curl -s -H 'Accept: text/html' -b "ls_token=$TOK" "$base/ls/text")
echo "$P" | grep -q 'id="sendta"' && ok "含输入框" || bad "缺输入框 textarea"
echo "$P" | grep -q 'id="sendbtn"' && ok "含发送按钮" || bad "缺发送按钮"
echo "$P" | grep -Fq "fetch(LS_ROOT+'ls/text'" && ok "脚本投递到挂载前缀下的 ls/text" || bad "未见挂载前缀下的 ls/text 投递"

echo "── 旧 /ls/send 302 兼容跳 /ls/text"
H=$(curl -s -D - -o /dev/null -b "ls_token=$TOK" "$base/ls/send")
echo "$H" | grep -qi '^HTTP/.* 302' && echo "$H" | grep -qi '^Location: */ls/text' && ok "/ls/send → 302 /ls/text" || bad "/ls/send 未 302 跳 /ls/text：$(echo "$H" | tr -d '\r' | head -3 | tr '\n' '|')"

echo "── POST /ls/text 收原文 + LOG 逐字回读（含 UTF-8 与 <）"
MSG=$'Hello 你好 <b>x</b>\n第二行 https://example.com'
S=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary "$MSG" -H 'Content-Type: text/plain' -b "ls_token=$TOK" "$base/ls/text")
[ "$S" = "200" ] && ok "投递 200" || bad "应 200 实为 $S"
# LOG 以 0x01 分隔；取首条比对
GOT=$(printf '%s' "$(cat "$LOG")" | tr -d '\1')
[ "$GOT" = "$MSG" ] && ok "原文逐字一致" || bad "原文不一致：[$GOT]"

echo "── 无 token → 403"
S=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary 'nope' "$base/ls/text")
[ "$S" = "403" ] && ok "无 token 403" || bad "应 403 实为 $S"

echo "── 空白文本 → 400"
S=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary '   ' -H 'Content-Type: text/plain' -b "ls_token=$TOK" "$base/ls/text")
[ "$S" = "400" ] && ok "空白 400" || bad "应 400 实为 $S"

echo "── 超 64KB → 413"
head -c 70000 /dev/zero | tr '\0' 'x' > /tmp/ls_big.$$
S=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary @/tmp/ls_big.$$ -H 'Content-Type: text/plain' -b "ls_token=$TOK" "$base/ls/text")
[ "$S" = "413" ] && ok "超限 413" || bad "应 413 实为 $S"
rm -f /tmp/ls_big.$$

kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

# ── 2. 闸门关（仅文件夹分享，无共享文本）：/ls/text 404、POST 403、列表无表单 ──
PORT=$(( (RANDOM % 10000) + 42000 ))
ROOT="$(mktemp -d)"; echo hi > "$ROOT/a.txt"
LS_HEADLESS=1 LS_FOLDER="$ROOT" LS_TOKEN="$TOK" LS_PORT="$PORT" "$BIN" >/dev/null 2>&1 &
SRV=$!
wait_up "$PORT" "/"
base="http://127.0.0.1:$PORT"

echo "── 闸门关、无文本：/ls/text 404"
S=$(curl -s -o /dev/null -w '%{http_code}' -b "ls_token=$TOK" "$base/ls/text")
[ "$S" = "404" ] && ok "/ls/text 404" || bad "应 404 实为 $S"
echo "── 闸门关：POST /ls/text 403"
S=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary 'x' -b "ls_token=$TOK" "$base/ls/text")
[ "$S" = "403" ] && ok "POST 403" || bad "应 403 实为 $S"
echo "── 闸门关：列表页不出发送表单"
curl -s -b "ls_token=$TOK" "$base/" | grep -q 'id="sendta"' && bad "列表页出现发送表单（不应）" || ok "列表页无发送表单"

kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -rf "$ROOT"

# ── 3. 文件夹 + 开收件箱：列表页内嵌发送表单 ──────────────────
PORT=$(( (RANDOM % 10000) + 43000 ))
ROOT="$(mktemp -d)"; echo hi > "$ROOT/a.txt"
LS_HEADLESS=1 LS_FOLDER="$ROOT" LS_RECV=1 LS_TOKEN="$TOK" LS_PORT="$PORT" "$BIN" >/dev/null 2>&1 &
SRV=$!
wait_up "$PORT" "/"
base="http://127.0.0.1:$PORT"

echo "── 文件夹+收件箱：列表页内嵌发送表单"
L=$(curl -s -b "ls_token=$TOK" "$base/")
echo "$L" | grep -q 'id="sendta"' && ok "列表页含发送表单" || bad "列表页缺发送表单"
echo "$L" | grep -q 'id="sendbtn"' && ok "列表页含发送按钮" || bad "列表页缺发送按钮"
echo "── 文件夹+收件箱：POST /ls/text 仍可投递"
S=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary 'from listing' -H 'Content-Type: text/plain' -b "ls_token=$TOK" "$base/ls/text")
[ "$S" = "200" ] && ok "投递 200" || bad "应 200 实为 $S"

kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -rf "$ROOT"

echo
echo "结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
