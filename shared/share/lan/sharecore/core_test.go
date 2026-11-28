package sharecore

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func fixture(t *testing.T)(Manifest,[]byte,Transaction){
	t.Helper()
	data:=bytes.Repeat([]byte("verified!"),BlockSize/9+32)
	entry,err:=InspectFile(context.Background(),"tree/file.bin",uint64(len(data)),bytes.NewReader(data))
	if err!=nil{t.Fatal(err)}
	m:=Manifest{Entries:[]Entry{{Path:"tree",Directory:true},{Path:"tree/empty",Directory:true},entry,{Path:"zero",Hash:sha256.Sum256(nil)}}}
	wire,err:=m.Encode();if err!=nil{t.Fatal(err)}
	tx:=Transaction{ID:sha256.Sum256([]byte("transaction")),Peer:sha256.Sum256([]byte("peer")),Manifest:sha256.Sum256(wire)}
	return m,data,tx
}
func budget(t *testing.T,n int)*Budget{
	t.Helper();b,err:=NewBudget(n);if err!=nil{t.Fatal(err)};return b
}
func TestManifestCanonicalAndLimits(t *testing.T){
	m,_,_:=fixture(t)
	wire,err:=m.Encode();if err!=nil{t.Fatal(err)}
	got,err:=Decode(wire);if err!=nil{t.Fatal(err)}
	again,err:=got.Encode();if err!=nil||!bytes.Equal(wire,again){t.Fatal("noncanonical")}
	for _,path:=range []string{"../file","/absolute","C:/a","a//b","NUL.txt","x.","x ","x:stream","A~1"}{
		if (Manifest{Entries:[]Entry{{Path:path,Directory:true}}}).Validate()==nil{t.Fatalf("accepted invalid path %q",path)}
	}
	for _,entries:=range [][]Entry{
		{{Path:"foo",Directory:true},{Path:"FOO",Directory:true}},
		{{Path:"absent/child",Directory:true}},
		{{Path:"foo",Hash:sha256.Sum256(nil)},{Path:"foo/child",Directory:true}},
		{{Path:"big",Size:MaxBytes+1}},
	}{
		if (Manifest{Entries:entries}).Validate()==nil{t.Fatal("invalid manifest accepted")}
	}
	if _,err:=Decode(append(wire,0));err==nil{t.Fatal("trailing bytes accepted")}
	if _,err:=Decode(wire[:len(wire)-1]);err==nil{t.Fatal("truncated manifest accepted")}
}

func TestResumeRechecksCorruptBlocksAndPublication(t *testing.T){
	ctx:=context.Background()
	m,data,tx:=fixture(t)
	b:=budget(t,2)
	s,err:=Create(t.TempDir(),tx,m,b);if err!=nil{t.Fatal(err)}
	first:=Block{2,0};second:=Block{2,1}
	if err:=s.Seal(ctx,func(context.Context,Entry,string)error{return nil});!errors.Is(err,ErrIncomplete){t.Fatal("incomplete published")}
	if err:=s.Receive(ctx,first,bytes.NewReader(data[:BlockSize]));err!=nil{t.Fatal(err)}
	if err:=s.Receive(ctx,first,bytes.NewReader(data[:BlockSize]));!errors.Is(err,ErrBusy){t.Fatal("duplicate accepted")}
	if err:=s.Receive(ctx,second,bytes.NewReader(make([]byte,len(data)-BlockSize)));!errors.Is(err,ErrCorrupt){t.Fatal("bad block accepted")}
	if err:=s.Close();err!=nil{t.Fatal(err)}
	file,err:=os.OpenFile(s.file(2),os.O_WRONLY,0);if err!=nil{t.Fatal(err)}
	if _,err=file.WriteAt([]byte{0},0);err!=nil{t.Fatal(err)}
	file.Close()
	badTx:=tx;badTx.Peer[0]^=1
	if _,err:=Reopen(ctx,s.Path(),badTx,m,b);err==nil{t.Fatal("wrong peer resumed")}
	s,err=Reopen(ctx,s.Path(),tx,m,b);if err!=nil{t.Fatal(err)}
	missing,err:=s.Missing();if err!=nil||len(missing)!=2{t.Fatalf("corruption not invalidated: %v %v",missing,err)}
	for _,block:=range missing{
		start,n,_,_:=m.blockInfo(block)
		if err:=s.Receive(ctx,block,bytes.NewReader(data[start:start+int64(n)]));err!=nil{t.Fatal(err)}
	}
	var paths []string
	if err:=s.Seal(ctx,func(_ context.Context,e Entry,path string)error{
		paths=append(paths,e.Path)
		if e.Directory{if path!=""{t.Fatal("directory has spool path")};return nil}
		got,err:=os.ReadFile(path)
		if err!=nil||sha256.Sum256(got)!=e.Hash{t.Fatal("publisher received wrong bytes")}
		return nil
	});err!=nil{t.Fatal(err)}
	if len(paths)!=4{t.Fatal("empty entries lost")}
	if _,err:=Reopen(ctx,s.Path(),tx,m,b);!errors.Is(err,ErrUncertain){t.Fatal("publication auto-retried")}
	if _,err:=os.Stat(filepath.Join(s.Path(),"published.v2"));err!=nil{t.Fatal(err)}
}

func TestParallelLanesAndGlobalBudget(t *testing.T){
	ctx,cancel:=context.WithTimeout(context.Background(),15*time.Second);defer cancel()
	m,data,tx:=fixture(t)
	receiveBudget:=budget(t,2);sendBudget:=budget(t,2)
	s,err:=Create(t.TempDir(),tx,m,receiveBudget);if err!=nil{t.Fatal(err)}
	sender,err:=NewSender(tx,m,sendBudget,func(_ context.Context,i uint32)(io.ReaderAt,io.Closer,error){
		if i!=2{return nil,nil,errors.New("unexpected file")}
		return bytes.NewReader(data),io.NopCloser(bytes.NewReader(nil)),nil
	})
	if err!=nil{t.Fatal(err)}
	var wg sync.WaitGroup
	errs:=make(chan error,4)
	for _,block:=range []Block{{2,0},{2,1}}{
		a,b:=net.Pipe()
		wg.Add(2)
		go func(){defer wg.Done();errs<-sender.ServeLane(ctx,a)}()
		go func(block Block){defer wg.Done();errs<-s.ReceiveLane(ctx,b,[]Block{block})}(block)
	}
	wg.Wait();close(errs)
	for err:=range errs{if err!=nil{t.Fatal(err)}}
	missing,err:=s.Missing();if err!=nil||len(missing)!=0{t.Fatal("parallel transfer incomplete")}
	for _,b:=range []*Budget{receiveBudget,sendBudget}{if _,active:=b.Status();active!=0{t.Fatal("lane leaked")}}
}

func TestBudgetCeilingAndCancellation(t *testing.T){
	ctx,cancel:=context.WithTimeout(context.Background(),5*time.Second);defer cancel()
	b:=budget(t,32)
	if err:=b.SetLimit(33);err==nil{t.Fatal("invalid ceiling accepted")}
	entered:=make(chan struct{},32)
	release:=make(chan struct{})
	var wg sync.WaitGroup
	for i:=0;i<32;i++{
		wg.Add(1)
		go func(){defer wg.Done();_ = b.run(ctx,func(buf []byte)error{
			if len(buf)!=BufferSize{t.Error("wrong stream buffer")}
			entered<-struct{}{}
			select{case <-release:return nil;case <-ctx.Done():return ctx.Err()}
		})}()
	}
	for i:=0;i<32;i++{select{case <-entered:case <-ctx.Done():t.Fatal("admission timeout")}}
	if _,active:=b.Status();active!=32{t.Fatal("wrong active count")}
	waitCtx,stop:=context.WithCancel(ctx);stop()
	if err:=b.run(waitCtx,func([]byte)error{t.Error("cancelled task admitted");return nil});!errors.Is(err,context.Canceled){t.Fatal("cancelled wait not rejected")}
	close(release);wg.Wait()
	if _,active:=b.Status();active!=0{t.Fatal("budget leaked")}
	a:=Adaptive{Budget:b,Ceiling:32}
	if err:=a.Observe(Sample{BytesPerSecond:100,RetryOrPressure:true});err!=nil{t.Fatal(err)}
	if limit,_:=b.Status();limit!=16{t.Fatal("pressure did not reduce limit")}
}
