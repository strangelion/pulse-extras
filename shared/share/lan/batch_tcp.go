package main

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"crypto/tls"
	"syscall"
	"time"

	"pulse-extras/share-lan/sharecore"
)

const laneHandshakeTimeout = 10*time.Second

// batchAuthorization is a local owner callback, NOT an authorization from
// a remote request. It checks the current saved peer, locally approved
// transaction/manifest and content grant, then returns the local identity.
// The same checks are required before and after every handshake. The owner
// must cancel active streams on grant revocation when that policy requires it.
type batchAuthorization func(context.Context,sharecore.Transaction)(identity,error)

func authorizeBatch(ctx context.Context,tx sharecore.Transaction,authorize batchAuthorization)(identity,error){
	if err:=ctx.Err();err!=nil{return identity{},err}
	if authorize==nil||tx.ID==(sharecore.Digest{})||tx.Peer==(sharecore.Digest{})||tx.Manifest==(sharecore.Digest{}){
		return identity{},errors.New("missing approved batch transaction")
	}
	id,err:=authorize(ctx,tx)
	if err!=nil{return identity{},err}
	if id.pin==([32]byte{})||len(id.cert.Certificate)!=1{return identity{},errors.New("missing local identity")}
	return id,nil
}

// authenticateBatchTCP owns raw on failure; the caller owns the successful
// TLS stream. No fallback ALPN, classical-only group or unauthenticated mode.
func authenticateBatchTCP(ctx context.Context,raw *net.TCPConn,tx sharecore.Transaction,id identity,server bool,authorize batchAuthorization)(conn *tls.Conn,err error){
	defer func(){if err!=nil{raw.Close()}}()
	stop:=context.AfterFunc(ctx,func(){raw.Close()});defer stop()
	if err=raw.SetDeadline(time.Now().Add(laneHandshakeTimeout));err!=nil{return nil,err}
	cfg:=tlsConfigForProtocol(id,tx.Peer,server,sharecore.LaneProtocol)
	if server{conn=tls.Server(raw,cfg)}else{conn=tls.Client(raw,cfg)}
	if err=conn.HandshakeContext(ctx);err!=nil{return nil,err}
	current,err:=authorizeBatch(ctx,tx,authorize)
	if err!=nil{return nil,err}
	if current.pin!=id.pin{return nil,errors.New("local identity changed during connection")}
	if err=raw.SetDeadline(time.Time{});err!=nil{return nil,err}
	if err=ctx.Err();err!=nil{return nil,err}
	return conn,nil
}

// Only dial failures known to be connectivity-related can trigger reconnect.
// Handshake errors are deliberately terminal, including ambiguous handshake
// interruptions; never retry a possible authentication failure automatically.
func batchDialError(err error)error{
	var n net.Error
	if errors.Is(err,syscall.ECONNREFUSED)||errors.Is(err,syscall.ECONNRESET)||
		errors.Is(err,syscall.ENETUNREACH)||errors.Is(err,syscall.EHOSTUNREACH)||
		(errors.As(err,&n)&&n.Timeout()){
		return sharecore.ErrLaneDisconnected
	}
	return err
}

// newBatchTCPOpener creates a transport adapter for an already approved
// local transaction. No sockets are opened until the scheduler admits a lane.
func newBatchTCPOpener(b binding,endpoint string,authorize batchAuthorization)(sharecore.OpenLane,error){
	addr,err:=b.peer(endpoint)
	if err!=nil{return nil,err}
	if authorize==nil{return nil,errors.New("missing local batch authorization")}
	return func(ctx context.Context,tx sharecore.Transaction)(sharecore.LaneStream,error){
		id,err:=authorizeBatch(ctx,tx,authorize)
		if err!=nil{return nil,err}
		dialer:=net.Dialer{Timeout:laneHandshakeTimeout,LocalAddr:net.TCPAddrFromAddrPort(netip.AddrPortFrom(b.ip,0))}
		raw,err:=dialer.DialContext(ctx,b.network(),addr.String())
		if err!=nil{
			if ctx.Err()!=nil{return nil,ctx.Err()}
			return nil,batchDialError(err)
		}
		tcp,ok:=raw.(*net.TCPConn)
		if !ok{raw.Close();return nil,errors.New("unexpected TCP connection type")}
		return authenticateBatchTCP(ctx,tcp,tx,id,false,authorize)
	},nil
}

// The future batch owner must bound admission BEFORE accepting/spawning
// handshake work and route only to an already approved transaction. This
// helper does not start a listener or grant a remote request access.
func acceptBatchTCP(ctx context.Context,b binding,raw *net.TCPConn,tx sharecore.Transaction,authorize batchAuthorization)(*tls.Conn,error){
	if raw==nil{return nil,errors.New("missing incoming lane")}
	if !b.allowsRemote(raw.RemoteAddr().(*net.TCPAddr).AddrPort().Addr()){
		raw.Close();return nil,errors.New("incoming lane source denied")
	}
	id,err:=authorizeBatch(ctx,tx,authorize)
	if err!=nil{raw.Close();return nil,err}
	return authenticateBatchTCP(ctx,raw,tx,id,true,authorize)
}
