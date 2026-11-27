package main

import (
	"context"
	"errors"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"pulse-extras/share-lan/sharecore"
)

func TestClipboardSyncChangedSequence(t *testing.T){
	ctx,cancel:=context.WithTimeout(context.Background(),3*time.Second);defer cancel()
	a,b:=net.Pipe();defer a.Close();defer b.Close()
	stop:=context.AfterFunc(ctx,func(){a.Close();b.Close()});defer stop()
	var src,dst atomic.Uint32
	src.Store(1);dst.Store(10)
	started:=make(chan struct{},1)
	got:=make(chan string,2)
	sender:=clipboardSyncIO{
		sequence:func()(uint32,error){
			v:=src.Load()
			select{case started<-struct{}{}:default:}
			return v,nil
		},
		read:func(string)(clipboardPayload,error){
			return clipboardPayload{kind:sharecore.ClipboardText,data:[]byte("new value")},nil
		},
	}
	receiver:=clipboardSyncIO{
		write:func(k sharecore.ContentKind,p []byte,_ []string,expected uint32,next *uint32)error{
			if k!=sharecore.ClipboardText||!dst.CompareAndSwap(expected,expected+1){return errors.New("clipboard changed")}
			*next=expected+1;got<-string(p);return nil
		},
	}
	check:=func(ctx context.Context)error{return ctx.Err()}
	sendDone,recvDone:=make(chan error,1),make(chan error,1)
	go func(){defer a.Close();sendDone<-syncSend(ctx,a,"text",check,sender,10*time.Millisecond)}()
	go func(){defer b.Close();recvDone<-syncReceive(ctx,b,"text",check,receiver,10)}()
	select{case <-started:case <-ctx.Done():t.Fatal(ctx.Err())}
	select{case v:=<-got:t.Fatal("initial clipboard leaked",v);case <-time.After(40*time.Millisecond):}
	src.Store(2)
	select{case v:=<-got:if v!="new value"{t.Fatal(v)};case <-ctx.Done():t.Fatal(ctx.Err())}
	// Same content is deduplicated; a receiver edit is never overwritten.
	dst.Store(90)
	src.Store(3)
	select{case v:=<-got:t.Fatal("duplicate delivered",v);case <-time.After(40*time.Millisecond):}
	cancel()
	select{case <-sendDone:case <-time.After(time.Second):t.Fatal("sender leaked")}
	select{case <-recvDone:case <-time.After(time.Second):t.Fatal("receiver leaked")}
}
func TestClipboardSyncRejectFiles(t *testing.T){
	if _,_,err:=syncKind("files");err==nil{t.Fatal("automatic file sync admitted")}
}
