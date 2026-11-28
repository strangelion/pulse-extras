package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"pulse-extras/share-lan/sharecore"
)

func TestBatchSessionTCPAndQUIC(t *testing.T){
	for _,q:=range []bool{false,true}{
		t.Run(map[bool]string{false:"TCP",true:"QUIC"}[q],func(t *testing.T){
			ctx,cancel:=context.WithTimeout(context.Background(),25*time.Second);defer cancel()
			a,err:=newIdentity();if err!=nil{t.Fatal(err)}
			b,err:=newIdentity();if err!=nil{t.Fatal(err)}
			bind,err:=bindLocal("127.0.0.1");if err!=nil{t.Fatal(err)}
			root:=filepath.Join(t.TempDir(),"tree");if err:=os.MkdirAll(filepath.Join(root,"empty"),0700);err!=nil{t.Fatal(err)}
			payload:=bytes.Repeat([]byte{42},sharecore.BlockSize*2+123)
			if err:=os.WriteFile(filepath.Join(root,"data"),payload,0600);err!=nil{t.Fatal(err)}
			s,err:=sharecore.ScanSelection(ctx,root);if err!=nil{t.Fatal(err)}
			spool:=t.TempDir()
			var resume string
			if q{
				wire,err:=s.Manifest.Encode();if err!=nil{t.Fatal(err)}
				tx:=sharecore.Transaction{Peer:a.pin,Manifest:sha256.Sum256(wire)}
				if _,err:=rand.Read(tx.ID[:]);err!=nil{t.Fatal(err)}
				budget,err:=sharecore.NewBudget(1);if err!=nil{t.Fatal(err)}
				stage,err:=sharecore.Create(spool,tx,s.Manifest,budget);if err!=nil{t.Fatal(err)}
				if err:=stage.Receive(ctx,sharecore.Block{File:1,Index:0},bytes.NewReader(payload[:sharecore.BlockSize]));err!=nil{t.Fatal(err)}
				resume=stage.Path()
				if err:=stage.Close();err!=nil{t.Fatal(err)}
			}
			endpoint:=make(chan string,1);done:=make(chan error,1)
			check:=func(ctx context.Context)error{return ctx.Err()}
			go func(){
				link,err:=openBatchReceiver(ctx,bind,0,b,a.pin,q,func(s string){endpoint<-s})
				if err!=nil{done<-err;return};defer link.close()
				done<-batchReceive(ctx,link,batchReceiveOptions{spool:spool,resume:resume,channels:3},a.pin,check,
					func(m sharecore.Manifest,k sharecore.ContentKind)(bool,error){return k==sharecore.Files&&len(m.Entries)==3,nil},
					func(ctx context.Context,stage *sharecore.Stage,m sharecore.Manifest,k sharecore.ContentKind)error{
						return stage.Seal(ctx,func(_ context.Context,e sharecore.Entry,path string)error{
							if e.Directory{return nil}
							b,err:=os.ReadFile(path);if err!=nil{return err}
							if sha256.Sum256(b)!=sha256.Sum256(payload){return errors.New("wrong payload")};return nil
						})
					})
			}()
			var address string
			select{case address=<-endpoint:case err:=<-done:t.Fatal(err);case <-ctx.Done():t.Fatal(ctx.Err())}
			addr,err:=bind.peer(address);if err!=nil{t.Fatal(err)}
			link,err:=openBatchSender(ctx,bind,addr,a,b.pin,q);if err!=nil{t.Fatal(err)};defer link.close()
			if err:=batchSend(ctx,link,batchSource{s.Manifest,s.OpenSource},sharecore.Files,b.pin,3,check);err!=nil{t.Fatal(err)}
			select{case err:=<-done:if err!=nil{t.Fatal(err)};case <-ctx.Done():t.Fatal(ctx.Err())}
			dirs,err:=os.ReadDir(spool);if err!=nil||len(dirs)!=1{t.Fatal("missing persisted record",err)}
			if _,err:=os.Stat(filepath.Join(spool,dirs[0].Name(),"published.v2"));err!=nil{t.Fatal(err)}
			if _,err:=os.Stat(filepath.Join(spool,dirs[0].Name(),"file-00000001.part"));!os.IsNotExist(err){t.Fatal("published payload not released")}
		})
	}
}
func TestBatchBrowseSelection(t *testing.T){
	m:=sharecore.Manifest{Entries:[]sharecore.Entry{{Path:"root",Directory:true},{Path:"root/sub",Directory:true},{Path:"root/sub/empty",Directory:true},{Path:"root/other",Directory:true}}}
	out,ids,err:=selectBatch(m,"root/sub");if err!=nil||len(out.Entries)!=2||out.Entries[1].Path!="sub/empty"||ids[0]!=1{t.Fatal("browse selection mismatch",err)}
	for _,p:=range []string{"../outside","root/missing","/root"}{if _,_,err:=selectBatch(m,p);err==nil{t.Fatal("invalid browse request admitted")}}
}
