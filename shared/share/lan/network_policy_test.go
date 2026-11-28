package main

import (
	"crypto/tls"
	"net"
	"net/netip"
	"testing"
	"time"
)

func TestExplicitRoutedPolicy(t *testing.T){
	b:=binding{ip:netip.MustParseAddr("192.168.1.20"),prefix:netip.MustParsePrefix("192.168.1.0/24"),iface:&net.Interface{Name:"test",Index:7}}
	for _,addr:=range []string{"100.64.0.5:45843","203.0.113.5:45843","10.2.0.5:45843"}{
		if _,err:=b.peer(addr);err==nil{t.Fatal("default LAN accepted routed address")}
	}
	if _,err:=b.peer("192.168.1.21:45843");err!=nil{t.Fatal(err)}
	if err:=b.setAllowedSource("100.64.0.5");err==nil{t.Fatal("source restriction accepted outside routed mode")}
	b.routed=true
	for _,addr:=range []string{"100.64.0.5:45843","203.0.113.5:45843","10.2.0.5:45843"}{
		if _,err:=b.peer(addr);err!=nil{t.Fatal(err)}
	}
	for _,addr:=range []string{"0.0.0.0:1","224.0.0.1:1","255.255.255.255:1","example.com:1","192.168.1.21:0","[2001:db8::1]:1"}{
		if _,err:=b.peer(addr);err==nil{t.Fatalf("invalid endpoint admitted: %s",addr)}
	}
	if b.allowsRemote(netip.MustParseAddr("100.64.0.5")){t.Fatal("source not selected")}
	if err:=b.setAllowedSource("100.64.0.5");err!=nil{t.Fatal(err)}
	if !b.allowsRemote(netip.MustParseAddr("100.64.0.5"))||b.allowsRemote(netip.MustParseAddr("100.64.0.6")){t.Fatal("exact source filter failed")}
	if _,_,err:=b.multicast();err==nil{t.Fatal("routed discovery enabled")}
	v6:=binding{ip:netip.MustParseAddr("fd00::1"),prefix:netip.MustParsePrefix("fd00::/64"),iface:&net.Interface{Index:7},routed:true}
	if _,err:=v6.peer("[2001:db8::2]:45843");err!=nil{t.Fatal(err)}
	if _,err:=v6.peer("[ff02::1]:45843");err==nil{t.Fatal("multicast peer")}
}

func TestHybridKeyExchangeRequired(t *testing.T){
	a,err:=newIdentity();if err!=nil{t.Fatal(err)}
	b,err:=newIdentity();if err!=nil{t.Fatal(err)}
	for _,classical:=range []bool{false,true}{
		l,err:=net.Listen("tcp4","127.0.0.1:0");if err!=nil{t.Fatal(err)}
		done:=make(chan error,1)
		go func(){
			defer l.Close()
			raw,err:=l.Accept();if err!=nil{done<-err;return}
			defer raw.Close()
			_ = raw.SetDeadline(time.Now().Add(5*time.Second))
			s:=tls.Server(raw,tlsConfig(b,a.pin,true))
			done<-s.Handshake()
		}()
		raw,err:=net.DialTimeout("tcp4",l.Addr().String(),5*time.Second)
		if err!=nil{l.Close();t.Fatal(err)}
		_ = raw.SetDeadline(time.Now().Add(5*time.Second))
		cfg:=tlsConfig(a,b.pin,false)
		if classical{cfg.CurvePreferences=[]tls.CurveID{tls.X25519}}
		c:=tls.Client(raw,cfg)
		err=c.Handshake()
		if !classical&&(err!=nil||c.ConnectionState().CurveID!=tls.X25519MLKEM768){raw.Close();t.Fatalf("hybrid negotiation failed: %v",err)}
		raw.Close()
		serverErr:=<-done
		if classical&&(err==nil||serverErr==nil){t.Fatal("classical-only downgrade accepted")}
		if !classical&&serverErr!=nil{t.Fatal(serverErr)}
	}
}


func TestPairDiscoveryAndOverlayPolicy(t *testing.T){
	a:=announcement(45843)
	p:=pairingAnnouncement(45844)
	if port,pairing,ok:=parseDiscovery(a[:]);!ok||pairing||port!=45843{t.Fatal("file advertisement")}
	if port,pairing,ok:=parseDiscovery(p[:]);!ok||!pairing||port!=45844{t.Fatal("pair advertisement")}
	if _,ok:=parseAnnouncement(p[:]);ok{t.Fatal("old parser confused pairing with file transfer")}
	invalid:=pairingAnnouncement(0)
	if _,_,ok:=parseDiscovery(invalid[:]);ok{t.Fatal("zero pairing port")}
	for _,s:=range []string{"192.168.1.1","100.64.0.1","fd7a:115c:a1e0::1"}{
		if !privatePairIP(netip.MustParseAddr(s)){t.Fatalf("private overlay rejected: %s",s)}
	}
	for _,s:=range []string{"8.8.8.8","2001:4860::1","0.0.0.0","ff02::1"}{
		if privatePairIP(netip.MustParseAddr(s)){t.Fatalf("public or invalid dynamic pairing address accepted: %s",s)}
	}
}
