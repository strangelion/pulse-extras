package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"io"
	"net"
	"testing"
	"time"

	"pulse-extras/share-lan/sharecore"
)

// Real TLS and actual peer pins, but not a production batch listener.
// Control-plane admission and native directory publication remain separate.
func TestBatchLaneOverPinnedTLS(t *testing.T){
	ctx,cancel:=context.WithTimeout(context.Background(),10*time.Second);defer cancel()
	a,err:=newIdentity();if err!=nil{t.Fatal(err)}
	b,err:=newIdentity();if err!=nil{t.Fatal(err)}
	data:=[]byte("batch content")
	entry,err:=sharecore.InspectFile(ctx,"sample.bin",uint64(len(data)),bytes.NewReader(data));if err!=nil{t.Fatal(err)}
	m:=sharecore.Manifest{Entries:[]sharecore.Entry{entry}}
	wire,err:=m.Encode();if err!=nil{t.Fatal(err)}
	tx:=sharecore.Transaction{Peer:a.pin,Manifest:sha256.Sum256(wire)}
	if _,err:=rand.Read(tx.ID[:]);err!=nil{t.Fatal(err)}
	sb,err:=sharecore.NewBudget(1);if err!=nil{t.Fatal(err)}
	rb,err:=sharecore.NewBudget(1);if err!=nil{t.Fatal(err)}
	remote:=tx;remote.Peer=b.pin
	sender,err:=sharecore.NewSender(remote,m,sb,func(context.Context,uint32)(io.ReaderAt,io.Closer,error){
		return bytes.NewReader(data),io.NopCloser(bytes.NewReader(nil)),nil
	});if err!=nil{t.Fatal(err)}
	stage,err:=sharecore.Create(t.TempDir(),tx,m,rb);if err!=nil{t.Fatal(err)}
	l,err:=net.Listen("tcp4","127.0.0.1:0");if err!=nil{t.Fatal(err)}
	defer l.Close()
	stop:=context.AfterFunc(ctx,func(){l.Close()});defer stop()
	done:=make(chan error,1)
	go func(){
		raw,err:=l.Accept();if err!=nil{done<-err;return}
		defer raw.Close()
		c:=tls.Server(raw,tlsConfigForProtocol(a,b.pin,true,sharecore.LaneProtocol))
		if err:=c.HandshakeContext(ctx);err!=nil{done<-err;return}
		done<-sender.ServeLane(ctx,c)
	}()
	raw,err:=(&net.Dialer{}).DialContext(ctx,"tcp4",l.Addr().String());if err!=nil{t.Fatal(err)}
	defer raw.Close()
	c:=tls.Client(raw,tlsConfigForProtocol(b,a.pin,false,sharecore.LaneProtocol))
	if err:=c.HandshakeContext(ctx);err!=nil{t.Fatal(err)}
	if c.ConnectionState().CurveID!=tls.X25519MLKEM768{t.Fatal("hybrid group not negotiated")}
	if err:=stage.ReceiveLane(ctx,c,[]sharecore.Block{{File:0,Index:0}});err!=nil{t.Fatal(err)}
	if err:=<-done;err!=nil{t.Fatal(err)}
	missing,err:=stage.Missing();if err!=nil||len(missing)!=0{t.Fatal("verified block missing")}
}
