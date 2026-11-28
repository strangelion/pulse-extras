package main

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"unicode"
	"unicode/utf8"
)

const peerNameLimit = 48
const utf8PeerPrefix = "peer-utf8-"
const peerSuffix = ".pin"

func legacyPeerName(name string) bool {
	if len(name) == 0 || len(name) > peerNameLimit {
		return false
	}
	for _, c := range name {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

func validPeerName(name string) bool {
	if name == "" || len(name) > 4*peerNameLimit || strings.Trim(name, " ") != name ||
		!utf8.ValidString(name) || utf8.RuneCountInString(name) > peerNameLimit {
		return false
	}
	for _, c := range name {
		if unicode.IsControl(c) || strings.ContainsRune(`<>:"/\|?*`, c) ||
			c >= '\u2028' && c <= '\u202e' || c >= '\u2066' && c <= '\u2069' || c == '\ufeff' {
			return false
		}
	}
	return true
}

// Keep existing lowercase records at their original paths. Other display
// names are never used as filenames. Exact UTF-8 bytes identify a record.
func peerFile(root, name string) (string, error) {
	if !validPeerName(name) {
		return "", errors.New("invalid UTF-8 device label")
	}
	if legacyPeerName(name) {
		return filepath.Join(root, "peer-"+name+peerSuffix), nil
	}
	digest := sha256.Sum256([]byte(name))
	return filepath.Join(root, fmt.Sprintf("%s%x%s", utf8PeerPrefix, digest, peerSuffix)), nil
}

func addPeer(root, name string, pin [32]byte) error {
	path, err := peerFile(root, name)
	if err != nil {
		return err
	}
	if legacyPeerName(name) {
		return createStoreFile(path, []byte(fmt.Sprintf("%x\n", pin)))
	}
	return createStoreFile(path, []byte(fmt.Sprintf("v2\n%s\n%x\n", name, pin)))
}

func readUTF8Peer(path string) (string, [32]byte, error) {
	data, err := readStoreFile(path, 4*peerNameLimit+69)
	if err != nil {
		return "", [32]byte{}, err
	}
	lines := strings.Split(string(data), "\n")
	if len(lines) != 4 || lines[0] != "v2" || lines[3] != "" || len(lines[2]) != 64 || legacyPeerName(lines[1]) {
		return "", [32]byte{}, errors.New("invalid UTF-8 peer record")
	}
	expected, err := peerFile(filepath.Dir(path), lines[1])
	if err != nil || filepath.Base(expected) != filepath.Base(path) {
		return "", [32]byte{}, errors.New("UTF-8 peer record does not match its filename")
	}
	pin, err := parsePin(lines[2])
	return lines[1], pin, err
}

func loadPeer(root, name string) ([32]byte, error) {
	path, err := peerFile(root, name)
	if err != nil {
		return [32]byte{}, err
	}
	if !legacyPeerName(name) {
		label, pin, err := readUTF8Peer(path)
		if err != nil {
			return [32]byte{}, err
		}
		if label != name {
			return [32]byte{}, errors.New("UTF-8 peer record has the wrong label")
		}
		return pin, nil
	}
	data, err := readStoreFile(path, 65)
	if err != nil {
		return [32]byte{}, err
	}
	if len(data) != 65 || data[64] != '\n' {
		return [32]byte{}, errors.New("invalid peer record")
	}
	return parsePin(string(data[:64]))
}

func revokePeer(root, name string) error {
	path, err := peerFile(root, name)
	if err != nil {
		return err
	}
	if _, err = loadPeer(root, name); err != nil {
		return err
	}
	return os.Remove(path)
}

func listPeers(root string) error {
	dir, err := os.Open(root)
	if err != nil {
		return err
	}
	defer dir.Close()
	entries, err := dir.ReadDir(1025)
	if err != nil && err != io.EOF {
		return err
	}
	if len(entries) > 1024 {
		return errors.New("store has too many entries")
	}
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, "peer-") || !strings.HasSuffix(name, peerSuffix) {
			continue
		}
		if len(name) == len(utf8PeerPrefix)+64+len(peerSuffix) && strings.HasPrefix(name, utf8PeerPrefix) {
			label, pin, err := readUTF8Peer(filepath.Join(root, name))
			if err != nil {
				return fmt.Errorf("invalid peer record: %w", err)
			}
			fmt.Printf("PEER2 %x %s\n", pin, label)
			continue
		}
		label := strings.TrimSuffix(strings.TrimPrefix(name, "peer-"), peerSuffix)
		if !legacyPeerName(label) {
			return errors.New("invalid legacy peer filename")
		}
		pin, err := loadPeer(root, label)
		if err != nil {
			return fmt.Errorf("invalid peer record: %w", err)
		}
		fmt.Printf("PEER %s %x\n", label, pin)
	}
	return nil
}
