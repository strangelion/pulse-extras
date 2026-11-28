package main

import (
	"bytes"
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
