package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
	"time"

	quic "github.com/quic-go/quic-go"
)

func TestQUICPacketAdmission(t *testing.T){
	p:=&admittedPackets{allow:func(a netip.Addr)bool{return a==netip.MustParseAddr("127.0.0.1")}}
	a:=net.UDPAddrFromAddrPort(netip.MustParseAddrPort("127.0.0.1:12345"))
	b:=net.UDPAddrFromAddrPort(netip.MustParseAddrPort("127.0.0.1:12346"))
	if !p.admitted(a)||!p.admitted(b){t.Fatal("initial permitted address denied")}
	if p.admitted(net.UDPAddrFromAddrPort(netip.MustParseAddrPort("127.0.0.2:12345"))){t.Fatal("wrong source admitted")}
	if err:=p.freeze(a);err!=nil{t.Fatal(err)}
	if p.admitted(b)||!p.admitted(a){t.Fatal("unexpected endpoint migration")}
}

func TestQUICFileProtocol(t *testing.T){
	ctx,cancel:=context.WithTimeout(context.Background(),20*time.Second);defer cancel()
	a,err:=newIdentity();if err!=nil{t.Fatal(err)}
	b,err:=newIdentity();if err!=nil{t.Fatal(err)}
	data:=bytes.Repeat([]byte("QUIC data"),65536)
	root:=t.TempDir()
	path:=filepath.Join(root,"source.bin")
	if err:=os.WriteFile(path,data,0600);err!=nil{t.Fatal(err)}
	f,err:=os.Open(path);if err!=nil{t.Fatal(err)};defer f.Close()
	l,err:=quic.ListenAddr("127.0.0.1:0",tlsConfigForProtocol(b,a.pin,true,quicFileALPN),fileQUICConfig(true));if err!=nil{t.Fatal(err)}
	defer l.Close()
	done:=make(chan error,1)
	go func(){
		c,err:=l.Accept(ctx);if err!=nil{done<-err;return};defer c.CloseWithError(0,"done")
		s,err:=c.AcceptStream(ctx);if err!=nil{done<-err;return}
		err=receiveFileProgress(s,root,func(o offer)(bool,error){return o.name=="received.bin",nil},
			func(o offer,p string)error{
				got,err:=os.ReadFile(p);if err!=nil{return err}
				if !bytes.Equal(got,data){return errors.New("wrong verified payload")}
				return nil
			},nil)
		if err==nil{err=finishQUICServer(ctx,c,s)}
		done<-err
	}()
	binding,err:=bindLocal("127.0.0.1");if err!=nil{t.Fatal(err)}
	addr:=l.Addr().(*net.UDPAddr).AddrPort()
	if err:=sendQUICFile(ctx,binding,addr,a,b.pin,f,offer{"received.bin",uint64(len(data)),sha256.Sum256(data)});err!=nil{t.Fatal(err)}
	select{case err:=<-done:if err!=nil{t.Fatal(err)};case <-ctx.Done():t.Fatal(ctx.Err())}
}
