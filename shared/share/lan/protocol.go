package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	maxFile = uint64(1024) * 1024 * 1024 * 1024
	chunk = 256 * 1024
	alpn = "pulse-share/1"
	offerTimeout = 2 * time.Minute
	transferTimeout = 30 * time.Minute
)

type identity struct {
	cert tls.Certificate
	pin [32]byte
}

func newIdentity() (identity, error) { return createIdentity(2*time.Hour) }

func createIdentity(lifetime time.Duration) (identity, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil { return identity{}, err }
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil { return identity{}, err }
	serial.Add(serial, big.NewInt(1))
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial, NotBefore: now.Add(-time.Minute),
		NotAfter: now.Add(lifetime),
		KeyUsage: x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil { return identity{}, err }
	return identity{tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, sha256.Sum256(der)}, nil
}

func parsePin(s string) ([32]byte, error) {
	var pin [32]byte
	if len(s) != 64 { return pin, errors.New("expected 64 hexadecimal fingerprint characters") }
	b, err := hex.DecodeString(s)
	if err != nil { return pin, errors.New("invalid fingerprint") }
	copy(pin[:], b)
	return pin, nil
}

// The operator must compare the entire certificate fingerprint through a
// separate trusted channel. Discovery NEVER authorizes an identity.
// TLS verifies possession of the pinned certificate's private key.
func tlsConfig(id identity, peer [32]byte, server bool) *tls.Config {
	config := &tls.Config{
		Certificates: []tls.Certificate{id.cert},
		MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
		NextProtos: []string{alpn}, SessionTicketsDisabled: true,
		CurvePreferences: []tls.CurveID{tls.X25519MLKEM768},
		VerifyConnection: func(state tls.ConnectionState) error {
			if state.NegotiatedProtocol != alpn || state.CurveID != tls.X25519MLKEM768 || len(state.PeerCertificates) != 1 {
				return errors.New("unexpected protocol or peer certificate chain")
			}
			cert := state.PeerCertificates[0]
			pin := sha256.Sum256(cert.Raw)
			if subtle.ConstantTimeCompare(pin[:], peer[:]) != 1 {
				return errors.New("peer fingerprint mismatch")
			}
			now := time.Now()
			if now.Before(cert.NotBefore) || now.After(cert.NotAfter) {
				return errors.New("peer identity expired")
			}
			return nil
		},
	}
	if server {
		config.ClientAuth = tls.RequireAnyClientCert
	} else {
		// Only the explicit, mandatory certificate pin above is the trust
		// root; public PKI names are not used for temporary LAN identities.
		config.InsecureSkipVerify = true
	}
	return config
}

type offer struct {
	name string
	size uint64
	digest [32]byte
}

// One Windows-compatible basename, no path, controls, reserved names or
// alternate streams. The native P1 supervisor independently checks it again.
func validName(s string) bool {
	if len(s)==0 || len(s)>240 || !utf8.ValidString(s) ||
		strings.HasSuffix(s, ".") || strings.HasSuffix(s, " ") ||
		strings.ContainsAny(s, "\\/:*?\"<>|") { return false }
	for _, r := range s {
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) { return false }
	}
	stem := strings.ToUpper(strings.TrimRight(strings.SplitN(s, ".", 2)[0], " "))
	switch stem {
	case "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$": return false
	}
	r := []rune(stem)
	if len(r)==4 && (string(r[:3])=="COM" || string(r[:3])=="LPT") &&
		((r[3]>='0' && r[3]<='9') || strings.ContainsRune("¹²³",r[3])) { return false }
	return true
}

func writeAll(w io.Writer, b []byte) error {
	for len(b)>0 {
		n,err:=w.Write(b)
		if err!=nil {return err}
		if n<=0 || n>len(b) {return io.ErrShortWrite}
		b=b[n:]
	}
	return nil
}

func writeOffer(w io.Writer, o offer) error {
	if !validName(o.name) || o.size>maxFile {return errors.New("invalid offer")}
	var header [46]byte
	copy(header[:4],"PSF1")
	binary.BigEndian.PutUint16(header[4:6],uint16(len(o.name)))
	binary.BigEndian.PutUint64(header[6:14],o.size)
	copy(header[14:],o.digest[:])
	if err:=writeAll(w,header[:]);err!=nil{return err}
	return writeAll(w,[]byte(o.name))
}

func readOffer(r io.Reader) (offer,error) {
	var header [46]byte
	if _,err:=io.ReadFull(r,header[:]);err!=nil{return offer{},err}
	n:=binary.BigEndian.Uint16(header[4:6])
	size:=binary.BigEndian.Uint64(header[6:14])
	if string(header[:4])!="PSF1" || n==0 || n>240 || size>maxFile {
		return offer{},errors.New("invalid offer header")
	}
	var name [240]byte
	if _,err:=io.ReadFull(r,name[:n]);err!=nil{return offer{},err}
	o:=offer{name:string(name[:n]),size:size}
	copy(o.digest[:],header[14:])
	if !validName(o.name){return offer{},errors.New("invalid filename")}
	return o,nil
}

func digestFile(f *os.File) (uint64,[32]byte,error) {
	var digest [32]byte
	info,err:=f.Stat()
	if err!=nil{return 0,digest,err}
	if !info.Mode().IsRegular() || info.Size()<0 || uint64(info.Size())>maxFile {
		return 0,digest,errors.New("source is not a bounded regular file")
	}
	if _,err=f.Seek(0,io.SeekStart);err!=nil{return 0,digest,err}
	h:=sha256.New()
	n,err:=io.CopyBuffer(h,io.LimitReader(f,info.Size()+1),make([]byte,chunk))
	if err!=nil{return 0,digest,err}
	if n!=info.Size(){return 0,digest,errors.New("source size changed")}
	copy(digest[:],h.Sum(nil))
	_,err=f.Seek(0,io.SeekStart)
	return uint64(n),digest,err
}

func readStatus(r io.Reader, expected byte) error {
	var b [1]byte
	if _,err:=io.ReadFull(r,b[:]);err!=nil{return err}
	if b[0]!=expected{return errors.New("peer declined or transfer failed")}
	return nil
}

func sendFile(c net.Conn,f *os.File,o offer) error { return sendFileProgress(c,f,o,nil) }

type progressWriter struct {
	w io.Writer
	total,done uint64
	last time.Time
	report func(uint64,uint64)
}
func (p *progressWriter) Write(b []byte)(int,error){
	n,err:=p.w.Write(b)
	p.done+=uint64(n)
	if p.report!=nil && (p.done==p.total || time.Since(p.last)>=250*time.Millisecond){
		p.report(p.done,p.total)
		p.last=time.Now()
	}
	return n,err
}

func sendFileProgress(c net.Conn,f *os.File,o offer,report func(uint64,uint64)) error {
	if err:=c.SetDeadline(time.Now().Add(offerTimeout));err!=nil{return err}
	if err:=writeOffer(c,o);err!=nil{return err}
	if err:=readStatus(c,1);err!=nil{return err}
	if err:=c.SetDeadline(time.Now().Add(transferTimeout));err!=nil{return err}
	h:=sha256.New()
	p:=&progressWriter{w:io.MultiWriter(c,h),total:o.size,report:report}
	if report!=nil{report(0,o.size)}
	n,err:=io.CopyBuffer(p,io.LimitReader(f,int64(o.size)),make([]byte,chunk))
	if err!=nil{return err}
	if uint64(n)!=o.size || !bytes.Equal(h.Sum(nil),o.digest[:]){
		return errors.New("source changed during send")
	}
	// The completion marker is separate from the bytes; receiver cannot
	// publish a truncated stream or a transfer whose sender did not finish.
	if err:=writeAll(c,[]byte{2});err!=nil{return err}
	return readStatus(c,3)
}

type approveFunc func(offer) (bool,error)
type commitFunc func(offer,string) error

// Spool parent is explicitly approved locally; no peer path is ever used to
// create the temporary file. Native commit performs the final no-overwrite
// copy. The caller supplies a user-private directory (Windows ACL inherited).
func receiveFile(c net.Conn,spool string,approve approveFunc,commit commitFunc) error {
	return receiveFileProgress(c,spool,approve,commit,nil)
}
func receiveFileProgress(c net.Conn,spool string,approve approveFunc,commit commitFunc,report func(uint64,uint64)) (result error) {
	if err:=c.SetDeadline(time.Now().Add(offerTimeout));err!=nil{return err}
	o,err:=readOffer(c)
	if err!=nil{return err}
	yes,err:=approve(o)
	if err!=nil || !yes {
		_ = writeAll(c,[]byte{0})
		if err!=nil{return err}
		return errors.New("local user declined")
	}
	dir,err:=os.MkdirTemp(spool,"pulse-share-")
	if err!=nil{return err}
	defer func(){
		// This is our newly created directory; remove only our one known file
		// and then the empty directory, never recursively remove foreign files.
		if err:=os.Remove(dir);err!=nil && result==nil{result=fmt.Errorf("spool directory cleanup: %w",err)}
	}()
	j,err:=newJournal(dir,o)
	if err!=nil{return err}
	defer func(){
		if err:=os.Remove(j.path);err!=nil && result==nil{result=fmt.Errorf("journal cleanup: %w",err)}
	}()
	path:=filepath.Join(dir,"payload.part")
	f,err:=os.OpenFile(path,os.O_WRONLY|os.O_CREATE|os.O_EXCL,0600)
	if err!=nil{return err}
	closed:=false
	defer func(){
		if !closed{_ = f.Close()}
		if err:=os.Remove(path);err!=nil && result==nil{result=fmt.Errorf("spool file cleanup: %w",err)}
	}()
	if err:=writeAll(c,[]byte{1});err!=nil{return err}
	if err:=c.SetDeadline(time.Now().Add(transferTimeout));err!=nil{return err}
	h:=sha256.New()
	p:=&progressWriter{w:io.MultiWriter(f,h),total:o.size,report:report}
	if report!=nil{report(0,o.size)}
	n,err:=io.CopyBuffer(p,io.LimitReader(c,int64(o.size)),make([]byte,chunk))
	if err!=nil{return err}
	if uint64(n)!=o.size || !bytes.Equal(h.Sum(nil),o.digest[:]){
		return errors.New("received length or SHA-256 mismatch")
	}
	if err:=readStatus(c,2);err!=nil{return err}
	if err:=f.Sync();err!=nil{return err}
	if err:=f.Close();err!=nil{return err}
	closed=true
	if err:=j.advance("verified");err!=nil{return err}
	if err:=j.advance("committing");err!=nil{return err}
	if err:=commit(o,path);err!=nil{_ = writeAll(c,[]byte{0});return err}
	if err:=j.advance("committed");err!=nil{
		return fmt.Errorf("file committed, local journal update failed: %w",err)
	}
	// Only a successful native no-overwrite commit permits the receipt.
	if err:=writeAll(c,[]byte{3});err!=nil{return fmt.Errorf("committed locally, receipt delivery uncertain: %w",err)}
	return nil
}
