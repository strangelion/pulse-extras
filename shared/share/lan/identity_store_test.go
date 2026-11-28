package main

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestPeerRecords(t *testing.T) {
	root := t.TempDir()
	pin := [32]byte{1, 2, 3}
	if err := addPeer(root, "laptop-1", pin); err != nil { t.Fatal(err) }
	got, err := loadPeer(root, "laptop-1")
	if err != nil || got != pin { t.Fatalf("load: %v %v", got, err) }
	if err := addPeer(root, "laptop-1", [32]byte{4}); err == nil { t.Fatal("replaced existing peer") }
	for _, label := range []string{"", "../escape", "a/b", "A", "a:b"} {
		if err := addPeer(root, label, pin); err == nil { t.Fatalf("accepted %q", label) }
	}
	if err := revokePeer(root, "laptop-1"); err != nil { t.Fatal(err) }
	if _, err := loadPeer(root, "laptop-1"); !os.IsNotExist(err) { t.Fatalf("revocation: %v", err) }
	if err := os.WriteFile(filepath.Join(root, "peer-bad.pin"), []byte("broken"), 0600); err != nil { t.Fatal(err) }
	if _, err := loadPeer(root, "bad"); err == nil { t.Fatal("accepted malformed peer") }
}

func TestPersistentIdentity(t *testing.T) {
	if runtime.GOOS != "windows" { t.Skip("Windows DPAPI") }
	root := t.TempDir()
	id, err := initStoredIdentity(root)
	if err != nil { t.Fatal(err) }
	got, err := loadStoredIdentity(root)
	if err != nil || got.pin != id.pin { t.Fatalf("load: %v", err) }
	if _, err := initStoredIdentity(root); err == nil { t.Fatal("replaced stored identity") }
	again, err := loadStoredIdentity(root)
	if err != nil || again.pin != id.pin { t.Fatalf("identity changed: %v", err) }
	path := filepath.Join(root, identityFile)
	blob, err := os.ReadFile(path)
	if err != nil { t.Fatal(err) }
	if bytes.Contains(blob, id.cert.Certificate[0]) { t.Fatal("unprotected identity data") }
	blob[len(blob)/2] ^= 1
	if err := os.WriteFile(path, blob, 0600); err != nil { t.Fatal(err) }
	if _, err := loadStoredIdentity(root); err == nil { t.Fatal("accepted tampered identity") }
}
