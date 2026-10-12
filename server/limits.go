package main

import (
	"context"
	"net"
	"net/http"
	"sync"
	"time"
)

type serverLimits struct {
	maxDevices           int
	deviceRequests       int
	totalRequests        int
	registrationsPerHour int
	deviceBytesPerSecond int64
	totalBytesPerSecond  int64
}

func defaultLimits() serverLimits {
	return serverLimits{1000, 8, 64, 5, 4 << 20, 32 << 20}
}

type registrationWindow struct {
	started time.Time
	count   int
}

type deviceUsage struct {
	requests int
	bucket   bandwidthBucket
}

type bandwidthBucket struct {
	updated time.Time
	tokens  float64
}

func (b *bandwidthBucket) available(now time.Time, rate int64) float64 {
	if b.updated.IsZero() {
		b.tokens = float64(rate)
	} else {
		b.tokens += now.Sub(b.updated).Seconds() * float64(rate)
		if b.tokens > float64(rate) {
			b.tokens = float64(rate)
		}
	}
	b.updated = now
	return b.tokens
}

func (h *hub) clientIP(r *http.Request) string {
	address, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	if h.behindProxy && net.ParseIP(address).IsLoopback() {
		if ip := net.ParseIP(r.Header.Get("X-Real-IP")); ip != nil {
			return ip.String()
		}
	}
	return address
}

func (h *hub) allowRegistration(r *http.Request) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	allowed := allowAttempt(h.registrations, h.clientIP(r), time.Hour, h.limits.registrationsPerHour)
	if !allowed {
		h.failures["registration_limit"]++
	}
	return allowed
}

func (h *hub) allowConnection(r *http.Request) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	allowed := allowAttempt(h.connections, h.clientIP(r), time.Minute, 60)
	if !allowed {
		h.failures["connection_limit"]++
	}
	return allowed
}

func allowAttempt(windows map[string]*registrationWindow, ip string, interval time.Duration, limit int) bool {
	now := time.Now()
	for address, window := range windows {
		if now.Sub(window.started) >= interval {
			delete(windows, address)
		}
	}
	window := windows[ip]
	if window == nil {
		if len(windows) >= 4096 {
			return false
		}
		window = &registrationWindow{started: now}
		windows[ip] = window
	}
	if window.count >= limit {
		return false
	}
	window.count++
	return true
}

func (h *hub) acquireRequest(deviceID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	usage := h.usage[deviceID]
	if usage == nil {
		usage = &deviceUsage{}
		h.usage[deviceID] = usage
	}
	if usage.requests >= h.limits.deviceRequests || h.inFlight >= h.limits.totalRequests {
		h.rejectedRequests++
		h.failures["request_limit"]++
		return false
	}
	usage.requests++
	h.inFlight++
	return true
}

func (h *hub) releaseRequest(deviceID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.usage[deviceID].requests--
	h.inFlight--
	if h.usage[deviceID].requests == 0 && h.agents[deviceID] == nil {
		delete(h.usage, deviceID)
	}
}

func (h *hub) waitBandwidth(ctx context.Context, deviceID string, size int) error {
	for {
		h.mu.Lock()
		now := time.Now()
		device := &h.usage[deviceID].bucket
		availableDevice := device.available(now, h.limits.deviceBytesPerSecond)
		availableTotal := h.bandwidth.available(now, h.limits.totalBytesPerSecond)
		if availableDevice >= float64(size) && availableTotal >= float64(size) {
			device.tokens -= float64(size)
			h.bandwidth.tokens -= float64(size)
			h.relayedBytes += uint64(size)
			h.mu.Unlock()
			return nil
		}
		wait := (float64(size) - availableDevice) / float64(h.limits.deviceBytesPerSecond)
		if total := (float64(size) - availableTotal) / float64(h.limits.totalBytesPerSecond); total > wait {
			wait = total
		}
		h.mu.Unlock()
		timer := time.NewTimer(time.Duration(wait * float64(time.Second)))
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}

// Bound idle and incomplete HTTP connections; hijacked WebSockets have one slot per device.
func limitHTTPConnections(limit int) func(net.Conn, http.ConnState) {
	var mu sync.Mutex
	active := make(map[net.Conn]bool)
	return func(conn net.Conn, state http.ConnState) {
		mu.Lock()
		reject := false
		switch state {
		case http.StateNew:
			active[conn] = true
			reject = len(active) > limit
		case http.StateClosed, http.StateHijacked:
			delete(active, conn)
		}
		mu.Unlock()
		if reject {
			_ = conn.Close()
		}
	}
}

func (h *hub) recordFailure(category string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.failures[category]++
}
