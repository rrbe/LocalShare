#!/usr/bin/env bash
# 防回归冒烟测：含中文 / 空格 / 加号 / 百分号的文件名能被正确解码并服务。
# 守的是 Swifter 1.5.0 的 path 二次编码 bug：req.path 落地文件系统前仍残留一层百分号编码，
# FileServer 必须 removingPercentEncoding 再去匹配磁盘；漏解码则这些名字一律 404（纯 ASCII 的
# a.html 因无 % 不受影响，单独留作控制组）。详见 CLAUDE.md「跨文件的关键约束」。
# 用法：./tools/smoke-filenames.sh   退出码 0=全过。依赖 node 做 URL 编码（项目本就有 .cjs 测试）。
set -u
# 强制 UTF-8 locale：脚本里 CJK 文件名与「」括号若在 C/POSIX locale 下解析，bash 会把多字节
# 字节并进变量名（$n 紧贴「」时报 n�: unbound）。仅 macOS 跑，en_US.UTF-8 必有。
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
BIN="${BIN:-.build/debug/LocalShare}"
[ -x "$BIN" ] || { echo "找不到 $BIN，先跑 swift build"; exit 2; }
command -v node >/dev/null || { echo "需要 node 做 URL 编码"; exit 2; }

TOK="nametest"; ROOT="$(mktemp -d)"
PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }

# 各文件内容 = "OK-<序号>"，断言取到的是对的那个文件（而非碰巧 200 的别的文件）。
NAMES=("中文文件.txt" "a b.txt" "a+b.txt" "100%.txt" "a.html")
i=0
for n in "${NAMES[@]}"; do i=$((i+1)); printf 'OK-%d' "$i" > "$ROOT/$n"; done

PORT=$(( (RANDOM % 10000) + 40000 ))
LS_HEADLESS=1 LS_FOLDER="$ROOT" LS_TOKEN="$TOK" LS_PORT="$PORT" "$BIN" >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -rf "$ROOT"' EXIT
base="http://127.0.0.1:$PORT"
for _ in $(seq 1 50); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$base/a.html?t=$TOK")" = "200" ] && break
  sleep 0.1
done

enc(){ node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$1"; }

echo "── 各特殊名按 URL 编码请求，应取到对应内容（验解码命中文件系统）"
i=0
for n in "${NAMES[@]}"; do
  i=$((i+1)); e=$(enc "$n"); got=$(curl -s "$base/$e?t=$TOK")
  [ "$got" = "OK-$i" ] && ok "「${n}」→ /${e} 取到 OK-${i}" || bad "「${n}」→ /${e} 取到「${got}」，应为 OK-${i}"
done

echo "── 目录列表页正常生成且含中文名（显示文本）"
L=$(curl -s "$base/?t=$TOK")
echo "$L" | grep -q "中文文件" && ok "列表页含「中文文件」" || bad "列表页未列出中文名"

echo
echo "结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
