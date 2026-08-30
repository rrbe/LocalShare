package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestDataFrameRoundTrip(t *testing.T) {
	frame := encodeData("req_123", []byte("hello"))
	id, data, ok := decodeData(frame)
	if !ok || id != "req_123" || !bytes.Equal(data, []byte("hello")) {
		t.Fatalf("round trip failed: %q %q %t", id, data, ok)
	}
	if _, _, ok := decodeData([]byte{0, 0, 0, 9, 'x'}); ok {
		t.Fatal("accepted truncated frame")
	}
}

func TestDefaultStateDir(t *testing.T) {
	if defaultStateDir != "/var/lib/localshare" {
		t.Fatalf("state dir = %q", defaultStateDir)
	}
}

func TestEnrollmentKeyIsOneTime(t *testing.T) {
	store, err := newStateStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	_, key, err := store.createEnrollmentKey("test")
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.enroll(key, "Mac"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.enroll(key, "Mac"); err == nil {
		t.Fatal("enrollment key was reusable")
	}
}

func TestRewriteLocationKeepsSharePrefix(t *testing.T) {
	if got := rewriteLocation("/folder/", "share_123"); got != "/share/share_123/folder/" {
		t.Fatalf("got %q", got)
	}
	if got := rewriteLocation("https://example.com/x", "share_123"); got != "https://example.com/x" {
		t.Fatalf("rewrote absolute URL: %q", got)
	}
}

func TestNormalizePublicURLRequiresBaseHTTPURL(t *testing.T) {
	if got, err := normalizePublicURL("https://ls.example.com/"); err != nil || got != "https://ls.example.com" {
		t.Fatalf("normalized URL = %q, err = %v", got, err)
	}
	for _, value := range []string{"", "ls.example.com", "https://ls.example.com/path", "https://ls.example.com/?x=1"} {
		if _, err := normalizePublicURL(value); err == nil {
			t.Fatalf("accepted invalid public URL %q", value)
		}
	}
}

func TestPublicShareQueryCannotOverrideLocalToken(t *testing.T) {
	req := httptest.NewRequest("GET", "http://server/share/share_1/a.txt?t=attacker&raw=1", nil)
	query := req.URL.Query()
	query.Del("t")
	if got := query.Encode(); got != "raw=1" {
		t.Fatalf("forwarded query = %q", got)
	}
}

func TestWebSocketRelayStreamsAgentResponse(t *testing.T) {
	store, err := newStateStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	hub := newHub(store, "")
	server := httptest.NewServer(newHTTPHandler(hub))
	defer server.Close()
	hub.publicURL = server.URL

	_, enrollmentKey, err := store.createEnrollmentKey("test")
	if err != nil {
		t.Fatal(err)
	}
	_, deviceToken, err := store.enroll(enrollmentKey, "Mac")
	if err != nil {
		t.Fatal(err)
	}
	conn, _, err := websocket.Dial(context.Background(), server.URL+"/api/v1/agent", &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + deviceToken}},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "done")

	ctx := context.Background()
	typ, payload, err := conn.Read(ctx)
	if err != nil || typ != websocket.MessageText {
		t.Fatalf("hello = %v %q", err, payload)
	}
	var hello wireMessage
	if err := json.Unmarshal(payload, &hello); err != nil || hello.Type != "hello" {
		t.Fatalf("invalid hello: %q", payload)
	}
	if err := conn.Write(ctx, websocket.MessageText, []byte(`{"type":"share.start","protocol":1,"share_id":"local_1"}`)); err != nil {
		t.Fatal(err)
	}
	_, payload, err = conn.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var ready wireMessage
	if err := json.Unmarshal(payload, &ready); err != nil || ready.Type != "share.ready" {
		t.Fatalf("invalid share response: %q", payload)
	}
	if !strings.HasPrefix(ready.ShareURL, server.URL+"/share/") {
		t.Fatalf("unexpected share URL: %q", ready.ShareURL)
	}

	result := make(chan []byte, 1)
	errors := make(chan error, 1)
	go func() {
		response, err := http.Get(ready.ShareURL + "/hello.txt")
		if err != nil {
			errors <- err
			return
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			errors <- fmt.Errorf("browser status = %d", response.StatusCode)
			return
		}
		body, err := io.ReadAll(response.Body)
		if err != nil {
			errors <- err
			return
		}
		result <- body
	}()

	_, payload, err = conn.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var request wireMessage
	if err := json.Unmarshal(payload, &request); err != nil || request.Type != "request.begin" {
		t.Fatalf("invalid request: %q", payload)
	}
	if request.ShareID != "local_1" {
		t.Fatalf("request share id = %q", request.ShareID)
	}
	body := bytes.Repeat([]byte("x"), 128<<10)
	responseBegin, _ := json.Marshal(wireMessage{
		Type: "response.begin", RequestID: request.RequestID, Status: http.StatusOK,
		Headers: map[string]string{"Content-Type": "text/plain", "Content-Length": fmt.Sprint(len(body))},
	})
	if err := conn.Write(ctx, websocket.MessageText, responseBegin); err != nil {
		t.Fatal(err)
	}
	if err := conn.Write(ctx, websocket.MessageBinary, encodeData(request.RequestID, body)); err != nil {
		t.Fatal(err)
	}
	responseEnd, _ := json.Marshal(wireMessage{Type: "response.end", RequestID: request.RequestID})
	if err := conn.Write(ctx, websocket.MessageText, responseEnd); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-errors:
		t.Fatal(err)
	case got := <-result:
		if !bytes.Equal(got, body) {
			t.Fatalf("browser body = %q", got)
		}
	}
}

func TestStateStorePermissionsAndCrossInstanceLock(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	first, err := newStateStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	second, err := newStateStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o700 {
		t.Fatalf("state dir mode = %v", info.Mode().Perm())
	}

	locked := make(chan struct{})
	release := make(chan struct{})
	firstDone := make(chan error, 1)
	go func() {
		firstDone <- first.withFileLock(true, func() error {
			close(locked)
			<-release
			return nil
		})
	}()
	<-locked
	secondDone := make(chan error, 1)
	go func() {
		_, _, err := second.createEnrollmentKey("second")
		secondDone <- err
	}()
	select {
	case err := <-secondDone:
		t.Fatalf("second store bypassed file lock: %v", err)
	case <-time.After(30 * time.Millisecond):
	}
	close(release)
	if err := <-firstDone; err != nil {
		t.Fatal(err)
	}
	if err := <-secondDone; err != nil {
		t.Fatal(err)
	}
	info, err = os.Stat(filepath.Join(dir, "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("state file mode = %v", info.Mode().Perm())
	}
}

func TestStartingNewShareInvalidatesOldToken(t *testing.T) {
	store, err := newStateStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h := newHub(store, "http://example.test")
	a := &agent{device: device{ID: "device_1"}}
	oldURL, err := h.startShare(a, "local_old")
	if err != nil {
		t.Fatal(err)
	}
	newURL, err := h.startShare(a, "local_new")
	if err != nil {
		t.Fatal(err)
	}
	if oldURL == newURL || !strings.HasSuffix(newURL, "/") {
		t.Fatalf("share URLs = %q, %q", oldURL, newURL)
	}
	oldToken := strings.TrimSuffix(strings.TrimPrefix(oldURL, "http://example.test/share/"), "/")
	h.mu.Lock()
	old := h.shares[oldToken]
	var current *share
	for _, item := range h.shares {
		current = item
	}
	h.mu.Unlock()
	if old != nil || current == nil || current.shareID != "local_new" {
		t.Fatalf("old=%v current=%+v", old, current)
	}
}

func TestSharePathWithoutSlashRedirectsBeforeRelay(t *testing.T) {
	store, err := newStateStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h := newHub(store, "http://example.test")
	req := httptest.NewRequest(http.MethodGet, "http://example.test/share/share_1?raw=1", nil)
	recorder := httptest.NewRecorder()
	h.shareHandler(recorder, req)
	if recorder.Code != http.StatusPermanentRedirect || recorder.Header().Get("Location") != "/share/share_1/?raw=1" {
		t.Fatalf("redirect = %d %q", recorder.Code, recorder.Header().Get("Location"))
	}
}

func TestRelayTimeoutSendsCancel(t *testing.T) {
	h, server, conn, shareURL := openTestAgent(t)
	defer server.Close()
	defer conn.Close(websocket.StatusNormalClosure, "done")
	h.requestIdleTimeout = 30 * time.Millisecond

	status := make(chan int, 1)
	go func() {
		response, err := http.Get(shareURL + "slow.txt")
		if err != nil {
			status <- 0
			return
		}
		defer response.Body.Close()
		status <- response.StatusCode
	}()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var begin wireMessage
	if json.Unmarshal(payload, &begin) != nil || begin.Type != "request.begin" {
		t.Fatalf("begin = %q", payload)
	}
	_, payload, err = conn.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var cancelMessage wireMessage
	if json.Unmarshal(payload, &cancelMessage) != nil || cancelMessage.Type != "request.cancel" || cancelMessage.RequestID != begin.RequestID {
		t.Fatalf("cancel = %q", payload)
	}
	if got := <-status; got != http.StatusGatewayTimeout {
		t.Fatalf("status = %d", got)
	}
}

func TestBrowserCancellationPropagatesToAgent(t *testing.T) {
	_, server, conn, shareURL := openTestAgent(t)
	defer server.Close()
	defer conn.Close(websocket.StatusNormalClosure, "done")
	ctx, cancelBrowser := context.WithCancel(context.Background())
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, shareURL+"cancel.txt", nil)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		response, err := http.DefaultClient.Do(request)
		if response != nil {
			response.Body.Close()
		}
		done <- err
	}()
	readCtx, cancelRead := context.WithTimeout(context.Background(), time.Second)
	defer cancelRead()
	_, payload, err := conn.Read(readCtx)
	if err != nil {
		t.Fatal(err)
	}
	var begin wireMessage
	if json.Unmarshal(payload, &begin) != nil || begin.Type != "request.begin" {
		t.Fatalf("begin = %q", payload)
	}
	cancelBrowser()
	_, payload, err = conn.Read(readCtx)
	if err != nil {
		t.Fatal(err)
	}
	var cancelMessage wireMessage
	if json.Unmarshal(payload, &cancelMessage) != nil || cancelMessage.Type != "request.cancel" || cancelMessage.RequestID != begin.RequestID {
		t.Fatalf("cancel = %q", payload)
	}
	if err := <-done; err == nil {
		t.Fatal("browser request unexpectedly succeeded")
	}
}

func TestRevokedDeviceCannotOpenNewWebSocket(t *testing.T) {
	store, err := newStateStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h := newHub(store, "")
	server := httptest.NewServer(newHTTPHandler(h))
	defer server.Close()
	_, enrollmentKey, err := store.createEnrollmentKey("test")
	if err != nil {
		t.Fatal(err)
	}
	deviceID, deviceToken, err := store.enroll(enrollmentKey, "Mac")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.revokeDevice(deviceID); err != nil {
		t.Fatal(err)
	}
	conn, response, err := websocket.Dial(context.Background(), server.URL+"/api/v1/agent", &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + deviceToken}},
	})
	if conn != nil {
		conn.Close(websocket.StatusNormalClosure, "done")
	}
	if err == nil || response == nil || response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("dial err=%v response=%v", err, response)
	}
}

func openTestAgent(t *testing.T) (*hub, *httptest.Server, *websocket.Conn, string) {
	t.Helper()
	store, err := newStateStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h := newHub(store, "")
	server := httptest.NewServer(newHTTPHandler(h))
	h.publicURL = server.URL
	_, enrollmentKey, err := store.createEnrollmentKey("test")
	if err != nil {
		t.Fatal(err)
	}
	_, deviceToken, err := store.enroll(enrollmentKey, "Mac")
	if err != nil {
		t.Fatal(err)
	}
	conn, _, err := websocket.Dial(context.Background(), server.URL+"/api/v1/agent", &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + deviceToken}},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, _, err := conn.Read(ctx); err != nil {
		t.Fatal(err)
	}
	if err := conn.Write(ctx, websocket.MessageText, []byte(`{"type":"share.start","protocol":1,"share_id":"local_1"}`)); err != nil {
		t.Fatal(err)
	}
	_, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var ready wireMessage
	if json.Unmarshal(payload, &ready) != nil || ready.Type != "share.ready" {
		t.Fatalf("ready = %q", payload)
	}
	return h, server, conn, ready.ShareURL
}
