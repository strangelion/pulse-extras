package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestPrepareDeviceCreatesAndKeepsPrivateIdentity(t *testing.T) {
	root := t.TempDir()
	store, spool := filepath.Join(root, "store"), filepath.Join(root, "spool")
	if err := prepareDevice(t.Context(), store, spool); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{store, spool} {
		if err := auditPrivateDirectory(path); err != nil {
			t.Fatal(err)
		}
	}
	key := filepath.Join(store, identityFile)
	before, err := os.ReadFile(key)
	if err != nil {
		t.Fatal(err)
	}
	if err := prepareDevice(t.Context(), store, spool); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(key)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("existing identity changed: %v", err)
	}
	if err := prepareDevice(t.Context(), store, store); err == nil {
		t.Fatal("accepted shared identity and spool path")
	}
	if err := os.WriteFile(key, []byte("broken"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := prepareDevice(t.Context(), store, spool); err == nil {
		t.Fatal("regenerated an unreadable identity")
	}
	after, err = os.ReadFile(key)
	if err != nil || string(after) != "broken" {
		t.Fatalf("unreadable identity changed: %v", err)
	}
}

func TestPrepareDeviceRejectsOrdinaryExistingDirectory(t *testing.T) {
	root := t.TempDir()
	store, spool := filepath.Join(root, "store"), filepath.Join(root, "spool")
	if err := os.Mkdir(store, 0700); err != nil {
		t.Fatal(err)
	}
	if err := prepareDevice(t.Context(), store, spool); err == nil {
		t.Fatal("accepted an ordinary existing directory")
	}
	if _, err := os.Lstat(filepath.Join(store, identityFile)); !os.IsNotExist(err) {
		t.Fatalf("changed refused identity directory: %v", err)
	}
}

func TestManagedReceiveSpoolCreationIsExplicitAndProtected(t *testing.T) {
	root := t.TempDir()
	spool := filepath.Join(root, "spool")
	if err := prepareReceiveSpool(t.Context(), spool, false); !errors.Is(err, errReceiveSpoolMissing) {
		t.Fatalf("expected an actionable missing-directory error: %v", err)
	}
	if _, err := os.Lstat(spool); !os.IsNotExist(err) {
		t.Fatalf("an unrequested spool appeared: %v", err)
	}
	cancelled, cancel := context.WithCancel(t.Context())
	cancel()
	if err := prepareReceiveSpool(cancelled, spool, true); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled request was admitted: %v", err)
	}
	if _, err := os.Lstat(spool); !os.IsNotExist(err) {
		t.Fatalf("cancelled request created a spool: %v", err)
	}
	for i := 0; i < 2; i++ {
		if err := prepareReceiveSpool(t.Context(), spool, true); err != nil {
			t.Fatal(err)
		}
	}
	if err := auditPrivateDirectory(spool); err != nil {
		t.Fatal(err)
	}
	ordinary := filepath.Join(root, "ordinary")
	if err := os.Mkdir(ordinary, 0700); err != nil {
		t.Fatal(err)
	}
	if err := prepareReceiveSpool(t.Context(), ordinary, true); err == nil {
		t.Fatal("accepted an existing directory with an inherited ACL")
	}
}
