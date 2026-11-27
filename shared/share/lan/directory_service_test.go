package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"pulse-extras/share-lan/sharecore"
)

func TestDirectoryReversedConnectionRoles(t *testing.T){
	for _,quic:=range []bool{false,true}{
		t.Run(map[bool]string{false:"TCP",true:"QUIC"}[quic],func(t *testing.T){
			ctx,cancel:=context.WithTimeout(context.Background(),20*time.Second);defer cancel()
			a,err:=newIdentity();if err!=nil{t.Fatal(err)}
			b,err:=newIdentity();if err!=nil{t.Fatal(err)}
			bind,err:=bindLocal("127.0.0.1");if err!=nil{t.Fatal(err)}
			root:=filepath.Join(t.TempDir(),"root")
			if err=os.Mkdir(root,0700);err!=nil{t.Fatal(err)}
			if err=os.WriteFile(filepath.Join(root,"sample"),[]byte("sample"),0600);err!=nil{t.Fatal(err)}
			src,err:=scanBatch(ctx,[]string{root});if err!=nil{t.Fatal(err)}
			spool:=t.TempDir()
			endpoint:=make(chan string,1);done:=make(chan error,1)
			check:=func(ctx context.Context)error{return ctx.Err()}
			go func(){
				link,err:=openBatchReceiver(ctx,bind,0,a,b.pin,quic,func(s string){endpoint<-s})
				if err!=nil{done<-err;return};defer link.close()
				done<-batchSend(ctx,link,src,sharecore.RemoteDirectory,b.pin,2,check)
			}()
			var addr string
			select{case addr=<-endpoint:case err:=<-done:t.Fatal(err);case <-ctx.Done():t.Fatal(ctx.Err())}
			peer,err:=bind.peer(addr);if err!=nil{t.Fatal(err)}
			link,err:=openBatchSender(ctx,bind,peer,b,a.pin,quic);if err!=nil{t.Fatal(err)}
			defer link.close()
			err=batchReceive(ctx,link,batchReceiveOptions{spool:spool,channels:2,browse:true,remotePath:"root/sample"},a.pin,check,
				func(m sharecore.Manifest,k sharecore.ContentKind)(bool,error){return k==sharecore.Files&&len(m.Entries)==1&&m.Entries[0].Path=="sample",nil},
				func(ctx context.Context,s *sharecore.Stage,m sharecore.Manifest,k sharecore.ContentKind)error{
					return s.Seal(ctx,func(_ context.Context,e sharecore.Entry,path string)error{
						data,err:=os.ReadFile(path);if err!=nil{return err}
						if string(data)!="sample"{return errors.New("incorrect subtree")};return nil
					})
				})
			if err!=nil{t.Fatal(err)}
			select{case err:=<-done:if err!=nil{t.Fatal(err)};case <-ctx.Done():t.Fatal(ctx.Err())}
		})
	}
}
