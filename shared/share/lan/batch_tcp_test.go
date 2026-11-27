package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"io"
	"net"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"

	"pulse-extras/share-lan/sharecore"
)

func batchTestBinding(t *testing.T,ip string)binding{
	t.Helper()
	b,err:=bindLocalMode(ip,true)
	if err!=nil{t.Fatal(err)}
	if err:=b.setAllowedSource(ip);err!=nil{t.Fatal(err)}
	return b
}

func batchTestAuthorization(id identity,expected sharecore.Transaction,revoked *atomic.Bool)batchAuthorization{
	return func(ctx context.Context,tx sharecore.Transaction)(identity,error){
		if tx!=expected||revoked.Load(){return identity{},errors.New("local batch grant denied")}
		return id,ctx.Err()
	}
}

func TestAuthenticatedBatchReconnectThroughTCPForward(t *testing.T){
	ctx,cancel:=context.WithTimeout(context.Background(),20*time.Second);defer cancel()
	client,err:=newIdentity();if err!=nil{t.Fatal(err)}
	server,err:=newIdentity();if err!=nil{t.Fatal(err)}
	b:=batchTestBinding(t,"127.0.0.1")
	data:=[]byte("verified transfer across a transparent TCP forward")
	entry,err:=sharecore.InspectFile(ctx,"file.bin",uint64(len(data)),bytes.NewReader(data));if err!=nil{t.Fatal(err)}
	m:=sharecore.Manifest{Entries:[]sharecore.Entry{entry}}
	wire,err:=m.Encode();if err!=nil{t.Fatal(err)}
	tx:=sharecore.Transaction{Peer:server.pin,Manifest:sha256.Sum256(wire)}
	if _,err:=rand.Read(tx.ID[:]);err!=nil{t.Fatal(err)}
	remote:=tx;remote.Peer=client.pin
	rb,err:=sharecore.NewBudget(1);if err!=nil{t.Fatal(err)}
	sb,err:=sharecore.NewBudget(1);if err!=nil{t.Fatal(err)}
	stage,err:=sharecore.Create(t.TempDir(),tx,m,rb);if err!=nil{t.Fatal(err)}
	defer stage.Close()
	sender,err:=sharecore.NewSender(remote,m,sb,func(context.Context,uint32)(io.ReaderAt,io.Closer,error){
		return bytes.NewReader(data),io.NopCloser(bytes.NewReader(nil)),nil
	});if err!=nil{t.Fatal(err)}
	var revoked atomic.Bool
	var authCalls atomic.Int32
	auth:=batchTestAuthorization(client,tx,&revoked)
	clientAuth:=func(ctx context.Context,tx sharecore.Transaction)(identity,error){
		authCalls.Add(1);return auth(ctx,tx)
	}
	serverAuth:=batchTestAuthorization(server,remote,&revoked)
	listener,err:=net.ListenTCP("tcp4",&net.TCPAddr{IP:net.IPv4(127,0,0,1)})
	if err!=nil{t.Fatal(err)}
	defer listener.Close()
	forward,err:=net.ListenTCP("tcp4",&net.TCPAddr{IP:net.IPv4(127,0,0,1)})
	if err!=nil{t.Fatal(err)}
	defer forward.Close()
	stop:=context.AfterFunc(ctx,func(){listener.Close();forward.Close()});defer stop()
	serverDone:=make(chan error,1)
	go func(){
		for i:=0;i<2;i++{
			raw,err:=listener.AcceptTCP();if err!=nil{serverDone<-err;return}
			conn,err:=acceptBatchTCP(ctx,b,raw,remote,serverAuth)
			if err!=nil{serverDone<-err;return}
			if i==0{
				// Disconnect after an actual mutually authenticated handshake.
				raw.Close()
				continue
			}
			serverDone<-sender.ServeLane(ctx,conn)
		}
	}()
	forwardDone:=make(chan error,1)
	go func(){
		for i:=0;i<2;i++{
			in,err:=forward.AcceptTCP();if err!=nil{forwardDone<-err;return}
			out,err:=net.DialTCP("tcp4",nil,listener.Addr().(*net.TCPAddr))
			if err!=nil{in.Close();forwardDone<-err;return}
			stop:=context.AfterFunc(ctx,func(){in.Close();out.Close()})
			done:=make(chan struct{},1)
			go func(){_,_=io.Copy(out,in);out.CloseWrite();done<-struct{}{}}()
			_,_=io.Copy(in,out)
			in.Close();out.Close();<-done;stop()
		}
		forwardDone<-nil
	}()
	opener,err:=newBatchTCPOpener(b,forward.Addr().String(),clientAuth)
	if err!=nil{t.Fatal(err)}
	if err:=stage.TransferMissing(ctx,opener,sharecore.ScheduleOptions{Workers:1,Attempts:3});err!=nil{t.Fatal(err)}
	if err:=<-serverDone;err!=nil{t.Fatal(err)}
	if err:=<-forwardDone;err!=nil{t.Fatal(err)}
	if authCalls.Load()!=4{t.Fatalf("expected reauthorization per connection, got %d",authCalls.Load())}
	if missing,err:=stage.Missing();err!=nil||len(missing)!=0{t.Fatal("incomplete transfer")}
	revoked.Store(true)
	if c,err:=opener(ctx,tx);err==nil{c.Close();t.Fatal("revoked grant admitted")}
}

func TestBatchTCPSourceAndGrantAdmission(t *testing.T){
	ctx,cancel:=context.WithTimeout(context.Background(),5*time.Second);defer cancel()
	b:=batchTestBinding(t,"127.0.0.1")
	b.source=netip.MustParseAddr("127.0.0.2")
	l,err:=net.ListenTCP("tcp4",&net.TCPAddr{IP:net.IPv4(127,0,0,1)})
	if err!=nil{t.Fatal(err)}
	defer l.Close()
	stop:=context.AfterFunc(ctx,func(){l.Close()});defer stop()
	c,err:=net.DialTCP("tcp4",nil,l.Addr().(*net.TCPAddr));if err!=nil{t.Fatal(err)}
	defer c.Close()
	raw,err:=l.AcceptTCP();if err!=nil{t.Fatal(err)}
	var calls int
	auth:=func(context.Context,sharecore.Transaction)(identity,error){calls++;return identity{},errors.New("denied")}
	if conn,err:=acceptBatchTCP(ctx,b,raw,sharecore.Transaction{},auth);err==nil{conn.Close();t.Fatal("wrong TCP source accepted")}
	if calls!=0{t.Fatal("wrong source reached authorization")}
	if _,err:=newBatchTCPOpener(b,"example.org:443",auth);err==nil{t.Fatal("nonnumeric endpoint accepted")}
}

func TestBatchTCPIPv6PinnedLane(t *testing.T){
	l,err:=net.ListenTCP("tcp6",&net.TCPAddr{IP:net.IPv6loopback})
	if err!=nil{t.Skip("IPv6 loopback unavailable")}
	defer l.Close()
	ctx,cancel:=context.WithTimeout(context.Background(),5*time.Second);defer cancel()
	stop:=context.AfterFunc(ctx,func(){l.Close()});defer stop()
	b:=batchTestBinding(t,"::1")
	a,err:=newIdentity();if err!=nil{t.Fatal(err)}
	z,err:=newIdentity();if err!=nil{t.Fatal(err)}
	tx:=sharecore.Transaction{ID:sha256.Sum256([]byte("id")),Manifest:sha256.Sum256([]byte("manifest")),Peer:z.pin}
	remote:=tx;remote.Peer=a.pin
	var revoked atomic.Bool
	done:=make(chan error,1)
	go func(){
		raw,err:=l.AcceptTCP();if err!=nil{done<-err;return}
		c,err:=acceptBatchTCP(ctx,b,raw,remote,batchTestAuthorization(z,remote,&revoked))
		if err!=nil{done<-err;return}
		defer c.Close()
		done<-writeAll(c,[]byte{7})
	}()
	open,err:=newBatchTCPOpener(b,l.Addr().String(),batchTestAuthorization(a,tx,&revoked))
	if err!=nil{t.Fatal(err)}
	c,err:=open(ctx,tx);if err!=nil{t.Fatal(err)}
	defer c.Close()
	if err:=c.SetDeadline(time.Now().Add(3*time.Second));err!=nil{t.Fatal(err)}
	var got [1]byte
	if _,err:=io.ReadFull(c,got[:]);err!=nil||got[0]!=7{t.Fatalf("IPv6 data: %v",err)}
	if err:=<-done;err!=nil{t.Fatal(err)}
}
