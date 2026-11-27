// Package pairauth is an experimental local adapter integration. It is not
// used by the shipping file-transfer commands or the Pulse host panel.
package pairauth

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"errors"
	"io"
	"os/exec"
	"path/filepath"
	"time"
)

const Protocol = "pulse-share-pair-cpace06/1"
const ExportLabel = "EXPORTER-Pulse-Share-Pairing-CPace06-v1"

// Confirm binds PAKE to the exact TLS connection and both presented
// certificate identities. The caller must first complete a TLS 1.3 handshake
// with proof of possession on both sides. It must not treat the initially
// untrusted TLS connection as authenticated before this returns successfully.
//
// The path must be an explicitly approved, immutable local helper path.
// This experimental adapter is not yet part of the native digest-pin chain.
func Confirm(ctx context.Context, conn *tls.Conn, localPin [32]byte, password []byte, server bool, helper string) ([32]byte,error) {
	var none [32]byte
	if len(password)!=8 || !filepath.IsAbs(helper) {return none,errors.New("invalid local pairing configuration")}
	for _,b:=range password {if b<'0'||b>'9'{return none,errors.New("invalid code format")}}
	state:=conn.ConnectionState()
	if !state.HandshakeComplete || state.Version!=tls.VersionTLS13 || state.NegotiatedProtocol!=Protocol || len(state.PeerCertificates)!=1 {
		return none,errors.New("unexpected pairing transport")
	}
	peer:=sha256.Sum256(state.PeerCertificates[0].Raw)
	if peer==localPin {return none,errors.New("self pairing")}
	exporter,err:=state.ExportKeyingMaterial(ExportLabel,nil,32)
	if err!=nil{return none,err}
	defer clear(exporter)
	a,b:=localPin,peer
	role:=byte(0)
	if server {a,b=peer,localPin;role=1}
	ctx,cancel:=context.WithTimeout(ctx,10*time.Second)
	defer cancel()
	deadline,_:=ctx.Deadline()
	if err:=conn.SetDeadline(deadline);err!=nil{return none,err}
	stop:=context.AfterFunc(ctx,func(){conn.Close()})
	defer stop()
	cmd:=exec.CommandContext(ctx,helper)
	// No code on argv, in the environment or stderr.
	cmd.Stderr=io.Discard
	in,err:=cmd.StdinPipe()
	if err!=nil{return none,err}
	out,err:=cmd.StdoutPipe()
	if err!=nil{in.Close();return none,err}
	if err:=cmd.Start();err!=nil{in.Close();out.Close();return none,err}
	waited:=false
	defer func(){
		in.Close()
		out.Close()
		if !waited {cancel();_ = cmd.Wait()}
	}()
	header:=make([]byte,109)
	copy(header,"PSP1")
	header[4]=role
	copy(header[5:13],password)
	copy(header[13:45],a[:])
	copy(header[45:77],b[:])
	copy(header[77:],exporter)
	err=write(in,header)
	clear(header)
	if err!=nil{return none,err}

	// A 48-byte initiator message, 32-byte responder message, then
	// two 64-byte confirmation tags. Forward only these exact sizes.
	var msg [64]byte
	forward:=func(from io.Reader,to io.Writer,n int)error{
		if _,err:=io.ReadFull(from,msg[:n]);err!=nil{return err}
		return write(to,msg[:n])
	}
	if !server {
		if err:=forward(out,conn,48);err!=nil{return none,err}
		if err:=forward(conn,in,32);err!=nil{return none,err}
		if err:=forward(out,conn,64);err!=nil{return none,err}
		if err:=forward(conn,in,64);err!=nil{return none,err}
	} else {
		if err:=forward(conn,in,48);err!=nil{return none,err}
		if err:=forward(out,conn,32);err!=nil{return none,err}
		if err:=forward(conn,in,64);err!=nil{return none,err}
		if err:=forward(out,conn,64);err!=nil{return none,err}
	}
	var result [1]byte
	if _,err:=io.ReadFull(out,result[:]);err!=nil||result[0]!=1{return none,errors.New("pair authentication failed")}
	in.Close()
	// Reject unexpected output. The helper must finish cleanly.
	if n,err:=out.Read(result[:]);n!=0||err!=io.EOF{return none,errors.New("unexpected adapter output")}
	err=cmd.Wait()
	waited=true
	if err!=nil||ctx.Err()!=nil{return none,errors.New("pair authentication failed")}
	return peer,nil
}

func write(w io.Writer,b []byte)error{
	for len(b)>0{
		n,err:=w.Write(b)
		if err!=nil{return err}
		if n<=0||n>len(b){return io.ErrShortWrite}
		b=b[n:]
	}
	return nil
}
