package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/coder/websocket"
)

const protocolVersion = 1
const maxWebSocketMessageSize = 8 << 20
const defaultRelayIdleTimeout = 60 * time.Second
const webSocketWriteTimeout = 10 * time.Second
const defaultStateDir = "/var/lib/localshare"

type credential struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Hash      string    `json:"hash"`
	Used      bool      `json:"used"`
	CreatedAt time.Time `json:"created_at"`
}

type device struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	TokenHash string    `json:"token_hash"`
	Revoked   bool      `json:"revoked"`
	CreatedAt time.Time `json:"created_at"`
}

type state struct {
	EnrollmentKeys []credential `json:"enrollment_keys"`
	Devices        []device     `json:"devices"`
}

type stateStore struct {
	path     string
	lockPath string
	mu       sync.Mutex
}

func newStateStore(dir string) (*stateStore, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, err
	}
	return &stateStore{
		path:     filepath.Join(dir, "state.json"),
		lockPath: filepath.Join(dir, ".state.lock"),
	}, nil
}

func (s *stateStore) load() (state, error) {
	var current state
	err := s.withFileLock(false, func() error {
		var err error
		current, err = s.loadUnlocked()
		return err
	})
	return current, err
}

func (s *stateStore) loadUnlocked() (state, error) {
	data, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return state{}, nil
	}
	if err != nil {
		return state{}, err
	}
	var current state
	if err := json.Unmarshal(data, &current); err != nil {
		return state{}, fmt.Errorf("read state: %w", err)
	}
	return current, nil
}

func (s *stateStore) saveUnlocked(current state) error {
	data, err := json.MarshalIndent(current, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	file, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return err
	}
	if _, err := file.Write(data); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

func (s *stateStore) withFileLock(exclusive bool, work func() error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	lockFile, err := os.OpenFile(s.lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lockFile.Close()
	if err := lockFile.Chmod(0o600); err != nil {
		return err
	}
	mode := syscall.LOCK_SH
	if exclusive {
		mode = syscall.LOCK_EX
	}
	if err := syscall.Flock(int(lockFile.Fd()), mode); err != nil {
		return err
	}
	defer syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)
	return work()
}

func (s *stateStore) update(work func(*state) error) error {
	return s.withFileLock(true, func() error {
		current, err := s.loadUnlocked()
		if err != nil {
			return err
		}
		if err := work(&current); err != nil {
			return err
		}
		return s.saveUnlocked(current)
	})
}

func randomToken(prefix string) (string, error) {
	data := make([]byte, 32)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return prefix + base64.RawURLEncoding.EncodeToString(data), nil
}

func tokenHash(value string) string {
	hash := sha256.Sum256([]byte(value))
	return base64.RawURLEncoding.EncodeToString(hash[:])
}

func (s *stateStore) createEnrollmentKey(name string) (string, string, error) {
	raw, err := randomToken("ls_enroll_")
	if err != nil {
		return "", "", err
	}
	id, err := randomToken("key_")
	if err != nil {
		return "", "", err
	}
	if err := s.update(func(current *state) error {
		current.EnrollmentKeys = append(current.EnrollmentKeys, credential{
			ID: id, Name: name, Hash: tokenHash(raw), CreatedAt: time.Now().UTC(),
		})
		return nil
	}); err != nil {
		return "", "", err
	}
	return id, raw, nil
}

func (s *stateStore) enroll(raw, name string) (string, string, error) {
	deviceID, err := randomToken("device_")
	if err != nil {
		return "", "", err
	}
	deviceToken, err := randomToken("ls_device_")
	if err != nil {
		return "", "", err
	}
	hash := tokenHash(raw)
	if err := s.update(func(current *state) error {
		keyIndex := -1
		for i := range current.EnrollmentKeys {
			if subtle.ConstantTimeCompare([]byte(current.EnrollmentKeys[i].Hash), []byte(hash)) == 1 && !current.EnrollmentKeys[i].Used {
				keyIndex = i
				break
			}
		}
		if keyIndex < 0 {
			return errors.New("invalid or already used enrollment key")
		}
		current.EnrollmentKeys[keyIndex].Used = true
		current.Devices = append(current.Devices, device{
			ID: deviceID, Name: name, TokenHash: tokenHash(deviceToken), CreatedAt: time.Now().UTC(),
		})
		return nil
	}); err != nil {
		return "", "", err
	}
	return deviceID, deviceToken, nil
}

func (s *stateStore) deviceForToken(raw string) (device, bool, error) {
	current, err := s.load()
	if err != nil {
		return device{}, false, err
	}
	hash := tokenHash(raw)
	for _, item := range current.Devices {
		if subtle.ConstantTimeCompare([]byte(item.TokenHash), []byte(hash)) == 1 {
			return item, !item.Revoked, nil
		}
	}
	return device{}, false, nil
}

func (s *stateStore) revokeDevice(id string) error {
	return s.update(func(current *state) error {
		for i := range current.Devices {
			if current.Devices[i].ID == id {
				current.Devices[i].Revoked = true
				return nil
			}
		}
		return errors.New("device not found")
	})
}

type wireMessage struct {
	Type       string            `json:"type"`
	Protocol   int               `json:"protocol,omitempty"`
	RequestID  string            `json:"request_id,omitempty"`
	Method     string            `json:"method,omitempty"`
	Path       string            `json:"path,omitempty"`
	Headers    map[string]string `json:"headers,omitempty"`
	Status     int               `json:"status,omitempty"`
	Error      string            `json:"error,omitempty"`
	ShareURL   string            `json:"share_url,omitempty"`
	ShareID    string            `json:"share_id,omitempty"`
	DeviceName string            `json:"device_name,omitempty"`
	Enrollment string            `json:"enrollment_key,omitempty"`
}

type relayMessage struct {
	kind    string
	status  int
	headers map[string]string
	data    []byte
	err     error
}

type pendingRequest struct {
	ch   chan relayMessage
	done chan struct{}
}

type agent struct {
	hub       *hub
	device    device
	conn      *websocket.Conn
	sendMu    sync.Mutex
	pendingMu sync.Mutex
	pending   map[string]*pendingRequest
}

type share struct {
	token    string
	shareID  string
	deviceID string
	agent    *agent
}

type hub struct {
	store              *stateStore
	publicURL          string
	mu                 sync.Mutex
	agents             map[string]*agent
	shares             map[string]*share
	requestIdleTimeout time.Duration
}

func newHub(store *stateStore, publicURL string) *hub {
	return &hub{
		store: store, publicURL: strings.TrimRight(publicURL, "/"), agents: map[string]*agent{},
		shares: map[string]*share{}, requestIdleTimeout: defaultRelayIdleTimeout,
	}
}

func normalizePublicURL(value string) (string, error) {
	u, err := url.ParseRequestURI(strings.TrimSpace(value))
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") ||
		u.User != nil || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("--public-url must be an http(s) base URL without path or query")
	}
	return strings.TrimRight(u.String(), "/"), nil
}

func (h *hub) enrollHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	var request wireMessage
	if err := json.NewDecoder(io.LimitReader(r.Body, 64<<10)).Decode(&request); err != nil || request.Enrollment == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid enrollment request"})
		return
	}
	deviceID, deviceToken, err := h.store.enroll(request.Enrollment, request.DeviceName)
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"device_id": deviceID, "device_token": deviceToken})
}

func (h *hub) agentHandler(w http.ResponseWriter, r *http.Request) {
	token := bearerToken(r.Header.Get("Authorization"))
	device, valid, err := h.store.deviceForToken(token)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "state unavailable"})
		return
	}
	if !valid {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid device token"})
		return
	}
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	conn.SetReadLimit(maxWebSocketMessageSize)
	a := &agent{hub: h, device: device, conn: conn, pending: map[string]*pendingRequest{}}
	h.mu.Lock()
	if old := h.agents[device.ID]; old != nil {
		_ = old.close(websocket.StatusGoingAway, "replaced")
	}
	h.agents[device.ID] = a
	h.mu.Unlock()
	defer h.removeAgent(a)
	_ = a.send(wireMessage{Type: "hello", Protocol: protocolVersion})
	a.readLoop(r.Context())
}

func (h *hub) removeAgent(a *agent) {
	h.mu.Lock()
	if h.agents[a.device.ID] == a {
		delete(h.agents, a.device.ID)
	}
	for token, item := range h.shares {
		if item.agent == a {
			delete(h.shares, token)
		}
	}
	h.mu.Unlock()
	a.failPending()
}

func (h *hub) startShare(a *agent, shareID string) (string, error) {
	if shareID == "" {
		return "", errors.New("share id is required")
	}
	token, err := randomToken("share_")
	if err != nil {
		return "", err
	}
	h.mu.Lock()
	for oldToken, item := range h.shares {
		if item.agent == a {
			delete(h.shares, oldToken)
		}
	}
	h.shares[token] = &share{token: token, shareID: shareID, deviceID: a.device.ID, agent: a}
	h.mu.Unlock()
	return h.publicURL + "/share/" + token + "/", nil
}

func (h *hub) stopShare(a *agent) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for token, item := range h.shares {
		if item.agent == a {
			delete(h.shares, token)
		}
	}
}

func (h *hub) shareHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	pathPart := strings.TrimPrefix(r.URL.EscapedPath(), "/share/")
	parts := strings.SplitN(pathPart, "/", 2)
	if len(parts) == 0 || parts[0] == "" {
		http.NotFound(w, r)
		return
	}
	token := parts[0]
	if len(parts) == 1 {
		target := r.URL.EscapedPath() + "/"
		if r.URL.RawQuery != "" {
			target += "?" + r.URL.RawQuery
		}
		http.Redirect(w, r, target, http.StatusPermanentRedirect)
		return
	}
	localPath := "/"
	if len(parts) == 2 {
		localPath += parts[1]
		if !strings.HasPrefix(localPath, "/") {
			localPath = "/" + localPath
		}
	}
	query := r.URL.Query()
	query.Del("t")
	if encodedQuery := query.Encode(); encodedQuery != "" {
		localPath += "?" + encodedQuery
	}
	h.mu.Lock()
	item := h.shares[token]
	h.mu.Unlock()
	if item == nil {
		http.NotFound(w, r)
		return
	}
	requestID, err := randomToken("req_")
	if err != nil {
		http.Error(w, "request unavailable", http.StatusInternalServerError)
		return
	}
	messages := item.agent.beginRequest(wireMessage{
		Type: "request.begin", RequestID: requestID, Method: r.Method, Path: localPath,
		Headers: forwardedRequestHeaders(r), ShareID: item.shareID,
	})
	defer item.agent.finishRequest(requestID)
	idleTimer := time.NewTimer(h.requestIdleTimeout)
	defer idleTimer.Stop()
	resetIdleTimer := func() {
		if !idleTimer.Stop() {
			select {
			case <-idleTimer.C:
			default:
			}
		}
		idleTimer.Reset(h.requestIdleTimeout)
	}
	started := false
	for {
		select {
		case <-r.Context().Done():
			item.agent.cancelRequest(requestID)
			return
		case message, ok := <-messages.ch:
			if !ok {
				if !started {
					http.Error(w, "agent unavailable", http.StatusBadGateway)
				}
				return
			}
			resetIdleTimer()
			switch message.kind {
			case "headers":
				if started {
					continue
				}
				started = true
				copyResponseHeaders(w, message.headers, token)
				if message.status == 0 {
					message.status = http.StatusOK
				}
				w.WriteHeader(message.status)
			case "data":
				if !started {
					http.Error(w, "invalid agent response", http.StatusBadGateway)
					return
				}
				if _, err := w.Write(message.data); err != nil {
					item.agent.cancelRequest(requestID)
					return
				}
				if flusher, ok := w.(http.Flusher); ok {
					flusher.Flush()
				}
			case "error":
				if !started {
					http.Error(w, message.err.Error(), http.StatusBadGateway)
				}
				return
			case "end":
				if !started {
					http.Error(w, "invalid agent response", http.StatusBadGateway)
				}
				return
			}
		case <-messages.done:
			if !started {
				http.Error(w, "agent unavailable", http.StatusBadGateway)
			}
			return
		case <-idleTimer.C:
			item.agent.cancelRequest(requestID)
			if !started {
				w.WriteHeader(http.StatusGatewayTimeout)
			}
			return
		}
	}
}

func (a *agent) readLoop(ctx context.Context) {
	for {
		typ, payload, err := a.conn.Read(ctx)
		if err != nil {
			return
		}
		if typ == websocket.MessageBinary {
			id, data, ok := decodeData(payload)
			if ok {
				a.deliver(id, relayMessage{kind: "data", data: data})
			}
			continue
		}
		var message wireMessage
		if json.Unmarshal(payload, &message) != nil {
			continue
		}
		switch message.Type {
		case "share.start":
			shareURL, err := a.hub.startShare(a, message.ShareID)
			if err != nil {
				_ = a.send(wireMessage{Type: "error", Error: err.Error()})
			} else {
				_ = a.send(wireMessage{Type: "share.ready", ShareURL: shareURL})
			}
		case "share.stop":
			a.hub.stopShare(a)
		case "response.begin":
			a.deliver(message.RequestID, relayMessage{kind: "headers", status: message.Status, headers: message.Headers})
		case "response.end":
			a.deliver(message.RequestID, relayMessage{kind: "end"})
		case "error":
			a.deliver(message.RequestID, relayMessage{kind: "error", err: errors.New(message.Error)})
		}
	}
}

func (a *agent) send(message wireMessage) error {
	data, err := json.Marshal(message)
	if err != nil {
		return err
	}
	a.sendMu.Lock()
	defer a.sendMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), webSocketWriteTimeout)
	defer cancel()
	return a.conn.Write(ctx, websocket.MessageText, data)
}

func (a *agent) close(code websocket.StatusCode, reason string) error {
	return a.conn.Close(code, reason)
}

func (a *agent) beginRequest(request wireMessage) *pendingRequest {
	pending := &pendingRequest{ch: make(chan relayMessage, 1), done: make(chan struct{})}
	a.pendingMu.Lock()
	a.pending[request.RequestID] = pending
	a.pendingMu.Unlock()
	if err := a.send(request); err != nil {
		a.deliver(request.RequestID, relayMessage{kind: "error", err: err})
	}
	return pending
}

func (a *agent) finishRequest(requestID string) {
	a.pendingMu.Lock()
	if pending := a.pending[requestID]; pending != nil {
		delete(a.pending, requestID)
		close(pending.done)
	}
	a.pendingMu.Unlock()
}

func (a *agent) cancelRequest(requestID string) {
	_ = a.send(wireMessage{Type: "request.cancel", RequestID: requestID})
}

func (a *agent) deliver(requestID string, message relayMessage) {
	a.pendingMu.Lock()
	pending := a.pending[requestID]
	a.pendingMu.Unlock()
	if pending != nil {
		select {
		case pending.ch <- message:
		case <-pending.done:
		}
	}
}

func (a *agent) failPending() {
	a.pendingMu.Lock()
	defer a.pendingMu.Unlock()
	for id, pending := range a.pending {
		delete(a.pending, id)
		close(pending.done)
	}
}

func forwardedRequestHeaders(r *http.Request) map[string]string {
	allowed := []string{"Accept", "Accept-Language", "If-Modified-Since", "If-None-Match", "Range", "User-Agent"}
	result := make(map[string]string)
	for _, name := range allowed {
		if value := r.Header.Get(name); value != "" {
			result[name] = value
		}
	}
	return result
}

func copyResponseHeaders(w http.ResponseWriter, headers map[string]string, shareToken string) {
	for name, value := range headers {
		lower := strings.ToLower(name)
		if lower == "set-cookie" || lower == "connection" || lower == "transfer-encoding" {
			continue
		}
		if strings.EqualFold(name, "Location") {
			value = rewriteLocation(value, shareToken)
		}
		w.Header().Set(name, value)
	}
}

func rewriteLocation(value, shareToken string) string {
	if strings.HasPrefix(value, "/") {
		return "/share/" + shareToken + value
	}
	return value
}

func encodeData(requestID string, data []byte) []byte {
	id := []byte(requestID)
	frame := make([]byte, 4+len(id)+len(data))
	binary.BigEndian.PutUint32(frame[:4], uint32(len(id)))
	copy(frame[4:], id)
	copy(frame[4+len(id):], data)
	return frame
}

func decodeData(frame []byte) (string, []byte, bool) {
	if len(frame) < 4 {
		return "", nil, false
	}
	idLen := int(binary.BigEndian.Uint32(frame[:4]))
	if idLen <= 0 || 4+idLen > len(frame) {
		return "", nil, false
	}
	return string(frame[4 : 4+idLen]), frame[4+idLen:], true
}

func bearerToken(value string) string {
	parts := strings.Fields(value)
	if len(parts) == 2 && strings.EqualFold(parts[0], "Bearer") {
		return parts[1]
	}
	return ""
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func runServe(args []string) error {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	listen := flags.String("listen", ":8080", "HTTP and WebSocket listen address")
	publicURL := flags.String("public-url", "", "public base URL used in share links")
	stateDir := flags.String("state-dir", defaultStateDir, "state directory")
	tlsCert := flags.String("tls-cert", "", "TLS certificate PEM file (required for an https public URL)")
	tlsKey := flags.String("tls-key", "", "TLS private key PEM file (required for an https public URL)")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *publicURL == "" {
		return errors.New("--public-url is required")
	}
	baseURL, err := normalizePublicURL(*publicURL)
	if err != nil {
		return err
	}
	useTLS := strings.HasPrefix(baseURL, "https://")
	if (*tlsCert == "") != (*tlsKey == "") {
		return errors.New("--tls-cert and --tls-key must be provided together")
	}
	if useTLS && (*tlsCert == "" || *tlsKey == "") {
		return errors.New("https --public-url requires --tls-cert and --tls-key")
	}
	if !useTLS && (*tlsCert != "" || *tlsKey != "") {
		return errors.New("--tls-cert and --tls-key require an https --public-url")
	}
	store, err := newStateStore(*stateDir)
	if err != nil {
		return err
	}
	h := newHub(store, baseURL)
	server := &http.Server{Addr: *listen, Handler: newHTTPHandler(h), ReadHeaderTimeout: 10 * time.Second}
	log.Printf("localshare-server listening on %s, public URL %s", *listen, baseURL)
	if useTLS {
		return server.ListenAndServeTLS(*tlsCert, *tlsKey)
	}
	return server.ListenAndServe()
}

func newHTTPHandler(h *hub) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("/api/v1/enroll", h.enrollHandler)
	mux.HandleFunc("/api/v1/agent", h.agentHandler)
	mux.HandleFunc("/share/", h.shareHandler)
	return mux
}

func runKey(args []string) error {
	if len(args) == 0 {
		return errors.New("key command requires create, list, or revoke")
	}
	flags := flag.NewFlagSet("key", flag.ContinueOnError)
	stateDir := flags.String("state-dir", defaultStateDir, "state directory")
	name := flags.String("name", "", "key label")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	store, err := newStateStore(*stateDir)
	if err != nil {
		return err
	}
	switch args[0] {
	case "create":
		id, value, err := store.createEnrollmentKey(*name)
		if err != nil {
			return err
		}
		fmt.Printf("id: %s\nkey: %s\n", id, value)
		return nil
	case "list":
		current, err := store.load()
		if err != nil {
			return err
		}
		for _, item := range current.EnrollmentKeys {
			fmt.Printf("%s\t%s\tused=%t\n", item.ID, item.Name, item.Used)
		}
		return nil
	case "revoke":
		if flags.NArg() != 1 {
			return errors.New("key revoke requires an id")
		}
		return revokeEnrollmentKey(store, flags.Arg(0))
	default:
		return fmt.Errorf("unknown key command %q", args[0])
	}
}

func revokeEnrollmentKey(store *stateStore, id string) error {
	return store.update(func(current *state) error {
		for i := range current.EnrollmentKeys {
			if current.EnrollmentKeys[i].ID == id {
				current.EnrollmentKeys[i].Used = true
				return nil
			}
		}
		return errors.New("key not found")
	})
}

func runDevice(args []string) error {
	if len(args) == 0 || (args[0] != "list" && args[0] != "revoke") || (args[0] == "revoke" && len(args) < 2) {
		return errors.New("device command requires list or revoke <id>")
	}
	flags := flag.NewFlagSet("device", flag.ContinueOnError)
	stateDir := flags.String("state-dir", defaultStateDir, "state directory")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	positional := flags.Args()
	store, err := newStateStore(*stateDir)
	if err != nil {
		return err
	}
	if args[0] == "list" {
		if len(positional) != 0 {
			return errors.New("device list does not accept an id")
		}
		current, err := store.load()
		if err != nil {
			return err
		}
		for _, item := range current.Devices {
			fmt.Printf("%s\t%s\trevoked=%t\n", item.ID, item.Name, item.Revoked)
		}
		return nil
	}
	if len(positional) != 1 {
		return errors.New("device revoke requires an id")
	}
	return store.revokeDevice(positional[0])
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: localshare-server serve --public-url <url> [--listen :8080] [--state-dir dir] [--tls-cert file --tls-key file]")
	fmt.Fprintln(os.Stderr, "       localshare-server key create|list|revoke [--name name] [--state-dir dir]")
	fmt.Fprintln(os.Stderr, "       localshare-server device list|revoke [--state-dir dir] [<id>]")
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "serve":
		err = runServe(os.Args[2:])
	case "key":
		err = runKey(os.Args[2:])
	case "device":
		err = runDevice(os.Args[2:])
	default:
		usage()
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Print(err)
		os.Exit(1)
	}
}
