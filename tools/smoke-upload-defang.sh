#!/usr/bin/env bash
# 防回归冒烟测：访客上传的 HTML/SVG 去势 + 全站 nosniff。
# 复现并验证「上传 index.html 顶替目录列表页 → 别人点进该目录零点击中招」这条存储型 XSS 已被堵。
#
# 用法： ./tools/smoke-upload-defang.sh        （需先 swift build；走 .build/debug 二进制）
# 退出码 0 = 全过；非 0 = 有断言失败（CI 可直接 gate）。
set -u

BIN="${BIN:-.build/debug/LocalShare}"
[ -x "$BIN" ] || { echo "找不到 $BIN，先跑 swift build"; exit 2; }

PORT=$(( (RANDOM % 10000) + 40000 ))
TOK="smoketok123"
ROOT="$(mktemp -d)"
mkdir -p "$ROOT/sub"

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

# 攻击载荷：内容里埋一个唯一标记，若被当页面发出去就能在响应里抓到。
MARKER="XSS_PAYLOAD_MARKER_8842"
PAYLOAD="$ROOT/payload.bin"
printf '<script>alert(1)</script>%s\n' "$MARKER" > "$PAYLOAD"

LS_HEADLESS=1 LS_FOLDER="$ROOT" LS_TOKEN="$TOK" LS_PORT="$PORT" LS_UPLOAD=1 "$BIN" >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -rf "$ROOT"' EXIT

# 等服务就绪
for _ in $(seq 1 50); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/?t=$TOK")" = "200" ] && break
  sleep 0.1
done

base="http://127.0.0.1:$PORT"
up() { curl -s -F "f=@$PAYLOAD;filename=$1" "$base/sub/?t=$TOK"; }   # 上传到 /sub/，回 JSON

echo "── 1. index.html 上传去势（核心：零点击劫持已堵）"
R=$(up "index.html")
echo "$R" | grep -q '"index.html.txt"' && ok "落地被改名为 index.html.txt: ${R}" || bad "未改名: ${R}"

# 别人点进 /sub/：应拿到目录列表页，而不是攻击者 HTML（响应里不该出现 MARKER 内容）
SUB=$(curl -s -H 'Accept: text/html' "$base/sub/?t=$TOK")
echo "$SUB" | grep -q "$MARKER" && bad "/sub/ 仍吐出攻击载荷内容（劫持未堵！）" || ok "/sub/ 返回目录列表、不含载荷内容"

echo "── 2. 文件本体保留但被中和为 text/plain + nosniff"
H=$(curl -s -D - -o /tmp/_body "$base/sub/index.html.txt?t=$TOK")
echo "$H" | grep -qi '^Content-Type: *text/plain' && ok "Content-Type 为 text/plain（不再执行）" || bad "Content-Type 非 text/plain：$(echo "$H" | grep -i content-type)"
echo "$H" | grep -qi '^X-Content-Type-Options: *nosniff' && ok "带 nosniff 头" || bad "缺 nosniff 头"
grep -q "$MARKER" /tmp/_body && ok "原始内容完整保留（未丢文件）" || bad "文件内容丢失"

echo "── 3. SVG 同样去势"
R=$(up "evil.svg")
echo "$R" | grep -q '"evil.svg.txt"' && ok "evil.svg → evil.svg.txt" || bad "SVG 未去势：$R"

echo "── 4. 正常文件不受影响（不误伤）"
R=$(up "report.pdf")
echo "$R" | grep -q '"report.pdf"' && ok "report.pdf 原样保留" || bad "正常文件被误改：$R"

echo "── 5. 普通文件响应也带 nosniff"
curl -s -D - -o /dev/null "$base/sub/report.pdf?t=$TOK" | grep -qi '^X-Content-Type-Options: *nosniff' \
  && ok "普通文件响应带 nosniff" || bad "普通文件缺 nosniff"

echo
echo "结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
