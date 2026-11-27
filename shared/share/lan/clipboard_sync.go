package main

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"time"

	"pulse-extras/share-lan/sharecore"
)

// An explicit, one-way session, never a global always-on clipboard watcher.
// No automatic files, on-disk clipboard payloads, or initial old clipboard.
const syncInterval=500*time.Millisecond
const syncIdle=20*time.Second

type clipboardSyncIO struct{
	sequence func()(uint32,error)
	read func(string)(clipboardPayload,error)
	write func(sharecore.ContentKind,[]byte,[]string,uint32,*uint32)error
}
func syncKind(name string)(sharecore.ContentKind,int,error){
	switch name{
	case "text":return sharecore.ClipboardText,maxClipboardText,nil
	case "image":return sharecore.ClipboardImage,maxClipboardImage,nil
	default:return 0,0,errors.New("automatic clipboard supports only text or image")
	}
}
func syncHeader(kind sharecore.ContentKind)[]byte{return []byte{'P','S','C','4',byte(kind)}}
func syncDeadline(s sharecore.LaneStream)error{return s.SetDeadline(time.Now().Add(syncIdle))}
func syncSend(ctx context.Context,s sharecore.LaneStream,typ string,check batchCheck,local clipboardSyncIO,interval time.Duration)error{
	kind,limit,err:=syncKind(typ);if err!=nil{return err}
	if err=check(ctx);err!=nil{return err}
	previous,err:=local.sequence();if err!=nil{return err}
	if err=syncDeadline(s);err!=nil{return err}
	if err=writeAll(s,syncHeader(kind));err!=nil{return err}
	if err=readStatus(s,1);err!=nil{return err}
	tick:=time.NewTicker(interval);defer tick.Stop()
	var last [32]byte
	haveLast:=false
	for{
		select{case <-ctx.Done():return ctx.Err();case <-tick.C:}
		if err=check(ctx);err!=nil{return err}
		if err=syncDeadline(s);err!=nil{return err}
		now,err:=local.sequence();if err!=nil{return err}
		if now!=previous{
			p,e:=local.read(typ)
			after,seqErr:=local.sequence()
			if seqErr!=nil{clear(p.data);return seqErr}
			if e==nil&&p.kind==kind&&after==now&&len(p.data)<=limit{
				h:=sha256.Sum256(p.data)
				if !haveLast||h!=last{
					var header [37]byte;header[0]=1;binary.BigEndian.PutUint32(header[1:5],uint32(len(p.data)));copy(header[5:],h[:])
					err=writeAll(s,header[:]);if err==nil{err=writeAll(s,p.data)}
					clear(p.data)
					if err!=nil{return err}
					if err=readStatus(s,1);err!=nil{return err}
					last=h;haveLast=true;previous=now
					continue
				}
				previous=now
			}
			clear(p.data)
		}
		// Heartbeats also recheck trust and detect a disconnected peer.
		if err=writeAll(s,[]byte{0});err!=nil{return err}
		if err=readStatus(s,1);err!=nil{return err}
	}
}
func syncReceive(ctx context.Context,s sharecore.LaneStream,typ string,check batchCheck,local clipboardSyncIO,expected uint32)error{
	kind,limit,err:=syncKind(typ);if err!=nil{return err}
	if err=check(ctx);err!=nil{return err}
	if err=syncDeadline(s);err!=nil{return err}
	var hello [5]byte
	if _,err=io.ReadFull(s,hello[:]);err!=nil{return err}
	if string(hello[:])!=string(syncHeader(kind)){return errors.New("clipboard sync type mismatch")}
	if err=writeAll(s,[]byte{1});err!=nil{return err}
	for{
		if err=check(ctx);err!=nil{return err}
		if err=syncDeadline(s);err!=nil{return err}
		var cmd [1]byte
		if _,err=io.ReadFull(s,cmd[:]);err!=nil{return err}
		if cmd[0]==0{
			if err=writeAll(s,[]byte{1});err!=nil{return err}
			continue
		}
		if cmd[0]!=1{return errors.New("invalid clipboard sync frame")}
		var header [36]byte
		if _,err=io.ReadFull(s,header[:]);err!=nil{return err}
		n:=binary.BigEndian.Uint32(header[:4]);if n>uint32(limit){return errors.New("clipboard sync payload exceeds limit")}
		var hash [32]byte;copy(hash[:],header[4:])
		payload:=make([]byte,int(n))
		_,err=io.ReadFull(s,payload)
		if err==nil&&sha256.Sum256(payload)!=hash{err=errors.New("clipboard sync digest mismatch")}
		if err==nil{err=check(ctx)}
		if err==nil{
			// The Windows adapter compares the sequence while it owns the
			// clipboard and returns the sequence of its own successful write.
			err=local.write(kind,payload,nil,expected,&expected)
		}
		clear(payload)
		if err!=nil{return err}
		if err=writeAll(s,[]byte{1});err!=nil{return err}
	}
}
func clipboardSyncCLI(ctx context.Context,c console,b binding,addr netip.AddrPort,port uint16,store,label,typ string,quic,receiving bool)error{
	if store==""||label==""{return errors.New("clipboard sync requires a saved peer")}
	kind,_,err:=syncKind(typ);if err!=nil{return err}
	id,pin,err:=sessionIdentity(c,store,label);if err!=nil{return err}
	check:=func(ctx context.Context)error{return batchGrant(ctx,store,label,id,pin)}
	if err=check(ctx);err!=nil{return err}
	direction:="send new local clipboard changes";if receiving{direction="automatically replace clipboard until a local edit"}
	answer,err:=c.prompt(fmt.Sprintf("OFFER enable %s, type=%d, peer=%x until cancelled? Enter yes:",direction,kind,pin))
	if err!=nil{return err};if answer!="yes"{return errors.New("clipboard sync declined")}
	local:=clipboardSyncIO{localClipboardSequence,readLocalClipboard,writeClipboardNext}
	seq,err:=local.sequence();if err!=nil{return err}
	var link *batchLink
	if receiving{link,err=openBatchReceiver(ctx,b,port,id,pin,quic,func(s string){fmt.Println("LISTEN",s)})}else{link,err=openBatchSender(ctx,b,addr,id,pin,quic)}
	if err!=nil{return err}
	defer link.close()
	stop:=context.AfterFunc(ctx,link.close);defer stop()
	fmt.Println("CLIPBOARD SYNC active; cancel to stop")
	if receiving{return syncReceive(ctx,link.control,typ,check,local,seq)}
	return syncSend(ctx,link.control,typ,check,local,syncInterval)
}
