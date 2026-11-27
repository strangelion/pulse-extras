package main

// Experimental enrollment controller. No CLI or Pulse UI calls this yet.
// The native supervisor must pin the adapter before any production caller
// is enabled. Codes are delivered only to a private local display callback.
import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"time"

	"pulse-extras/share-lan/internal/pairauth"
	"pulse-extras/share-lan/internal/pairwindow"
)

var errPairDeclined = errors.New("pairing declined")
var errPairUncertain = errors.New("pairing enrollment incomplete; inspect both local peer stores")

// Each party owns its label. A peer cannot choose a local file path.
type pairConfig struct {
	id identity
	root, label, helper string
	consent func(context.Context, [32]byte) (bool,error)
}

// LocalSaved is evidence of the local successful exclusive write, not
// evidence that the other computer committed. PeerReportedSaved is only
// an authenticated peer's report. No implicit rollback on disconnection.
type pairResult struct {
	pin [32]byte
	localWriteAttempted bool
	localSaved bool
	peerReportKnown bool
	peerReportedSaved bool
}

// The callback must be local, nonblocking and private. An empty code means
// clear the display. Never log or persist this value.
type pairDisplay func(endpoint netip.AddrPort, code string, validFor time.Duration)

func (p pairConfig) validate() error {
	if p.consent==nil || !filepath.IsAbs(p.helper) {
		return errors.New("missing local pairing configuration")
	}
	if len(p.id.cert.Certificate)!=1 || sha256.Sum256(p.id.cert.Certificate[0])!=p.id.pin {
		return errors.New("invalid local pairing identity")
	}
	root,err:=storeRoot(p.root)
	if err!=nil{return err}
	path,err:=peerFile(root,p.label)
	if err!=nil{return err}
	if _,err=os.Lstat(path); !os.IsNotExist(err) {
		if err!=nil{return err}
		return errors.New("peer label already exists; choose a new label or revoke explicitly")
	}
	return nil
}

// This TLS channel initially proves possession but does not establish trust.
// It is used solely for the PAKE exchange and then explicit enrollment.
func pairingTLS(id identity,server bool)*tls.Config{
	c:=&tls.Config{
		Certificates:[]tls.Certificate{id.cert},
		MinVersion:tls.VersionTLS13,MaxVersion:tls.VersionTLS13,
		NextProtos:[]string{pairauth.Protocol},SessionTicketsDisabled:true,
		InsecureSkipVerify:!server,
		VerifyConnection:func(s tls.ConnectionState)error{
			if s.NegotiatedProtocol!=pairauth.Protocol||len(s.PeerCertificates)!=1{
				return errors.New("unexpected pairing certificate")
			}
			cert:=s.PeerCertificates[0]
			pub,ok:=cert.PublicKey.(*ecdsa.PublicKey)
			if !ok||pub.Curve!=elliptic.P256()||len(cert.Raw)>8192||cert.IsCA{
				return errors.New("unsupported pairing identity")
			}
			now:=time.Now()
			if now.Before(cert.NotBefore)||now.After(cert.NotAfter){
				return errors.New("expired pairing identity")
			}
			return nil
		},
	}
	if server{c.ClientAuth=tls.RequireAnyClientCert}
	return c
}

func authenticatePair(ctx context.Context, raw net.Conn, p pairConfig, password []byte, server bool)(*tls.Conn,[32]byte,error){
	var none [32]byte
	ctx,cancel:=context.WithTimeout(ctx,10*time.Second)
	defer cancel()
	stop:=context.AfterFunc(ctx,func(){raw.Close()})
	defer stop()
	deadline,_:=ctx.Deadline()
	if err:=raw.SetDeadline(deadline);err!=nil{return nil,none,err}
	var conn *tls.Conn
	if server{conn=tls.Server(raw,pairingTLS(p.id,true))}else{conn=tls.Client(raw,pairingTLS(p.id,false))}
	if err:=conn.HandshakeContext(ctx);err!=nil{return nil,none,err}
	pin,err:=pairauth.Confirm(ctx,conn,p.id.pin,password,server,p.helper)
	if err!=nil||ctx.Err()!=nil{return nil,none,errors.New("pair authentication failed")}
	return conn,pin,nil
}

// Exchange exactly one status byte each way in a fixed role order. This
// runs only inside the authenticated pairing TLS connection. No arbitrary
// peer strings, paths or decisions are passed to local storage.
func pairExchange(conn net.Conn, server bool, local byte)(byte,error){
	var other [1]byte
	if !server{
		if err:=writeAll(conn,[]byte{local});err!=nil{return 0,err}
		if err:=readStatusByte(conn,&other);err!=nil{return 0,err}
	}else{
		if err:=readStatusByte(conn,&other);err!=nil{return 0,err}
		if err:=writeAll(conn,[]byte{local});err!=nil{return 0,err}
	}
	return other[0],nil
}

func readStatusByte(conn net.Conn,b *[1]byte)error{
	if _,err:=io.ReadFull(conn,b[:]);err!=nil{return err}
	if b[0]!=0&&b[0]!=1{return errors.New("invalid pairing status")}
	return nil
}

// Both operators must approve the exact authenticated certificate pin
// before either side attempts a write. A failure after the consent exchange
// is explicitly partial/uncertain; distributed atomic commit is not claimed.
func enrollPair(ctx context.Context,conn *tls.Conn,p pairConfig,pin [32]byte,server bool)(pairResult,error){
	result:=pairResult{pin:pin}
	ctx,cancel:=context.WithTimeout(ctx,90*time.Second)
	defer cancel()
	stop:=context.AfterFunc(ctx,func(){conn.Close()})
	defer stop()
	deadline,_:=ctx.Deadline()
	if err:=conn.SetDeadline(deadline);err!=nil{return result,err}
	approved,err:=p.consent(ctx,pin)
	if err!=nil||ctx.Err()!=nil{approved=false}
	local:=byte(0)
	if approved{local=1}
	other,err:=pairExchange(conn,server,local)
	if err!=nil{return result,err}
	if local!=1||other!=1{return result,errPairDeclined}
	if ctx.Err()!=nil{return result,errPairUncertain}
	result.localWriteAttempted=true
	saveErr:=addPeer(p.root,p.label,pin)
	result.localSaved=saveErr==nil
	local=0
	if result.localSaved{local=1}
	other,err=pairExchange(conn,server,local)
	if err!=nil{return result,errPairUncertain}
	result.peerReportKnown=true
	result.peerReportedSaved=other==1
	if !result.localSaved||!result.peerReportedSaved{return result,errPairUncertain}
	return result,nil
}

// Explicit, single-use pairing host on one selected local interface.
// A listener accepts at most five admitted attempts. Authentication is
// bounded by both the current code step and the overall pairing window.
// There is no automatic advertisement or background listener.
func hostPair(ctx context.Context,b binding,port uint16,p pairConfig,display pairDisplay)(pairResult,error){
	var none pairResult
	if display==nil{return none,errors.New("private pairing display required")}
	if err:=p.validate();err!=nil{return none,err}
	listener,err:=net.ListenTCP(b.network(),net.TCPAddrFromAddrPort(netip.AddrPortFrom(b.ip,port)))
	if err!=nil{return none,err}
	defer listener.Close()
	endpoint:=listener.Addr().(*net.TCPAddr).AddrPort()
	defer display(endpoint,"",0)
	window,err:=pairwindow.New()
	if err!=nil{return none,err}
	defer window.Close()
	authCtx,cancel:=context.WithTimeout(ctx,pairwindow.Lifetime)
	defer cancel()
	stop:=context.AfterFunc(authCtx,func(){listener.Close()})
	defer stop()
	for authCtx.Err()==nil{
		code,remaining,err:=window.Display()
		if err!=nil{return none,err}
		display(endpoint,code,remaining)
		deadline:=time.Now().Add(min(remaining,time.Second))
		if err:=listener.SetDeadline(deadline);err!=nil{return none,err}
		raw,err:=listener.AcceptTCP()
		if err!=nil{
			if ne,ok:=err.(net.Error);ok&&ne.Timeout(){continue}
			return none,err
		}
		if !b.allows(raw.RemoteAddr().(*net.TCPAddr).AddrPort().Addr()){
			raw.Close()
			continue
		}
		ticket,password,remaining,err:=window.Begin()
		if err!=nil{raw.Close();return none,err}
		attempt,cancelAttempt:=context.WithTimeout(authCtx,remaining)
		secret:=[]byte(password)
		conn,pin,authErr:=authenticatePair(attempt,raw,p,secret,true)
		clear(secret)
		cancelAttempt()
		if !window.Finish(ticket,authErr==nil){
			raw.Close()
			continue
		}
		// Success consumes the code before human consent. Stop accepting
		// further attempts; the consent exchange has its own bounded timer.
		listener.Close()
		stop()
		cancel()
		display(endpoint,"",0)
		defer raw.Close()
		return enrollPair(ctx,conn,p,pin,true)
	}
	return none,authCtx.Err()
}

// The initiating user supplies the code from the other computer's private
// display. The address is an explicitly reviewed numeric on-link endpoint.
func joinPair(ctx context.Context,b binding,endpoint string,p pairConfig,password []byte)(pairResult,error){
	var none pairResult
	if err:=p.validate();err!=nil{return none,err}
	if len(password)!=8{return none,errors.New("invalid connection code")}
	for _,c:=range password{if c<'0'||c>'9'{return none,errors.New("invalid connection code")}}
	addr,err:=b.peer(endpoint)
	if err!=nil{return none,err}
	dialer:=net.Dialer{Timeout:10*time.Second,LocalAddr:net.TCPAddrFromAddrPort(netip.AddrPortFrom(b.ip,0))}
	raw,err:=dialer.DialContext(ctx,b.network(),addr.String())
	if err!=nil{return none,err}
	defer raw.Close()
	conn,pin,err:=authenticatePair(ctx,raw,p,password,false)
	if err!=nil{return none,err}
	return enrollPair(ctx,conn,p,pin,false)
}
