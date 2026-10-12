package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestRegistrationLimitsAndCredentialIsolation(t *testing.T) {
	store, _ := newStateStore(t.TempDir())
	h := newHub(store, "https://share.example.com")
	register := func(ip string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "/api/v1/register", strings.NewReader(`{"device_name":"Mac"}`))
		r.RemoteAddr = ip + ":1234"
		w := httptest.NewRecorder()
		h.registerHandler(w, r)
		return w
	}
	if w := register("192.0.2.1"); w.Code != 404 {
		t.Fatalf("registration closed: %d", w.Code)
	}
	h.registrationOpen = true
	h.limits.registrationsPerHour = 2
	h.limits.maxDevices = 3
	one, two := register("192.0.2.1"), register("192.0.2.1")
	var a, b map[string]string
	_ = json.Unmarshal(one.Body.Bytes(), &a)
	_ = json.Unmarshal(two.Body.Bytes(), &b)
	if one.Code != 200 || two.Code != 200 || a["device_token"] == b["device_token"] {
		t.Fatal("credentials not independent")
	}
	if w := register("192.0.2.1"); w.Code != 429 {
		t.Fatalf("IP quota: %d", w.Code)
	}
	if w := register("192.0.2.2"); w.Code != 200 {
		t.Fatalf("other IP: %d", w.Code)
	}
	if w := register("192.0.2.3"); w.Code != 503 {
		t.Fatalf("device capacity: %d", w.Code)
	}
	current, _ := store.load()
	for _, d := range current.Devices {
		if d.TokenHash == a["device_token"] || d.TokenHash == "" {
			t.Fatal("plaintext credential stored")
		}
	}
	if err := store.revokeDevice(a["device_id"]); err != nil {
		t.Fatal(err)
	}
	if _, valid, _ := store.deviceForToken(a["device_token"]); valid {
		t.Fatal("revoked token accepted")
	}
	if _, valid, _ := store.deviceForToken(b["device_token"]); !valid {
		t.Fatal("unrelated device revoked")
	}
}

func TestPublicTLSAndProxyIdentityBoundary(t *testing.T) {
	for _, address := range []string{"http://example.com", "http://192.0.2.1"} {
		if _, err := normalizePublicURL(address); err == nil {
			t.Fatal("public HTTP accepted")
		}
	}
	h := newHub(nil, "")
	h.behindProxy = true
	r := httptest.NewRequest("POST", "/api/v1/register", nil)
	r.RemoteAddr = "192.0.2.1:5000"
	r.Header.Set("X-Real-IP", "198.51.100.1")
	if h.clientIP(r) != "192.0.2.1" {
		t.Fatal("untrusted IP header used")
	}
	r.RemoteAddr = "127.0.0.1:5000"
	if h.clientIP(r) != "198.51.100.1" {
		t.Fatal("proxy IP ignored")
	}
	w := httptest.NewRecorder()
	newHTTPHandler(h).ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("plaintext proxy request accepted")
	}
}

func TestRelayCarriesVerifiedSourceIPInsteadOfBrowserIdentityHeaders(t *testing.T) {
	for _, tc := range []struct {
		name  string
		proxy bool
		ip    string
		want  string
	}{
		{"direct", false, "198.51.100.20", "127.0.0.1"},
		{"proxy-v4", true, "198.51.100.20", "198.51.100.20"},
		{"proxy-v6", true, "2001:db8::20", "2001:db8::20"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h, server, conn, shareURL := openTestAgent(t)
			defer server.Close()
			defer conn.CloseNow()
			h.behindProxy = tc.proxy
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			browserDone := make(chan error, 1)
			go func() {
				req, _ := http.NewRequestWithContext(ctx, http.MethodGet, shareURL, nil)
				req.Header.Set("X-Real-IP", tc.ip)
				req.Header.Set("X-Forwarded-Proto", "https")
				req.Header.Set("X-Forwarded-For", "203.0.113.250")
				req.Header.Set("X-LocalShare-Client-IP", "203.0.113.250")
				response, err := http.DefaultClient.Do(req)
				if err == nil {
					response.Body.Close()
					if response.StatusCode != http.StatusOK {
						err = fmt.Errorf("browser status = %d", response.StatusCode)
					}
				}
				browserDone <- err
			}()
			_, payload, err := conn.Read(ctx)
			var request wireMessage
			if err != nil || json.Unmarshal(payload, &request) != nil || request.Type != "request.begin" {
				t.Fatalf("request: %s %v", payload, err)
			}
			if request.ClientIP != tc.want {
				t.Fatalf("source IP = %q, want %q", request.ClientIP, tc.want)
			}
			for _, key := range []string{"X-Real-IP", "X-Forwarded-For", "X-LocalShare-Client-IP"} {
				if _, present := request.Headers[key]; present {
					t.Fatalf("browser identity header forwarded: %s", key)
				}
			}
			for _, message := range []wireMessage{
				{Type: "response.begin", RequestID: request.RequestID, Status: 200, Headers: map[string]string{"Content-Length": "0"}},
				{Type: "response.end", RequestID: request.RequestID},
			} {
				encoded, _ := json.Marshal(message)
				if err := conn.Write(ctx, websocket.MessageText, encoded); err != nil {
					t.Fatal(err)
				}
			}
			if err := <-browserDone; err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestRequestCapacityAndBandwidthCancellation(t *testing.T) {
	h := newHub(nil, "")
	h.limits.deviceRequests = 1
	h.limits.totalRequests = 2
	if !h.acquireRequest("a") || h.acquireRequest("a") || !h.acquireRequest("b") || h.acquireRequest("c") {
		t.Fatal("capacity bypassed")
	}
	h.releaseRequest("a")
	if !h.acquireRequest("a") {
		t.Fatal("capacity not released")
	}
	h.limits.deviceBytesPerSecond = 65536
	h.limits.totalBytesPerSecond = 65536
	if err := h.waitBandwidth(context.Background(), "a", 65536); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := h.waitBandwidth(ctx, "a", 65536); err == nil {
		t.Fatal("cancelled limiter continued")
	}
	h.releaseRequest("a")
	h.releaseRequest("b")
	if h.inFlight != 0 {
		t.Fatal("request leak")
	}
}

func TestLiveRevocationInvalidatesShareAndPendingRequest(t *testing.T) {
	h, server, conn, shareURL := openTestAgent(t)
	defer server.Close()
	defer conn.CloseNow()
	h.mu.Lock()
	var a *agent
	for _, agent := range h.agents {
		a = agent
	}
	h.mu.Unlock()
	pending := a.beginRequest(context.Background(), wireMessage{Type: "request.begin", RequestID: "revoke-test"})
	if err := h.store.revokeDevice(a.device.ID); err != nil {
		t.Fatal(err)
	}
	h.disconnectRevoked()
	select {
	case <-pending.done:
	case <-time.After(time.Second):
		t.Fatal("pending request survived revoke")
	}
	response, err := http.Get(shareURL)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 404 {
		t.Fatalf("old share: %d", response.StatusCode)
	}
}

func TestSlowBrowserDoesNotBlockSiblingAndReleasesCapacity(t *testing.T) {
	h, server, conn, shareURL := openTestAgent(t)
	defer server.Close()
	defer conn.CloseNow()
	h.requestIdleTimeout = 200 * time.Millisecond
	// Keep the TCP receive window small and never consume the response body.
	endpoint, _ := url.Parse(shareURL)
	slow, err := net.Dial("tcp", endpoint.Host)
	if err != nil {
		t.Fatal(err)
	}
	defer slow.Close()
	_ = slow.(*net.TCPConn).SetReadBuffer(1024)
	_, _ = fmt.Fprintf(slow, "GET %sslow HTTP/1.1\r\nHost: %s\r\n\r\n", endpoint.Path, endpoint.Host)
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	cancelled := make(chan struct{})
	readerDone := make(chan error, 1)
	go func() {
		var slowID string
		chunk := bytes.Repeat([]byte("x"), maxRelayChunkSize)
		write := func(m wireMessage) error { b, _ := json.Marshal(m); return conn.Write(ctx, websocket.MessageText, b) }
		for {
			_, payload, err := conn.Read(ctx)
			if err != nil {
				readerDone <- err
				return
			}
			var m wireMessage
			if json.Unmarshal(payload, &m) != nil {
				continue
			}
			switch m.Type {
			case "request.begin":
				if strings.Contains(m.Path, "slow") {
					slowID = m.RequestID
					_ = write(wireMessage{Type: "response.begin", RequestID: m.RequestID, Status: 200})
					_ = conn.Write(ctx, websocket.MessageBinary, encodeData(slowID, chunk))
				} else {
					_ = write(wireMessage{Type: "response.begin", RequestID: m.RequestID, Status: 200, Headers: map[string]string{"Content-Length": "2"}})
					_ = conn.Write(ctx, websocket.MessageBinary, encodeData(m.RequestID, []byte("ok")))
				}
			case "response.ack":
				if m.RequestID == slowID {
					_ = conn.Write(ctx, websocket.MessageBinary, encodeData(slowID, chunk))
				} else {
					_ = write(wireMessage{Type: "response.end", RequestID: m.RequestID})
				}
			case "request.cancel":
				if m.RequestID == slowID {
					close(cancelled)
					readerDone <- nil
					return
				}
			}
		}
	}()
	// Wait for the first headers without draining any body bytes.
	_ = slow.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := http.ReadResponse(bufio.NewReader(slow), nil); err != nil {
		t.Fatal(err)
	}
	response, err := (&http.Client{Timeout: time.Second}).Get(shareURL + "fast")
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || string(body) != "ok" {
		t.Fatalf("sibling response: %s %v", body, err)
	}
	select {
	case <-cancelled:
	case err := <-readerDone:
		if err != nil {
			t.Fatalf("reader ended: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("slow download never timed out")
	}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		h.mu.Lock()
		count := h.inFlight
		h.mu.Unlock()
		if count == 0 {
			return
		}
		time.Sleep(time.Millisecond * 10)
	}
	t.Fatal("slow download leaked request capacity")
}

func TestOversizedMetadataCannotDisconnectDevice(t *testing.T) {
	_, server, conn, shareURL := openTestAgent(t)
	defer server.Close()
	defer conn.CloseNow()
	request, _ := http.NewRequest("GET", shareURL, nil)
	request.Header.Set("User-Agent", strings.Repeat("x", 9000))
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 431 {
		t.Fatalf("oversized header: %d", response.StatusCode)
	}
	if validDeviceName("name\nforged row") || validDeviceName("\x1b[31m") {
		t.Fatal("control characters accepted in device name")
	}
}

func TestHTTPAndProxyCannotListenPublicly(t *testing.T) {
	for _, args := range [][]string{
		{"--listen", ":8080", "--public-url", "http://127.0.0.1:8080"},
		{"--listen", ":8080", "--public-url", "https://share.example.com", "--behind-proxy"},
	} {
		if err := runServe(args); err == nil {
			t.Fatal("public plaintext listener accepted")
		}
	}
}

func TestPrunePreservesActiveCredentials(t *testing.T) {
	dir := t.TempDir()
	store, _ := newStateStore(dir)
	_, key, _ := store.createEnrollmentKey("used")
	oldID, _, _ := store.enroll(key, "old")
	_, activeKey, _ := store.createEnrollmentKey("active")
	_, token, _ := store.enroll(activeKey, "active")
	_ = store.revokeDevice(oldID)
	if err := runDevice([]string{"prune", "--state-dir", dir}); err != nil {
		t.Fatal(err)
	}
	current, err := store.load()
	if err != nil || len(current.Devices) != 1 || len(current.EnrollmentKeys) != 0 {
		t.Fatalf("pruned state: %+v %v", current, err)
	}
	if _, valid, _ := store.deviceForToken(token); !valid {
		t.Fatal("active credential removed")
	}
}

func streamTestResponses(ctx context.Context, conn *websocket.Conn) {
	chunk := bytes.Repeat([]byte("x"), maxRelayChunkSize)
	for {
		_, payload, err := conn.Read(ctx)
		if err != nil {
			return
		}
		var message wireMessage
		if json.Unmarshal(payload, &message) != nil {
			continue
		}
		switch message.Type {
		case "request.begin":
			headers, _ := json.Marshal(wireMessage{Type: "response.begin", RequestID: message.RequestID, Status: 200})
			if conn.Write(ctx, websocket.MessageText, headers) != nil {
				return
			}
			if conn.Write(ctx, websocket.MessageBinary, encodeData(message.RequestID, chunk)) != nil {
				return
			}
		case "response.ack":
			if conn.Write(ctx, websocket.MessageBinary, encodeData(message.RequestID, chunk)) != nil {
				return
			}
		}
	}
}

func waitTestRequestsDrained(t *testing.T, h *hub, a *agent) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		h.mu.Lock()
		count := h.inFlight
		h.mu.Unlock()
		a.pendingMu.Lock()
		pending := len(a.pending)
		a.pendingMu.Unlock()
		if count == 0 && pending == 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("requests or relay queues remained after cancellation")
}

func TestRepeatedConcurrentSlowDownloadsRespectCapacity(t *testing.T) {
	h, server, conn, shareURL := openTestAgent(t)
	defer server.Close()
	defer conn.CloseNow()
	h.requestIdleTimeout = 100 * time.Millisecond
	h.limits.deviceRequests = 2
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	go streamTestResponses(ctx, conn)
	h.mu.Lock()
	var a *agent
	for _, current := range h.agents {
		a = current
	}
	h.mu.Unlock()
	endpoint, _ := url.Parse(shareURL)
	baseline := runtime.NumGoroutine()
	for wave := 0; wave < 10; wave++ {
		var clients []net.Conn
		for i := 0; i < 4; i++ {
			client, err := net.Dial("tcp", endpoint.Host)
			if err != nil {
				t.Fatal(err)
			}
			_ = client.(*net.TCPConn).SetReadBuffer(1024)
			_, _ = fmt.Fprintf(client, "GET %sslow HTTP/1.1\r\nHost: %s\r\n\r\n", endpoint.Path, endpoint.Host)
			clients = append(clients, client)
		}
		rejected := 0
		for _, client := range clients {
			_ = client.SetReadDeadline(time.Now().Add(time.Second))
			response, err := http.ReadResponse(bufio.NewReader(client), nil)
			if err != nil {
				t.Fatal(err)
			}
			if response.StatusCode == 429 {
				rejected++
			} else if response.StatusCode != 200 {
				t.Fatalf("status: %d", response.StatusCode)
			}
		}
		if rejected != 2 {
			t.Fatalf("wave %d bypassed device request cap: %d rejected", wave, rejected)
		}
		waitTestRequestsDrained(t, h, a)
		for _, client := range clients {
			_ = client.Close()
		}
	}
	deadline := time.Now().Add(time.Second)
	for runtime.NumGoroutine() > baseline+4 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if runtime.NumGoroutine() > baseline+4 {
		t.Fatal("goroutines kept growing after repeated slow downloads")
	}
}

func TestControlChangesInterruptSlowDownloads(t *testing.T) {
	for _, action := range []string{"stop", "replace", "revoke"} {
		t.Run(action, func(t *testing.T) {
			h, server, conn, shareURL := openTestAgent(t)
			defer server.Close()
			defer conn.CloseNow()
			// A long idle deadline ensures cleanup is caused by the control action.
			h.requestIdleTimeout = 30 * time.Second
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			go streamTestResponses(ctx, conn)
			h.mu.Lock()
			var a *agent
			for _, current := range h.agents {
				a = current
			}
			h.mu.Unlock()
			endpoint, _ := url.Parse(shareURL)
			client, err := net.Dial("tcp", endpoint.Host)
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			_ = client.(*net.TCPConn).SetReadBuffer(1024)
			_, _ = fmt.Fprintf(client, "GET %sslow HTTP/1.1\r\nHost: %s\r\n\r\n", endpoint.Path, endpoint.Host)
			_ = client.SetReadDeadline(time.Now().Add(time.Second))
			if _, err := http.ReadResponse(bufio.NewReader(client), nil); err != nil {
				t.Fatal(err)
			}
			switch action {
			case "stop":
				h.stopShare(a)
			case "replace":
				if _, err := h.startShare(a, "replacement"); err != nil {
					t.Fatal(err)
				}
			case "revoke":
				if err := h.store.revokeDevice(a.device.ID); err != nil {
					t.Fatal(err)
				}
				h.disconnectRevoked()
			}
			waitTestRequestsDrained(t, h, a)
			response, err := (&http.Client{Timeout: time.Second}).Get(shareURL)
			if err != nil {
				t.Fatal(err)
			}
			response.Body.Close()
			if response.StatusCode != 404 {
				t.Fatalf("old URL remained active: %d", response.StatusCode)
			}
		})
	}
}

func TestContinuousTransferMayOutlastIdleTimeout(t *testing.T) {
	h, server, conn, shareURL := openTestAgent(t)
	defer server.Close()
	defer conn.CloseNow()
	h.requestIdleTimeout = 250 * time.Millisecond
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	chunk := bytes.Repeat([]byte("x"), maxRelayChunkSize)
	done := make(chan error, 1)
	go func() {
		_, payload, err := conn.Read(ctx)
		if err != nil {
			done <- err
			return
		}
		var request wireMessage
		_ = json.Unmarshal(payload, &request)
		headers, _ := json.Marshal(wireMessage{Type: "response.begin", RequestID: request.RequestID, Status: 200, Headers: map[string]string{"Content-Length": fmt.Sprint(len(chunk) * 5)}})
		if err := conn.Write(ctx, websocket.MessageText, headers); err != nil {
			done <- err
			return
		}
		for i := 0; i < 5; i++ {
			time.Sleep(100 * time.Millisecond)
			if err := conn.Write(ctx, websocket.MessageBinary, encodeData(request.RequestID, chunk)); err != nil {
				done <- err
				return
			}
			_, payload, err := conn.Read(ctx)
			var ack wireMessage
			if err != nil {
				done <- err
				return
			}
			if json.Unmarshal(payload, &ack) != nil || ack.Type != "response.ack" {
				done <- fmt.Errorf("expected ack: %s", payload)
				return
			}
		}
		end, _ := json.Marshal(wireMessage{Type: "response.end", RequestID: request.RequestID})
		done <- conn.Write(ctx, websocket.MessageText, end)
	}()
	started := time.Now()
	response, err := (&http.Client{Timeout: 2 * time.Second}).Get(shareURL + "continuous")
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || len(body) != len(chunk)*5 {
		t.Fatalf("incomplete response: %d bytes, %v", len(body), err)
	}
	if time.Since(started) <= h.requestIdleTimeout {
		t.Fatal("fixture did not cross the idle-timeout duration")
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestHTTPConnectionCapacityReopensAfterPeerCloses(t *testing.T) {
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) }))
	type transition struct {
		address string
		state   http.ConnState
	}
	states := make(chan transition, 32)
	limit := limitHTTPConnections(2)
	server.Config.ConnState = func(conn net.Conn, state http.ConnState) {
		limit(conn, state)
		states <- transition{conn.RemoteAddr().String(), state}
	}
	server.Start()
	defer server.Close()
	endpoint, _ := url.Parse(server.URL)
	var peers []net.Conn
	for i := 0; i < 2; i++ {
		peer, err := net.Dial("tcp", endpoint.Host)
		if err != nil {
			t.Fatal(err)
		}
		defer peer.Close()
		peers = append(peers, peer)
		select {
		case <-states:
		case <-time.After(time.Second):
			t.Fatal("idle connection was not accepted")
		}
	}
	transport := &http.Transport{}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: time.Second}
	if response, err := client.Get(server.URL); err == nil {
		response.Body.Close()
		t.Fatal("HTTP connection capacity was exceeded")
	}
	address := peers[0].LocalAddr().String()
	_ = peers[0].Close()
	deadline := time.NewTimer(time.Second)
	defer deadline.Stop()
	for {
		select {
		case state := <-states:
			if state.address == address && state.state == http.StateClosed {
				response, err := client.Get(server.URL)
				if err != nil {
					t.Fatal(err)
				}
				body, err := io.ReadAll(response.Body)
				response.Body.Close()
				if err != nil || string(body) != "ok" {
					t.Fatal("released connection capacity was not reusable")
				}
				return
			}
		case <-deadline.C:
			t.Fatal("closed connection did not release capacity")
		}
	}
}

func TestEscapedMetadataAndMaximumTextFitOneFrame(t *testing.T) {
	h, server, conn, shareURL := openTestAgent(t)
	defer server.Close()
	defer conn.CloseNow()
	conn.SetReadLimit(maxWebSocketMessageSize)
	h.mu.Lock()
	for _, item := range h.shares {
		item.textInbox = true
	}
	h.mu.Unlock()
	body := bytes.Repeat([]byte("x"), 64<<10)
	request, _ := http.NewRequest(http.MethodPost, shareURL+"ls/text?q="+strings.Repeat("<", 4000), bytes.NewReader(body))
	request.Header.Set("Content-Type", "text/plain")
	request.Header.Set("User-Agent", strings.Repeat("<", 4000))
	done := make(chan error, 1)
	go func() {
		response, err := (&http.Client{Timeout: time.Second}).Do(request)
		if err == nil {
			response.Body.Close()
			if response.StatusCode != 200 {
				err = fmt.Errorf("status: %d", response.StatusCode)
			}
		}
		done <- err
	}()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(payload) > maxWebSocketMessageSize {
		t.Fatal("valid text request exceeded receiver frame limit")
	}
	var begin wireMessage
	if json.Unmarshal(payload, &begin) != nil || !bytes.Equal(begin.Body, body) {
		t.Fatal("text request was not preserved")
	}
	for _, message := range []wireMessage{
		{Type: "response.begin", RequestID: begin.RequestID, Status: 200, Headers: map[string]string{"Content-Length": "0"}},
		{Type: "response.end", RequestID: begin.RequestID},
	} {
		raw, _ := json.Marshal(message)
		if err := conn.Write(ctx, websocket.MessageText, raw); err != nil {
			t.Fatal(err)
		}
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	request, _ = http.NewRequest(http.MethodPost, shareURL+"ls/text", bytes.NewReader(body))
	request.Header.Set("User-Agent", strings.Repeat("<", 8000))
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 431 {
		t.Fatalf("oversized escaped headers: %d", response.StatusCode)
	}
	h.mu.Lock()
	connected := len(h.agents)
	h.mu.Unlock()
	if connected != 1 {
		t.Fatal("rejected metadata disconnected the device")
	}
}
