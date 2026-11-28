package main

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"os"
	"path/filepath"
	"time"
)

const identityFile = "identity.dpapi"
const storeLimit = 64 * 1024

// Explicit existing user-private directory. The caller must establish its
// ACL; DPAPI protects key material but is not a same-user sandbox.
func storeRoot(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", errors.New("use an absolute existing private store directory")
	}
	info, err := os.Lstat(path)
	if err != nil { return "", err }
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("expected a private directory, not a symlink")
	}
	return filepath.Clean(path), nil
}

func readStoreFile(path string, limit int64) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil { return nil, err }
	if !info.Mode().IsRegular() || info.Size() < 1 || info.Size() > limit {
		return nil, errors.New("invalid store file")
	}
	f, err := os.Open(path)
	if err != nil { return nil, err }
	defer f.Close()
	opened, err := f.Stat()
	if err != nil { return nil, err }
	if !os.SameFile(info, opened) { return nil, errors.New("store file changed") }
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil { return nil, err }
	if len(data) == 0 || int64(len(data)) > limit { return nil, errors.New("invalid store length") }
	return data, nil
}

// Exclusive creation only; do not silently overwrite identity or trust.
// On failure remove only the newly created file. Interrupted writes are
// rejected on load; recovery is explicit, not automatic key regeneration.
func createStoreFile(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil { return err }
	err = writeAll(f, data)
	if err == nil { err = f.Sync() }
	closeErr := f.Close()
	if err == nil { err = closeErr }
	if err != nil {
		if cleanup := os.Remove(path); cleanup != nil { return errors.Join(err, cleanup) }
	}
	return err
}

func initStoredIdentity(root string) (identity, error) {
	id, err := createIdentity(365 * 24 * time.Hour)
	if err != nil { return identity{}, err }
	key, ok := id.cert.PrivateKey.(*ecdsa.PrivateKey)
	if !ok { return identity{}, errors.New("unexpected identity key") }
	raw, err := x509.MarshalECPrivateKey(key)
	if err != nil { return identity{}, err }
	defer clear(raw)
	// Length-delimited encoding: two DER objects, one protected DPAPI blob.
	der := id.cert.Certificate[0]
	if len(der) > 8192 || len(raw) > 8192 { return identity{}, errors.New("identity exceeds size limit") }
	payload := make([]byte, 4+len(der)+len(raw))
	payload[0], payload[1] = byte(len(der)>>8), byte(len(der))
	payload[2], payload[3] = byte(len(raw)>>8), byte(len(raw))
	copy(payload[4:], der)
	copy(payload[4+len(der):], raw)
	defer clear(payload)
	encrypted, err := protectIdentity(payload)
	if err != nil { return identity{}, err }
	if err := createStoreFile(filepath.Join(root, identityFile), encrypted); err != nil { return identity{}, err }
	return id, nil
}

func loadStoredIdentity(root string) (identity, error) {
	data, err := readStoreFile(filepath.Join(root, identityFile), storeLimit)
	if err != nil { return identity{}, err }
	payload, err := unprotectIdentity(data)
	if err != nil { return identity{}, err }
	defer clear(payload)
	if len(payload) < 4 { return identity{}, errors.New("invalid identity") }
	dl, kl := int(payload[0])*256+int(payload[1]), int(payload[2])*256+int(payload[3])
	if dl == 0 || kl == 0 || dl > 8192 || kl > 8192 || 4+dl+kl != len(payload) {
		return identity{}, errors.New("invalid identity lengths")
	}
	der := append([]byte(nil), payload[4:4+dl]...)
	cert, err := x509.ParseCertificate(der)
	if err != nil { return identity{}, err }
	key, err := x509.ParseECPrivateKey(payload[4+dl:])
	if err != nil { return identity{}, err }
	pub, ok := cert.PublicKey.(*ecdsa.PublicKey)
	if !ok || !key.PublicKey.Equal(pub) { return identity{}, errors.New("identity key mismatch") }
	now := time.Now()
	if now.Before(cert.NotBefore) || now.After(cert.NotAfter) {
		return identity{}, errors.New("stored identity expired; initialize a new private store and pair again")
	}
	return identity{tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, sha256.Sum256(der)}, nil
}
