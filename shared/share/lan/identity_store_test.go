package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"strings"
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
	for _, label := range []string{"", "../escape", "a/b", "a:b", "换行\n", "外部\u202e字符"} {
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

func TestUTF8PeerRecordsKeepOriginalNames(t *testing.T) {
	root := t.TempDir()
	legacy := [32]byte{1}
	chinese := [32]byte{2}
	if err := addPeer(root, "laptop-1", legacy); err != nil {
		t.Fatal(err)
	}
	name := "客厅 电脑 💻"
	if err := addPeer(root, name, chinese); err != nil {
		t.Fatal(err)
	}
	path, err := peerFile(root, name)
	if err != nil || strings.Contains(filepath.Base(path), "客厅") {
		t.Fatalf("name appeared in filename: %v", err)
	}
	gotLabel, gotPin, err := readUTF8Peer(path)
	if err != nil || gotLabel != name || gotPin != chinese {
		t.Fatalf("UTF-8 record returned %q: %v", gotLabel, err)
	}
	if got, err := loadPeer(root, name); err != nil || got != chinese {
		t.Fatalf("load Unicode record: %v", err)
	}
	if got, err := loadPeer(root, "laptop-1"); err != nil || got != legacy {
		t.Fatalf("load legacy record: %v", err)
	}
	if err := addPeer(root, name, legacy); err == nil {
		t.Fatal("replaced a UTF-8 peer record")
	}
	otherName := "Café PC"
	if err := addPeer(root, otherName, legacy); err != nil {
		t.Fatal(err)
	}
	if err := revokePeer(root, name); err != nil {
		t.Fatal(err)
	}
	if _, err := loadPeer(root, name); !os.IsNotExist(err) {
		t.Fatalf("revoked record: %v", err)
	}
	otherPath, err := peerFile(root, otherName)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(otherPath)
	if err != nil {
		t.Fatal(err)
	}
	wrongPath, err := peerFile(root, "另一台")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(wrongPath, data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := readUTF8Peer(wrongPath); err == nil {
		t.Fatal("accepted another peer's record at a mismatched alias")
	}
	fp := sha256.Sum256([]byte(otherName))
	if !strings.Contains(filepath.Base(otherPath), fmt.Sprintf("%x", fp)) {
		t.Fatal("record filename was not derived from the exact UTF-8 lookup key")
	}
}
