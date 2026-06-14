#!/usr/bin/env bash
# 防回归冒烟测：#6「仅当前网络可见」网卡绑定。LS_BIND 设为某私网 IPv4 时 socket 只绑该地址——
# 该地址可达、电脑上的其它接口一律拒连；不设 LS_BIND 则绑全部接口（默认：回环 + 局域网都可达）。
# 对应 GUI 设置页「仅当前网络可见」开关（AppState.bindSelectedOnly → FileServer.listenAddress）。
# 用法：./tools/smoke-bind-interface.sh   退出码 0=全过（探测不到私网 IPv4 时跳过并退 0）。
set -u
BIN="${BIN:-.build/debug/LocalShare}"
[ -x "$BIN" ] || { echo "找不到 $BIN，先跑 swift build"; exit 2; }

# 探测任一私网 IPv4（192.168/10/172.16–31）；无线下机器/CI 探不到则跳过——绑定语义无从验证。
LAN=$(ifconfig 2>/dev/null | awk '/inet /{print $2}' \
      | grep -E '^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | head -1)
if [ -z "$LAN" ]; then echo "⏭  未探测到私网 IPv4，跳过绑定测试"; exit 0; fi
echo "本机私网 IPv4：$LAN"

TOK="bindtest"; ROOT="$(mktemp -d)"; echo hi > "$ROOT/a.txt"
PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }
SRV=""
cleanup(){ [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; wait 2>/dev/null; rm -rf "$ROOT"; }
trap cleanup EXIT

# host port → HTTP 码 / REFUSED / TIMEOUT。--noproxy 绕开本机 HTTP 代理（如 Clash），否则直连判断失真。
probe(){
  local c rc
  c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 4 "http://$1:$2/a.txt?t=$TOK" 2>/dev/null); rc=$?
  if [ "$rc" -eq 7 ]; then echo REFUSED; elif [ "$rc" -eq 28 ]; then echo TIMEOUT; else echo "$c"; fi
}

# $1=LS_BIND（可空） $2=端口 $3=就绪探测地址；就绪返回 0，进程早退/超时返回 1。
start_srv(){
  local bind="$1" port="$2" ready="$3"
  env ${bind:+LS_BIND=$bind} LS_HEADLESS=1 LS_FOLDER="$ROOT" LS_TOKEN="$TOK" LS_PORT="$port" "$BIN" >/dev/null 2>&1 &
  SRV=$!
  for _ in $(seq 1 50); do
    [ "$(probe "$ready" "$port")" = "200" ] && return 0
    kill -0 "$SRV" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}
stop_srv(){ kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""; }

echo "── 1. 默认（不设 LS_BIND）→ 绑全部接口，回环与局域网都可达"
if start_srv "" 18211 127.0.0.1; then
  [ "$(probe 127.0.0.1 18211)" = "200" ] && ok "回环可达" || bad "回环应可达"
  [ "$(probe "$LAN" 18211)" = "200" ] && ok "局域网可达" || bad "局域网应可达"
else bad "默认服务未就绪"; fi
stop_srv

echo "── 2. LS_BIND=127.0.0.1 → 仅回环可达，局域网被拒"
if start_srv 127.0.0.1 18212 127.0.0.1; then
  [ "$(probe 127.0.0.1 18212)" = "200" ] && ok "回环可达" || bad "回环应可达"
  r=$(probe "$LAN" 18212); [ "$r" = "REFUSED" ] && ok "局域网被拒（绑定生效）" || bad "局域网应被拒，实为 $r"
else bad "回环绑定服务未就绪"; fi
stop_srv

echo "── 3. LS_BIND=$LAN → 仅局域网可达，回环被拒，内容完整"
if start_srv "$LAN" 18213 "$LAN"; then
  [ "$(probe "$LAN" 18213)" = "200" ] && ok "局域网可达" || bad "局域网应可达"
  r=$(probe 127.0.0.1 18213); [ "$r" = "REFUSED" ] && ok "回环被拒（绑定生效）" || bad "回环应被拒，实为 $r"
  [ "$(curl --noproxy '*' -s --max-time 4 "http://$LAN:18213/a.txt?t=$TOK")" = "hi" ] && ok "内容完整" || bad "内容应为 hi"
else bad "局域网绑定服务未就绪"; fi
stop_srv

echo "── 4. LS_BIND 非法值 → 启动失败，不静默绑全接口（inet_pton 校验）"
env LS_BIND=not-an-ip LS_HEADLESS=1 LS_FOLDER="$ROOT" LS_TOKEN="$TOK" LS_PORT=18214 "$BIN" >/dev/null 2>&1 &
SRV=$!; sleep 1
if kill -0 "$SRV" 2>/dev/null; then
  bad "非法 LS_BIND 仍在运行（loopback=$(probe 127.0.0.1 18214)）——应启动失败而非静默对外开放"
  stop_srv
else
  ok "非法 LS_BIND 启动失败（未静默绑全接口）"; SRV=""
fi

echo
echo "结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
