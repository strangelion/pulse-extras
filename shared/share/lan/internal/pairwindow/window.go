// Package pairwindow holds local-only pairing-window policy. It does not
// authenticate a network peer; a reviewed PAKE adapter must do that.
package pairwindow

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"sync"
	"time"
)

const (
	Step = 60 * time.Second
	Lifetime = 3 * time.Minute
	MaxAttempts = 5
)

var ErrClosed = errors.New("pairing window unavailable")

// Window is process-local, single-use and never persisted. Do not copy it.
// No device identifier, MAC address or clock value is used as a secret.
type Window struct {
	mu sync.Mutex
	seed [32]byte
	started time.Time
	attempts int
	pending bool
	closed bool
	ticket uint64
	deadline time.Time
}

func New() (*Window, error) {
	w := &Window{started: time.Now()}
	if _, err := rand.Read(w.seed[:]); err != nil { return nil, err }
	return w, nil
}

// RFC 6238 HMAC-SHA256 with 8 digits. A public counter is not secret.
func code(seed []byte, counter uint64) string {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], counter)
	h := hmac.New(sha256.New, seed)
	h.Write(b[:])
	sum := h.Sum(nil)
	i := int(sum[len(sum)-1] & 15)
	return fmt.Sprintf("%08d", (binary.BigEndian.Uint32(sum[i:i+4]) & 0x7fffffff) % 100000000)
}

func (w *Window) closeLocked() {
	w.closed = true
	w.pending = false
	clear(w.seed[:])
}

func (w *Window) current(now time.Time) (string, time.Duration, error) {
	elapsed := now.Sub(w.started)
	if w.closed || elapsed < 0 || elapsed >= Lifetime {
		w.closeLocked()
		return "", 0, ErrClosed
	}
	// Use the monotonic elapsed time from the start, not a mutable wall clock.
	seconds := w.started.Add(elapsed).Unix()
	if seconds < 0 { w.closeLocked(); return "", 0, ErrClosed }
	remaining := time.Duration(60-seconds%60)*time.Second - time.Duration(w.started.Add(elapsed).Nanosecond())
	remaining = min(remaining, Lifetime-elapsed)
	return code(w.seed[:], uint64(seconds/60)), remaining, nil
}

// Display returns the locally visible current code, never a log message.
func (w *Window) Display() (string, time.Duration, error) {
	w.mu.Lock(); defer w.mu.Unlock()
	if w.attempts >= MaxAttempts && !w.pending { w.closeLocked() }
	return w.current(time.Now())
}

// Begin reserves exactly one online attempt before invoking PAKE. The code
// returned is a local password input for the adapter, NEVER a wire message.
// No overlap or previous-step fallback is allowed.
func (w *Window) Begin() (uint64, string, time.Duration, error) {
	return w.begin(time.Now())
}

func (w *Window) begin(now time.Time) (uint64, string, time.Duration, error) {
	w.mu.Lock(); defer w.mu.Unlock()
	if w.pending { return 0, "", 0, ErrClosed }
	if w.attempts >= MaxAttempts { w.closeLocked(); return 0, "", 0, ErrClosed }
	password, remaining, err := w.current(now)
	if err != nil { return 0, "", 0, err }
	w.attempts++
	w.ticket++
	w.pending = true
	w.deadline = now.Add(remaining)
	return w.ticket, password, remaining, nil
}

// Finish is called ONLY by the future authenticated adapter after mutual
// key confirmation and identity binding. A bool received from a peer is not
// evidence of authentication. This method cannot save trust or send files.
func (w *Window) Finish(ticket uint64, authenticated bool) bool {
	return w.finish(time.Now(), ticket, authenticated)
}

func (w *Window) finish(now time.Time, ticket uint64, authenticated bool) bool {
	w.mu.Lock(); defer w.mu.Unlock()
	if w.closed || !w.pending || ticket != w.ticket { return false }
	w.pending = false
	valid := authenticated && !now.Before(w.started) && now.Before(w.deadline)
	if valid || w.attempts >= MaxAttempts || now.Sub(w.started) >= Lifetime { w.closeLocked() }
	return valid
}

func (w *Window) Close() {
	w.mu.Lock(); defer w.mu.Unlock()
	w.closeLocked()
}
