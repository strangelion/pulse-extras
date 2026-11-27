//go:build linux

package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"pulse-extras/share-lan/sharecore"
)

// Test-only process entry point. Ordinary go test never runs these cases.
// The acceptance driver creates a fresh private, synthetic fixture and
// launches this test binary in isolated Linux network namespaces.
func acceptanceIdentity(t *testing.T,root,name string) identity{
	t.Helper()
	c,err:=tls.LoadX509KeyPair(filepath.Join(root,name+".pem"),filepath.Join(root,name+".key"))
	if err!=nil{t.Fatal(err)}
	return identity{c,sha256.Sum256(c.Certificate[0])}
}
func acceptancePrepare(t *testing.T,root string){
	t.Helper()
	info,err:=os.Lstat(root);if err!=nil||!info.IsDir()||info.Mode()&os.ModeSymlink!=0{t.Fatal("expected fresh private fixture directory")}
	entries,err:=os.ReadDir(root);if err!=nil||len(entries)!=0{t.Fatal("fixture directory must be empty")}
	for _,name:=range []string{"a","b"}{
		id,err:=newIdentity();if err!=nil{t.Fatal(err)}
		key,err:=x509.MarshalPKCS8PrivateKey(id.cert.PrivateKey);if err!=nil{t.Fatal(err)}
		if err=createStoreFile(filepath.Join(root,name+".key"),pem.EncodeToMemory(&pem.Block{Type:"PRIVATE KEY",Bytes:key}));err!=nil{t.Fatal(err)}
		clear(key)
		if err=createStoreFile(filepath.Join(root,name+".pem"),pem.EncodeToMemory(&pem.Block{Type:"CERTIFICATE",Bytes:id.cert.Certificate[0]}));err!=nil{t.Fatal(err)}
	}
	for _,n:=range []int64{8*1024*1024+123,128*1024*1024+123}{
		path:=filepath.Join(root,fmt.Sprintf("fixture-%d.bin",n))
		f,err:=os.OpenFile(path,os.O_WRONLY|os.O_CREATE|os.O_EXCL,0600);if err!=nil{t.Fatal(err)}
		h:=sha256.New()
		_,err=io.CopyN(io.MultiWriter(f,h),rand.Reader,n)
		err=errors.Join(err,f.Close());if err!=nil{t.Fatal(err)}
		if err=createStoreFile(path+".sha256",[]byte(hex.EncodeToString(h.Sum(nil))));err!=nil{t.Fatal(err)}
	}
}
type countedAcceptanceLane struct{
	sharecore.LaneStream
	once sync.Once
	active *atomic.Int32
}
func(s *countedAcceptanceLane)Close()error{
	var e error
	s.once.Do(func(){e=s.LaneStream.Close();s.active.Add(-1)})
	return e
}
func TestNetworkAcceptanceProcess(t *testing.T){
	role:=os.Getenv("PULSE_ACCEPTANCE_ROLE")
	if role==""{t.Skip("dedicated isolated network acceptance only")}
	root:=os.Getenv("PULSE_ACCEPTANCE_ROOT")
	if !filepath.IsAbs(root){t.Fatal("missing private test fixture")}
	if role=="prepare"{acceptancePrepare(t,root);return}
	if role!="send"&&role!="receive"{t.Fatal("invalid test role")}
	n,err:=strconv.ParseInt(os.Getenv("PULSE_ACCEPTANCE_BYTES"),10,64)
	if err!=nil||(n!=8*1024*1024+123&&n!=128*1024*1024+123){t.Fatal("invalid fixture size")}
	workers,err:=strconv.Atoi(os.Getenv("PULSE_ACCEPTANCE_CHANNELS"));if err!=nil||workers<1||workers>32{t.Fatal("invalid workers")}
	port,err:=strconv.ParseUint(os.Getenv("PULSE_ACCEPTANCE_PORT"),10,16);if err!=nil||port==0{t.Fatal("invalid port")}
	ctx,cancel:=context.WithTimeout(context.Background(),150*time.Second);defer cancel()
	b,err:=bindLocalMode(os.Getenv("PULSE_ACCEPTANCE_BIND"),true);if err!=nil{t.Fatal(err)}
	aID,bID:=acceptanceIdentity(t,root,"a"),acceptanceIdentity(t,root,"b")
	q:=os.Getenv("PULSE_ACCEPTANCE_QUIC")=="1"
	check:=func(ctx context.Context)error{return ctx.Err()}
	path:=filepath.Join(root,fmt.Sprintf("fixture-%d.bin",n))
	expected,err:=os.ReadFile(path+".sha256");if err!=nil{t.Fatal(err)}
	spool:=os.Getenv("PULSE_ACCEPTANCE_SPOOL")
	before,_:=os.ReadDir("/proc/self/fd")
	start:=time.Now()
	var active,peak,opened atomic.Int32
	if role=="send"{
		peer,err:=b.peer(os.Getenv("PULSE_ACCEPTANCE_PEER"));if err!=nil{t.Fatal(err)}
		snap,err:=sharecore.ScanSelection(ctx,path);if err!=nil{t.Fatal(err)}
		link,err:=openBatchSender(ctx,b,peer,aID,bID.pin,q);if err!=nil{t.Fatal(err)}
		defer link.close()
		err=batchSend(ctx,link,batchSource{snap.Manifest,snap.OpenSource},sharecore.Files,bID.pin,workers,check)
		link.close()
		if err!=nil{t.Fatal(err)}
	}else{
		if err=b.setAllowedSource(os.Getenv("PULSE_ACCEPTANCE_SOURCE"));err!=nil{t.Fatal(err)}
		link,err:=openBatchReceiver(ctx,b,uint16(port),bID,aID.pin,q,func(s string){fmt.Println("ACCEPTANCE_READY",s)})
		if err!=nil{t.Fatal(err)}
		defer link.close()
		old:=link.lane
		link.lane=func(ctx context.Context)(sharecore.LaneStream,error){
			l,err:=old(ctx);if err!=nil{return nil,err}
			opened.Add(1);v:=active.Add(1)
			for p:=peak.Load();v>p&&!peak.CompareAndSwap(p,v);p=peak.Load(){}
			return &countedAcceptanceLane{LaneStream:l,active:&active},nil
		}
		err=batchReceive(ctx,link,batchReceiveOptions{spool:spool,resume:os.Getenv("PULSE_ACCEPTANCE_RESUME"),channels:workers},aID.pin,check,
			func(m sharecore.Manifest,k sharecore.ContentKind)(bool,error){
				return k==sharecore.Files&&len(m.Entries)==1&&m.Entries[0].Size==uint64(n)&&hex.EncodeToString(m.Entries[0].Hash[:])==string(expected),nil
			},
			func(ctx context.Context,stage *sharecore.Stage,m sharecore.Manifest,k sharecore.ContentKind)error{
				return stage.Seal(ctx,func(_ context.Context,e sharecore.Entry,p string)error{
					f,err:=os.Open(p);if err!=nil{return err};defer f.Close()
					h:=sha256.New();got,err:=io.Copy(h,f)
					if err!=nil||got!=n||hex.EncodeToString(h.Sum(nil))!=string(expected){return errors.New("independent payload verification failed")}
					return nil
				})
			})
		link.close()
		if err!=nil{t.Fatal(err)}
		if active.Load()!=0||peak.Load()>int32(workers)||opened.Load()<1{t.Fatal("lane accounting invalid",active.Load(),peak.Load(),opened.Load())}
	}
	runtime.GC()
	after,_:=os.ReadDir("/proc/self/fd")
	if len(after)>len(before)+4{t.Fatalf("unexpected retained file descriptors: %d -> %d",len(before),len(after))}
	fmt.Printf("ACCEPTANCE_METRIC role=%s bytes=%d elapsed_ms=%d opened=%d peak_lanes=%d fd_before=%d fd_after=%d\n",role,n,time.Since(start).Milliseconds(),opened.Load(),peak.Load(),len(before),len(after))
}
