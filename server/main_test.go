package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

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
	if err := conn.Write(ctx, websocket.MessageText, []byte(`{"type":"share.start","protocol":1}`)); err != nil {
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
