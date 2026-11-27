package main

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestDynamicPairEnrollment(t *testing.T){
	helper:=os.Getenv("PULSE_SHARE_PAKE_TEST_HELPER")
	if helper==""{t.Skip("experimental Rust adapter not built")}
	helper,err:=filepath.Abs(helper)
	if err!=nil{t.Fatal(err)}
	b,err:=bindLocal("127.0.0.1")
	if err!=nil{t.Fatal(err)}
	for _,tc:=range []struct{name string; clientApprove,serverApprove,conflict bool}{
		{"both approve",true,true,false},
		{"client declines",false,true,false},
		{"server declines",true,false,false},
		{"exclusive write conflict",true,true,true},
	}{
		t.Run(tc.name,func(t *testing.T){
			client,err:=newIdentity();if err!=nil{t.Fatal(err)}
			server,err:=newIdentity();if err!=nil{t.Fatal(err)}
			cr,sr:=t.TempDir(),t.TempDir()
			ctx,cancel:=context.WithTimeout(context.Background(),20*time.Second)
			defer cancel()
			type shown struct{ endpoint netip.AddrPort;code string }
			display:=make(chan shown,1)
			type final struct{result pairResult;err error}
			done:=make(chan final,1)
			serverConfig:=pairConfig{id:server,root:sr,label:"client",helper:helper,
				consent:func(_ context.Context,pin [32]byte)(bool,error){
					if pin!=client.pin{return false,errors.New("wrong authenticated client")}
					return tc.serverApprove,nil
				}}
			clientConfig:=pairConfig{id:client,root:cr,label:"server",helper:helper,
				consent:func(_ context.Context,pin [32]byte)(bool,error){
					if pin!=server.pin{return false,errors.New("wrong authenticated server")}
					if tc.conflict{
						// Simulate a local change after initial preflight.
						if err:=addPeer(cr,"server",client.pin);err!=nil{return false,err}
					}
					return tc.clientApprove,nil
				}}
			go func(){
				r,e:=hostPair(ctx,b,0,serverConfig,func(addr netip.AddrPort,code string,validFor time.Duration){
					if code!=""&&validFor>=3*time.Second{select{case display<-shown{addr,code}:default:}}
				})
				done<-final{r,e}
			}()
			var s shown
			select{
			case s=<-display:
			case r:=<-done:t.Fatalf("host did not open: %v",r.err)
			case <-ctx.Done():t.Fatal("private code not shown")
			}
			secret:=[]byte(s.code)
			r,e:=joinPair(ctx,b,s.endpoint.String(),clientConfig,secret)
			clear(secret)
			var other final
			select{case other=<-done:case <-ctx.Done():t.Fatal("host did not finish")}
			if tc.conflict{
				if !errors.Is(e,errPairUncertain)||!errors.Is(other.err,errPairUncertain)||r.localSaved||!other.result.localSaved{
					t.Fatalf("incorrect partial enrollment results: client %v server %v",e,other.err)
				}
				pin,err:=loadPeer(cr,"server")
				if err!=nil||pin!=client.pin{t.Fatal("existing local record overwritten")}
				return
			}
			if tc.clientApprove&&tc.serverApprove{
				if e!=nil||other.err!=nil||!r.localSaved||!other.result.localSaved||!r.peerReportedSaved||!other.result.peerReportedSaved{
					t.Fatalf("enrollment failed: client %v server %v",e,other.err)
				}
				a,ae:=loadPeer(cr,"server");z,ze:=loadPeer(sr,"client")
				if ae!=nil||ze!=nil||a!=server.pin||z!=client.pin{t.Fatal("stored wrong certificate")}
				// Existing explicit revoke remains usable for newly paired peers.
				if err:=revokePeer(cr,"server");err!=nil{t.Fatal(err)}
				if _,err:=loadPeer(cr,"server");!os.IsNotExist(err){t.Fatal("revoked peer still loaded")}
			}else{
				if !errors.Is(e,errPairDeclined)||!errors.Is(other.err,errPairDeclined){t.Fatalf("decline: client %v server %v",e,other.err)}
				if r.localWriteAttempted||other.result.localWriteAttempted{t.Fatal("write attempted without bilateral consent")}
				if _,err:=loadPeer(cr,"server");!os.IsNotExist(err){t.Fatal("client trust written on decline")}
				if _,err:=loadPeer(sr,"client");!os.IsNotExist(err){t.Fatal("server trust written on decline")}
			}
		})
	}
}

func TestPairStatusRejectsMalformedByte(t *testing.T){
	a,b:=net.Pipe()
	defer a.Close()
	defer b.Close()
	go func(){_ = writeAll(a,[]byte{2})}()
	var status [1]byte
	if err:=readStatusByte(b,&status);err==nil{t.Fatal("invalid decision accepted")}
}


func TestDynamicPairAttemptLimit(t *testing.T){
	helper:=os.Getenv("PULSE_SHARE_PAKE_TEST_HELPER")
	if helper==""{t.Skip("experimental Rust adapter not built")}
	helper,err:=filepath.Abs(helper);if err!=nil{t.Fatal(err)}
	b,err:=bindLocal("127.0.0.1");if err!=nil{t.Fatal(err)}
	client,err:=newIdentity();if err!=nil{t.Fatal(err)}
	server,err:=newIdentity();if err!=nil{t.Fatal(err)}
	cr,sr:=t.TempDir(),t.TempDir()
	ctx,cancel:=context.WithTimeout(context.Background(),20*time.Second);defer cancel()
	type shown struct{endpoint netip.AddrPort;code string}
	display:=make(chan shown,1)
	done:=make(chan error,1)
	noConsent:=func(context.Context,[32]byte)(bool,error){
		t.Error("incorrect code reached enrollment")
		return false,nil
	}
	go func(){
		_,err:=hostPair(ctx,b,0,pairConfig{id:server,root:sr,label:"client",helper:helper,consent:noConsent},
			func(addr netip.AddrPort,code string,validFor time.Duration){
				if code!=""&&validFor>=10*time.Second{select{case display<-shown{addr,code}:default:}}
			})
		done<-err
	}()
	// If we started near rotation, the 10s margin can take almost 10s to
	// obtain. The context bounds the whole test.
	var s shown
	select{
	case s=<-display:
	case err:=<-done:t.Fatalf("host failed to start: %v",err)
	case <-ctx.Done():t.Fatal("private code not shown")
	}
	wrong:=[]byte(s.code)
	wrong[0]='0'+(wrong[0]-'0'+1)%10
	defer clear(wrong)
	p:=pairConfig{id:client,root:cr,label:"server",helper:helper,consent:noConsent}
	for i:=0;i<5;i++{
		r,err:=joinPair(ctx,b,s.endpoint.String(),p,wrong)
		if err==nil||r.localWriteAttempted{t.Fatal("wrong code accepted")}
	}
	select{
	case err:=<-done:
		if err==nil{t.Fatal("exhausted pairing window succeeded")}
	case <-ctx.Done():t.Fatal("host did not close after five attempts")
	}
	if _,err:=loadPeer(cr,"server");!os.IsNotExist(err){t.Fatal("unexpected client trust")}
	if _,err:=loadPeer(sr,"client");!os.IsNotExist(err){t.Fatal("unexpected server trust")}
}

func TestPairCancellationClearsDisplay(t *testing.T){
	b,err:=bindLocal("127.0.0.1");if err!=nil{t.Fatal(err)}
	id,err:=newIdentity();if err!=nil{t.Fatal(err)}
	// No connection occurs and the adapter is never started.
	helper,err:=filepath.Abs("unused-pake-helper");if err!=nil{t.Fatal(err)}
	ctx,cancel:=context.WithCancel(context.Background());defer cancel()
	shown,cleared:=false,false
	_,err=hostPair(ctx,b,0,pairConfig{id:id,root:t.TempDir(),label:"peer",helper:helper,
		consent:func(context.Context,[32]byte)(bool,error){t.Error("unexpected consent");return false,nil}},
		func(_ netip.AddrPort,code string,_ time.Duration){
			if code!=""{shown=true;cancel()}else{cleared=true}
		})
	if err==nil||!shown||!cleared{t.Fatal("cancelled pairing window did not clear display")}
}
