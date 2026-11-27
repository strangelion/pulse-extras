package main

import (
	"bytes"
	"crypto/sha256"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestOffer(t *testing.T){
	for _,name:=range []string{"", "..", "../x", "a:b", "CON.txt", "COM¹", "x. ", "x\u202eexe", "NUL", "a\\b"}{
		if validName(name){t.Fatalf("admitted %q",name)}
	}
	o:=offer{"示例.bin",12,sha256.Sum256([]byte("data"))}
	var b bytes.Buffer
	if err:=writeOffer(&b,o);err!=nil{t.Fatal(err)}
	got,err:=readOffer(&b)
	if err!=nil || got!=o{t.Fatalf("%+v %v",got,err)}
	if _,err:=readOffer(bytes.NewReader([]byte("short")));err==nil{t.Fatal("truncated offer accepted")}
	b.Reset()
	o.size=maxFile+1
	if err:=writeOffer(&b,o);err==nil{t.Fatal("oversized offer accepted")}
}

func TestDiscovery(t *testing.T){
	a:=announcement(12345)
	if p,ok:=parseAnnouncement(a[:]);!ok || p!=12345{t.Fatal("bad roundtrip")}
	for _,b:=range [][]byte{nil, a[:7], append(a[:],0), []byte("PSLAN1\x00\x00"), []byte("BAD!!!\x00\x01")}{
		if _,ok:=parseAnnouncement(b);ok{t.Fatal("invalid announcement accepted")}
	}
}

func testTLS(t *testing.T,network,address string,badPin bool,operation func(net.Conn,net.Conn)){
	t.Helper()
	listener,err:=net.Listen(network,address)
	if err!=nil{
		if network=="tcp6"{t.Skipf("IPv6 loopback unavailable: %v",err)}
		t.Fatal(err)
	}
	defer listener.Close()
	a,err:=newIdentity()
	if err!=nil{t.Fatal(err)}
	b,err:=newIdentity()
	if err!=nil{t.Fatal(err)}
	serverPin:=a.pin
	if badPin{serverPin=[32]byte{}}
	type result struct{c net.Conn;err error}
	server:=make(chan result,1)
	go func(){
		raw,err:=listener.Accept()
		if err!=nil{server<-result{nil,err};return}
		_ = raw.SetDeadline(time.Now().Add(5*time.Second))
		c:=tls.Server(raw,tlsConfig(b,serverPin,true))
		err=c.Handshake()
		server<-result{c,err}
	}()
	raw,err:=net.DialTimeout(network,listener.Addr().String(),5*time.Second)
	if err!=nil{t.Fatal(err)}
	defer raw.Close()
	_ = raw.SetDeadline(time.Now().Add(5*time.Second))
	client:=tls.Client(raw,tlsConfig(a,b.pin,false))
	err=client.Handshake()
	got:=<-server
	if got.c!=nil{defer got.c.Close()}
	if badPin {
		if got.err==nil{t.Fatal("wrong client pin accepted")}
		return
	}
	if err!=nil || got.err!=nil{t.Fatalf("client %v server %v",err,got.err)}
	operation(client,got.c)
}

func TestMutualTLSAndTransfer(t *testing.T){
	for _,v:=range []struct{network,addr string}{{"tcp4","127.0.0.1:0"},{"tcp6","[::1]:0"}}{
		t.Run(v.network,func(t *testing.T){
			testTLS(t,v.network,v.addr,false,func(client,server net.Conn){
				root:=t.TempDir()
				data:=bytes.Repeat([]byte("test data"),70000)
				source:=filepath.Join(root,"source.bin")
				if err:=os.WriteFile(source,data,0600);err!=nil{t.Fatal(err)}
				f,err:=os.Open(source)
				if err!=nil{t.Fatal(err)}
				defer f.Close()
				size,digest,err:=digestFile(f)
				if err!=nil{t.Fatal(err)}
				done:=make(chan error,1)
				go func(){
					done<-receiveFile(server,root,func(o offer)(bool,error){return o.name=="目标.bin",nil},
						func(o offer,path string)error{
							got,err:=os.ReadFile(path)
							if err!=nil{return err}
							if !bytes.Equal(got,data){return errors.New("bad payload")}
							return os.WriteFile(filepath.Join(root,o.name),got,0600)
						})
				}()
				if err:=sendFile(client,f,offer{"目标.bin",size,digest});err!=nil{t.Fatal(err)}
				if err:=<-done;err!=nil{t.Fatal(err)}
				entries,err:=os.ReadDir(root)
				if err!=nil || len(entries)!=2{t.Fatalf("spool not cleaned: %v %v",entries,err)}
			})
		})
	}
}

func TestWrongPin(t *testing.T){
	testTLS(t,"tcp4","127.0.0.1:0",true,func(net.Conn,net.Conn){t.Fatal("unexpected pairing")})
}

func TestDeclineAndCorruptPayload(t *testing.T){
	for _,decline:=range []bool{true,false}{
		t.Run(map[bool]string{true:"declined",false:"corrupt"}[decline],func(t *testing.T){
			client,server:=net.Pipe()
			defer client.Close()
			defer server.Close()
			_ = client.SetDeadline(time.Now().Add(5*time.Second))
			root:=t.TempDir()
			done:=make(chan error,1)
			committed:=false
			go func(){
				done<-receiveFile(server,root,func(offer)(bool,error){return !decline,nil},func(offer,string)error{
					committed=true
					return nil
				})
			}()
			o:=offer{"data.bin",3,sha256.Sum256([]byte("abc"))}
			if err:=writeOffer(client,o);err!=nil{t.Fatal(err)}
			if decline{
				if err:=readStatus(client,0);err!=nil{t.Fatal(err)}
			}else{
				if err:=readStatus(client,1);err!=nil{t.Fatal(err)}
				if _,err:=io.WriteString(client,"bad");err!=nil{t.Fatal(err)}
			}
			if err:=<-done;err==nil{t.Fatal("invalid transfer succeeded")}
			if committed{t.Fatal("invalid transfer committed")}
			entries,err:=os.ReadDir(root)
			if err!=nil || len(entries)!=0{t.Fatalf("spool leaked: %v %v",entries,err)}
		})
	}
}
