#!/usr/bin/env bash
# 防回归冒烟测：防目录穿越（HTTP 全链路）+ 单文件分享隔离。这是安全边界的端到端兜底，
# 与单测 PathTraversalTests（直测 resolveWithinRoot）互补——这里还覆盖 Swifter 二次编码的
# removingPercentEncoding 解码路径（%2e%2e / ..%2f 解码成 .. 后同样要被挡）。
#   ① 目录模式：../、..%2f、%2e%2e、%2e%2e%2f、子目录回跳一律 403，且拿不到 share 外的密件；
#   ② 单文件模式：任何路径只回那一个文件，不泄露同目录兄弟。
# 用法：./tools/smoke-traversal.sh   退出码 0=全过。curl 必须 --path-as-is，否则它会客户端折叠 ../。
set -u
BIN="${BIN:-.build/debug/LocalShare}"
[ -x "$BIN" ] || { echo "找不到 $BIN，先跑 swift build"; exit 2; }

TOK="travtest"
BASE="$(mktemp -d)"; ROOT="$BASE/share"; mkdir -p "$ROOT/sub"
echo INSIDE     > "$ROOT/ok.txt"
echo INSIDE-SUB > "$ROOT/sub/deep.txt"
echo SHARED     > "$ROOT/shared.txt"
echo SIBLING    > "$ROOT/sibling.txt"        # 单文件模式下不该被泄露
echo TOPSECRET  > "$BASE/secret.txt"         # 在 share 之外（root 的兄弟）

PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }
SRV=""
trap '[ -n "$SRV" ] && kill $SRV 2>/dev/null; wait 2>/dev/null; rm -rf "$BASE"' EXIT

# $1=LS_FOLDER 值  $2=端口  $3=就绪探测路径（相对，单文件模式任何路径都 200）
start_srv(){
  env LS_HEADLESS=1 LS_FOLDER="$1" LS_TOKEN="$TOK" LS_PORT="$2" "$BIN" >/dev/null 2>&1 &
  SRV=$!
  for _ in $(seq 1 50); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --path-as-is "http://127.0.0.1:$2/$3?t=$TOK")" = "200" ] && return 0
    kill -0 "$SRV" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}
stop_srv(){ kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""; }

P1=$(( (RANDOM % 10000) + 40000 )); b1="http://127.0.0.1:$P1"
start_srv "$ROOT" "$P1" "ok.txt" || { echo "目录模式服务未就绪"; exit 1; }
code(){ curl -s -o /dev/null -w '%{http_code}' --path-as-is "$b1/$1?t=$TOK"; }
body(){ curl -s --path-as-is "$b1/$1?t=$TOK"; }

echo "── 控制组：正常文件可达、内容正确"
[ "$(code ok.txt)" = "200" ] && ok "ok.txt → 200" || bad "ok.txt 应 200，实为 $(code ok.txt)"
[ "$(body sub/deep.txt)" = "INSIDE-SUB" ] && ok "sub/deep.txt 内容正确" || bad "sub/deep.txt 内容错"

echo "── 穿越尝试一律 403"
for p in "../secret.txt" "..%2fsecret.txt" "%2e%2e/secret.txt" "%2e%2e%2fsecret.txt" "sub/../../secret.txt"; do
  c=$(code "$p")
  [ "$c" = "403" ] && ok "$p → 403" || bad "$p 应 403，实为 $c"
done
leak=0
for p in "../secret.txt" "..%2fsecret.txt" "%2e%2e%2fsecret.txt" "sub/../../secret.txt"; do
  body "$p" | grep -q TOPSECRET && leak=1
done
[ "$leak" = "0" ] && ok "任何穿越尝试都拿不到密件内容" || bad "密件内容被泄露！"
stop_srv

echo "── 单文件分享隔离：任何路径只回该文件，兄弟不泄露"
P2=$(( (RANDOM % 10000) + 40000 )); b2="http://127.0.0.1:$P2"
start_srv "$ROOT/shared.txt" "$P2" "shared.txt" || { echo "单文件模式服务未就绪"; exit 1; }
sf(){ curl -s --path-as-is "$b2/$1?t=$TOK"; }
[ "$(sf shared.txt)" = "SHARED" ] && ok "/shared.txt → 该文件内容" || bad "/shared.txt 应为 SHARED"
[ "$(sf '')" = "SHARED" ]         && ok "/ → 仍是该文件（单文件直链）" || bad "/ 应为 SHARED"
[ "$(sf sibling.txt)" = "SHARED" ] && ok "/sibling.txt → 回共享文件、未路由到兄弟" || bad "/sibling.txt 应回 SHARED"
sf sibling.txt | grep -q SIBLING && bad "兄弟文件内容被泄露！" || ok "确认无 SIBLING 内容泄露"
stop_srv

echo
echo "结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
