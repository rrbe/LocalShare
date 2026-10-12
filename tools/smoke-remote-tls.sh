#!/usr/bin/env bash
# 验证 HTTPS 服务可达时，Mac 仍拒绝不受信任的证书，配对码不会被消费。
set -euo pipefail
CLIENT_BIN="${CLIENT_BIN:-.build/debug/LocalShare}"
[ -x "$CLIENT_BIN" ] || { echo "先执行 swift build"; exit 2; }
TMP="$(mktemp -d)"
SERVER_PID=""; CLIENT_PID=""
cleanup() {
  [ -z "$CLIENT_PID" ] || kill "$CLIENT_PID" 2>/dev/null || true
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  [ -z "$CLIENT_PID" ] || wait "$CLIENT_PID" 2>/dev/null || true
  [ -z "$SERVER_PID" ] || wait "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
PORT=$(( (RANDOM % 5000) + 30000 ))
LOCAL_PORT=$(( PORT + 20000 ))
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' \
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >"$TMP/openssl.log" 2>&1
(cd server && go build -o "$TMP/server" .)
KEY=$("$TMP/server" key create --name tls-test --state-dir "$TMP/state" | awk '/^key: /{print $2}')
URL="https://127.0.0.1:$PORT"
"$TMP/server" serve --listen "127.0.0.1:$PORT" --public-url "$URL" \
  --tls-cert "$TMP/cert.pem" --tls-key "$TMP/key.pem" --state-dir "$TMP/state" \
  >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
HEALTHY=0
for _ in $(seq 1 50); do
  if curl --fail --silent --max-time 2 --cacert "$TMP/cert.pem" "$URL/healthz" > /dev/null; then HEALTHY=1; break; fi
  sleep 0.1
done
[ "$HEALTHY" = 1 ] || { echo "TLS 测试服务未启动"; exit 1; }
LS_HEADLESS=1 LS_TEXT=tls-test LS_TOKEN=tls-test LS_PORT="$LOCAL_PORT" LS_REMOTE=1 \
  LS_REMOTE_SERVER="$URL" LS_REMOTE_KEY="$KEY" "$CLIENT_BIN" >"$TMP/client.log" 2>&1 &
CLIENT_PID=$!
for _ in $(seq 1 100); do
  grep -q '^LS_REMOTE_ERROR ' "$TMP/client.log" && break
  sleep 0.1
done
grep -Eqi '^LS_REMOTE_ERROR .*(SSL|certificate|证书|安全连接|secure connection)' "$TMP/client.log" \
  || { echo "Client 未报告证书校验错误"; exit 1; }
if grep -q '^LS_REMOTE_URL ' "$TMP/client.log"; then echo "错误：无效证书仍发布了分享"; exit 1; fi
python3 - "$TMP/state/state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert not state.get('devices'), 'TLS failure still enrolled a device'
assert not state['enrollment_keys'][0]['used'], 'TLS failure consumed the enrollment key'
PY
echo "PASS: untrusted TLS certificate denied; no share published or credential consumed"
