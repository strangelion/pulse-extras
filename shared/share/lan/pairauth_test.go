package main

import (
	"context"
	"crypto/tls"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"pulse-extras/share-lan/internal/pairauth"
)

// Experimental pairing ALPN is distinct from file-transfer ALPN. This
// deliberately untrusted TLS config exists only in this test harness.
func candidateTLS(id identity,server bool)*tls.Config{
	c:=&tls.Config{Certificates:[]tls.Certificate{id.cert},MinVersion:tls.VersionTLS13,
		MaxVersion:tls.VersionTLS13,NextProtos:[]string{pairauth.Protocol},
		SessionTicketsDisabled:true,InsecureSkipVerify:!server,
		VerifyConnection:func(s tls.ConnectionState)error{
			if s.NegotiatedProtocol!=pairauth.Protocol||len(s.PeerCertificates)!=1{return errors.New("unexpected test pairing certificate")}
			now:=time.Now()
			if now.Before(s.PeerCertificates[0].NotBefore)||now.After(s.PeerCertificates[0].NotAfter){return errors.New("expired test identity")}
			return nil
		}}
	if server{c.ClientAuth=tls.RequireAnyClientCert}
	return c
}

func TestCandidatePAKEOverTLS(t *testing.T){
	helper:=os.Getenv("PULSE_SHARE_PAKE_TEST_HELPER")
	if helper==""{t.Skip("experimental Rust adapter not built")}
	helper,err:=filepath.Abs(helper)
	if err!=nil{t.Fatal(err)}
	for _,tc:=range []struct{name,code string;badBinding bool;want bool}{
		{"matching","12345678",false,true},
		{"wrong code","87654321",false,false},
		{"wrong certificate context","12345678",true,false},
	}{
		t.Run(tc.name,func(t *testing.T){
			a,err:=newIdentity();if err!=nil{t.Fatal(err)}
			b,err:=newIdentity();if err!=nil{t.Fatal(err)}
			l,err:=net.Listen("tcp4","127.0.0.1:0");if err!=nil{t.Fatal(err)}
			defer l.Close()
			l.(*net.TCPListener).SetDeadline(time.Now().Add(10*time.Second))
			ctx,cancel:=context.WithTimeout(context.Background(),20*time.Second)
			defer cancel()
			type result struct{pin [32]byte;err error}
			done:=make(chan result,1)
			go func(){
				raw,err:=l.Accept()
				if err!=nil{done<-result{err:err};return}
				defer raw.Close()
				_ = raw.SetDeadline(time.Now().Add(10*time.Second))
				conn:=tls.Server(raw,candidateTLS(b,true))
				if err:=conn.HandshakeContext(ctx);err!=nil{done<-result{err:err};return}
				pin,err:=pairauth.Confirm(ctx,conn,b.pin,[]byte("12345678"),true,helper)
				done<-result{pin,err}
			}()
			raw,err:=net.DialTimeout("tcp4",l.Addr().String(),5*time.Second);if err!=nil{t.Fatal(err)}
			defer raw.Close()
			_ = raw.SetDeadline(time.Now().Add(10*time.Second))
			conn:=tls.Client(raw,candidateTLS(a,false))
			if err:=conn.HandshakeContext(ctx);err!=nil{t.Fatal(err)}
			pin:=a.pin
			if tc.badBinding{pin[0]^=1}
			got,clientErr:=pairauth.Confirm(ctx,conn,pin,[]byte(tc.code),false,helper)
			r:=<-done
			if tc.want{
				if clientErr!=nil||r.err!=nil||got!=b.pin||r.pin!=a.pin{t.Fatalf("client=%v server=%v",clientErr,r.err)}
			}else if clientErr==nil||r.err==nil{t.Fatalf("unexpected authentication: client=%v server=%v",clientErr,r.err)}
		})
	}
}
