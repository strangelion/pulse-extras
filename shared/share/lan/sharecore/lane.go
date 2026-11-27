package sharecore

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"time"
)

// LaneProtocol is a separate versioned application protocol; native transport
// must authenticate each lane's peer, check its certificate and bind it to
// the same explicitly approved transaction. No trust derives from this ID.
const LaneProtocol = "pulse-share-batch/2"

const laneIdle = 30*time.Second

// Source opens an independently reviewed source for a manifest entry.
// The adapter owns path/handle admission, identity and source change checks.
type Source func(context.Context,uint32)(io.ReaderAt,io.Closer,error)

func writeAll(w io.Writer,data []byte)error{
	for len(data)>0{
		n,err:=w.Write(data)
		if err!=nil{return err}
		if n<=0||n>len(data){return io.ErrShortWrite}
		data=data[n:]
	}
	return nil
}

func laneHeader(tx Transaction)[68]byte{
	var h [68]byte
	copy(h[:4],"PSL2");copy(h[4:36],tx.ID[:]);copy(h[36:68],tx.Manifest[:])
	return h
}

func status(r io.Reader,want byte)error{
	var b [1]byte
	if _,err:=io.ReadFull(r,b[:]);err!=nil{return err}
	if b[0]!=want{return errors.New("unexpected lane status")}
	return nil
}

// ServeLane consumes one already-authenticated, approved stream. The
// budget reservation lasts for the whole lane, not each block. Each request
// is a fixed block identity in the agreed manifest. The sender checks the
// source digest before marking the block finished. No new manifest, grant,
// filename or transaction can be supplied over a lane.
type Sender struct {
	tx Transaction
	m Manifest
	b *Budget
	open Source
}

// NewSender validates and snapshots once per transaction, rather than
// cloning an up-to-16-MiB manifest separately for every parallel lane.
func NewSender(tx Transaction,m Manifest,b *Budget,open Source)(*Sender,error){
	if open==nil{return nil,errors.New("missing source adapter")}
	_,manifest,err:=prepare(m,tx,b)
	if err!=nil{return nil,err}
	return &Sender{tx:tx,m:manifest,b:b,open:open},nil
}

func (s *Sender) ServeLane(ctx context.Context,conn net.Conn)error{
	if conn==nil{return errors.New("missing lane adapter")}
	defer conn.Close()
	stop:=context.AfterFunc(ctx,func(){conn.Close()});defer stop()
	return s.b.run(ctx,func(buf []byte)error{
		if err:=conn.SetDeadline(time.Now().Add(laneIdle));err!=nil{return err}
		expect:=laneHeader(s.tx)
		var header [68]byte
		if _,err:=io.ReadFull(conn,header[:]);err!=nil{return err}
		if header!=expect{return errors.New("lane transaction mismatch")}
		if err:=writeAll(conn,[]byte{1});err!=nil{return err}
		// Bound even a malicious approved peer's repeated requests.
		seen:=make(map[Block]struct{})
		for{
			if err:=conn.SetDeadline(time.Now().Add(laneIdle));err!=nil{return err}
			var command [1]byte
			if _,err:=io.ReadFull(conn,command[:]);err!=nil{return err}
			if command[0]==0{return writeAll(conn,[]byte{3})}
			if command[0]!=1||len(seen)>=MaxBlocks{return errors.New("invalid lane request")}
			var ref [8]byte
			if _,err:=io.ReadFull(conn,ref[:]);err!=nil{return err}
			block:=Block{binary.BigEndian.Uint32(ref[:4]),binary.BigEndian.Uint32(ref[4:])}
			offset,n,digest,err:=s.m.blockInfo(block)
			if err!=nil{return err}
			if _,ok:=seen[block];ok{return errors.New("duplicate lane request")}
			seen[block]=struct{}{}
			r,closer,err:=s.open(ctx,block.File)
			if err!=nil{return err}
			if r==nil||closer==nil{if closer!=nil{closer.Close()};return errors.New("invalid source adapter")}
			h:=sha256.New()
			err=copyExact(ctx,io.MultiWriter(conn,h),io.NewSectionReader(r,offset,int64(n)),int64(n),buf)
			err=errors.Join(err,closer.Close())
			if err!=nil{return err}
			if !bytes.Equal(h.Sum(nil),digest[:]){return ErrCorrupt}
			if err:=writeAll(conn,[]byte{2});err!=nil{return err}
			// Receiver acknowledges only a synced, digest-verified block.
			if err:=status(conn,1);err!=nil{return err}
		}
	})
}

// ReceiveLane requests the caller-assigned missing blocks, then closes.
// A disconnect preserves durable verified receipts. No auto-publish;
// Seal separately verifies all files and invokes a reviewed local publisher.
func(s *Stage) ReceiveLane(ctx context.Context,conn net.Conn,blocks []Block)error{
	if conn==nil{return errors.New("missing lane connection")}
	defer conn.Close()
	stop:=context.AfterFunc(ctx,func(){conn.Close()});defer stop()
	if len(blocks)==0||len(blocks)>MaxBlocks{return errors.New("invalid assigned blocks")}
	return s.budget.run(ctx,func(buf []byte)error{
		if err:=conn.SetDeadline(time.Now().Add(laneIdle));err!=nil{return err}
		header:=laneHeader(s.tx)
		if err:=writeAll(conn,header[:]);err!=nil{return err}
		if err:=status(conn,1);err!=nil{return err}
		for _,block:=range blocks{
			if _,_,_,err:=s.m.blockInfo(block);err!=nil{return err}
			if err:=conn.SetDeadline(time.Now().Add(laneIdle));err!=nil{return err}
			var request [9]byte
			request[0]=1
			binary.BigEndian.PutUint32(request[1:5],block.File)
			binary.BigEndian.PutUint32(request[5:9],block.Index)
			if err:=writeAll(conn,request[:]);err!=nil{return err}
			if err:=s.receive(ctx,block,conn,buf,func()error{return status(conn,2)});err!=nil{return err}
			if err:=writeAll(conn,[]byte{1});err!=nil{return err}
		}
		if err:=writeAll(conn,[]byte{0});err!=nil{return err}
		return status(conn,3)
	})
}
