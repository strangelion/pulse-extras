package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strings"
	"sync"
	"time"

	quic "github.com/quic-go/quic-go"
	"pulse-extras/share-lan/sharecore"
)

const batchControlALPN = "pulse-share-control/3"
const batchQUICALPN = "pulse-share-quic-batch/3"
const batchDeadline = 2 * time.Hour

type batchSource struct {
	m sharecore.Manifest
	open sharecore.Source
}
type batchLink struct {
	control sharecore.LaneStream
	lane func(context.Context)(sharecore.LaneStream,error)
	finish func(context.Context)error
	close func()
}
func onceClose(f func())func(){
	var once sync.Once
	return func(){once.Do(f)}
}

// Close preserves outgoing FIN, and deadlines unblock an outstanding write.
// Never re-use a stream for a different application lane.
type batchQUICStream struct {
	*quic.Stream
	once sync.Once
	writeMu sync.Mutex
}
func(s *batchQUICStream) Write(p []byte)(int,error){
	s.writeMu.Lock();defer s.writeMu.Unlock()
	n,e:=s.Stream.Write(p);return n,quicLaneError(e)
}
func(s *batchQUICStream) Read(p []byte)(int,error){
	n,e:=s.Stream.Read(p);return n,quicLaneError(e)
}
func(s *batchQUICStream) Close()error{
	s.once.Do(func(){
		_ = s.SetDeadline(time.Now())
		s.writeMu.Lock();_ = s.Stream.Close();s.writeMu.Unlock()
		s.CancelRead(0)
	})
	return nil
}
func quicLaneError(err error)error{
	var e *quic.StreamError
	if errors.As(err,&e)&&e.Remote&&e.ErrorCode==0{return sharecore.ErrLaneDisconnected}
	return err
}
func batchQUICConfig(server bool)*quic.Config{
	c:=fileQUICConfig(server)
	c.RequireStreamCreditRelease=false
	if server{c.MaxIncomingStreams=sharecore.MaxChannels+1}
	c.MaxConnectionReceiveWindow=8*1024*1024
	return c
}
func noBatchFinish(context.Context)error{return nil}

func dialBatchTCP(ctx context.Context,b binding,addr netip.AddrPort,id identity,pin [32]byte,protocol string)(sharecore.LaneStream,error){
	d:=net.Dialer{Timeout:laneHandshakeTimeout,LocalAddr:net.TCPAddrFromAddrPort(netip.AddrPortFrom(b.ip,0))}
	raw,err:=d.DialContext(ctx,b.network(),addr.String());if err!=nil{return nil,err}
	c:=tls.Client(raw,tlsConfigForProtocol(id,pin,false,protocol))
	stop:=context.AfterFunc(ctx,func(){raw.Close()});defer stop()
	if err=raw.SetDeadline(time.Now().Add(laneHandshakeTimeout));err==nil{err=c.HandshakeContext(ctx)}
	if err!=nil{raw.Close();return nil,err}
	return c,nil
}
func acceptBatchConn(ctx context.Context,b binding,l *net.TCPListener,id identity,pin [32]byte,protocol string)(sharecore.LaneStream,error){
	deadline:=time.Now().Add(laneHandshakeTimeout)
	if d,ok:=ctx.Deadline();ok&&d.Before(deadline){deadline=d}
	if err:=l.SetDeadline(deadline);err!=nil{return nil,err}
	for i:=0;i<8;i++{
		raw,err:=l.AcceptTCP();if err!=nil{return nil,err}
		if !b.allowsRemote(raw.RemoteAddr().(*net.TCPAddr).AddrPort().Addr()){raw.Close();continue}
		c:=tls.Server(raw,tlsConfigForProtocol(id,pin,true,protocol))
		stop:=context.AfterFunc(ctx,func(){raw.Close()})
		err=raw.SetDeadline(deadline);if err==nil{err=c.HandshakeContext(ctx)}
		stop()
		if err!=nil{raw.Close();return nil,err}
		return c,nil
	}
	return nil,errors.New("batch admission limit")
}
func openBatchSender(ctx context.Context,b binding,addr netip.AddrPort,id identity,pin [32]byte,useQUIC bool)(*batchLink,error){
	if !useQUIC{
		c,err:=dialBatchTCP(ctx,b,addr,id,pin,batchControlALPN);if err!=nil{return nil,err}
		return &batchLink{c,func(ctx context.Context)(sharecore.LaneStream,error){
			return dialBatchTCP(ctx,b,addr,id,pin,sharecore.LaneProtocol)
		},noBatchFinish,onceClose(func(){c.Close()})},nil
	}
	raw,err:=net.ListenUDP(quicNetwork(b),net.UDPAddrFromAddrPort(netip.AddrPortFrom(b.ip,0)));if err!=nil{return nil,err}
	tr:=&quic.Transport{Conn:&admittedPackets{PacketConn:raw,peer:addr}}
	dial,stop:=context.WithTimeout(ctx,laneHandshakeTimeout);defer stop()
	c,err:=tr.Dial(dial,net.UDPAddrFromAddrPort(addr),tlsConfigForProtocol(id,pin,false,batchQUICALPN),batchQUICConfig(false))
	if err!=nil{tr.Close();raw.Close();return nil,err}
	closeAll:=onceClose(func(){c.CloseWithError(0,"batch ended");tr.Close();raw.Close()})
	s,err:=c.OpenStreamSync(dial);if err!=nil{closeAll();return nil,err}
	return &batchLink{s,func(ctx context.Context)(sharecore.LaneStream,error){
		s,err:=c.OpenStreamSync(ctx);if err!=nil{return nil,err}
		// QUIC streams are visible to AcceptStream only after the first
		// stream frame. Send a one-byte framing marker before returning.
		if err:=s.SetDeadline(time.Now().Add(laneHandshakeTimeout));err!=nil{s.CancelWrite(0);s.CancelRead(0);return nil,err}
		if err:=writeAll(s,[]byte{0x4c});err!=nil{s.CancelWrite(0);s.CancelRead(0);return nil,err}
		return &batchQUICStream{Stream:s},nil
	},func(context.Context)error{return finishQUICClient(s)},closeAll},nil
}
func openBatchReceiver(ctx context.Context,b binding,port uint16,id identity,pin [32]byte,useQUIC bool,announce func(string))(*batchLink,error){
	wait,stop:=context.WithTimeout(ctx,2*time.Minute);defer stop()
	if !useQUIC{
		l,err:=net.ListenTCP(b.network(),net.TCPAddrFromAddrPort(netip.AddrPortFrom(b.ip,port)));if err!=nil{return nil,err}
		announce(l.Addr().String())
		cancel:=context.AfterFunc(ctx,func(){l.Close()})
		var c sharecore.LaneStream
		for wait.Err()==nil{
			c,err=acceptBatchConn(wait,b,l,id,pin,batchControlALPN)
			var n net.Error
			if err==nil||!errors.As(err,&n)||!n.Timeout(){break}
		}
		if err!=nil||c==nil{cancel();l.Close();if err==nil{err=wait.Err()};return nil,err}
		return &batchLink{c,func(ctx context.Context)(sharecore.LaneStream,error){
			return acceptBatchConn(ctx,b,l,id,pin,sharecore.LaneProtocol)
		},noBatchFinish,onceClose(func(){cancel();c.Close();l.Close()})},nil
	}
	raw,err:=net.ListenUDP(quicNetwork(b),net.UDPAddrFromAddrPort(netip.AddrPortFrom(b.ip,port)));if err!=nil{return nil,err}
	packets:=&admittedPackets{PacketConn:raw,allow:b.allowsRemote}
	admissions:=make(chan struct{},8)
	tr:=&quic.Transport{Conn:packets,VerifySourceAddress:func(net.Addr)bool{return true},
		ConnContext:func(ctx context.Context,info *quic.ClientInfo)(context.Context,error){
			if !packets.admitted(info.RemoteAddr){return nil,errors.New("batch source denied")}
			select{case admissions<-struct{}{}:return ctx,nil;default:return nil,errors.New("batch admission limit")}
		}}
	l,err:=tr.Listen(tlsConfigForProtocol(id,pin,true,batchQUICALPN),batchQUICConfig(true))
	if err!=nil{tr.Close();raw.Close();return nil,err}
	announce(raw.LocalAddr().String())
	c,err:=l.Accept(wait)
	if err!=nil{l.Close();tr.Close();raw.Close();return nil,err}
	closeAll:=onceClose(func(){c.CloseWithError(0,"batch ended");l.Close();tr.Close();raw.Close()})
	if err=packets.freeze(c.RemoteAddr());err!=nil{closeAll();return nil,err}
	if err=l.Close();err!=nil{closeAll();return nil,err}
	s,err:=c.AcceptStream(wait);if err!=nil{closeAll();return nil,err}
	return &batchLink{s,func(ctx context.Context)(sharecore.LaneStream,error){
		s,err:=c.AcceptStream(ctx);if err!=nil{return nil,err}
		if err:=s.SetDeadline(time.Now().Add(laneHandshakeTimeout));err!=nil{s.CancelWrite(0);s.CancelRead(0);return nil,err}
		var marker [1]byte
		if _,err:=io.ReadFull(s,marker[:]);err!=nil||marker[0]!=0x4c{s.CancelWrite(0);s.CancelRead(0);return nil,errors.New("invalid lane marker")}
		return &batchQUICStream{Stream:s},nil
	},func(ctx context.Context)error{return finishQUICServer(ctx,c,s)},closeAll},nil
}

func batchKindOK(k sharecore.ContentKind)bool{
	return k==sharecore.Files||k==sharecore.ClipboardText||k==sharecore.ClipboardImage||k==sharecore.ClipboardFiles||k==sharecore.RemoteDirectory
}
func writeBatchOffer(w io.Writer,m sharecore.Manifest,kind sharecore.ContentKind,channels int)error{
	wire,err:=m.Encode();if err!=nil{return err}
	if !batchKindOK(kind)||channels<1||channels>sharecore.MaxChannels{return errors.New("invalid batch parameters")}
	var h [10]byte;copy(h[:4],"PSB3");h[4]=byte(kind);h[5]=byte(channels);binary.BigEndian.PutUint32(h[6:],uint32(len(wire)))
	if err:=writeAll(w,h[:]);err!=nil{return err};return writeAll(w,wire)
}
func readBatchOffer(r io.Reader)(sharecore.Manifest,sharecore.ContentKind,int,error){
	var h [10]byte
	if _,err:=io.ReadFull(r,h[:]);err!=nil{return sharecore.Manifest{},0,0,err}
	n:=binary.BigEndian.Uint32(h[6:]);k:=sharecore.ContentKind(h[4]);channels:=int(h[5])
	if string(h[:4])!="PSB3"||!batchKindOK(k)||channels<1||channels>sharecore.MaxChannels||n<8||n>sharecore.MaxManifest{
		return sharecore.Manifest{},0,0,errors.New("invalid batch offer")
	}
	buf:=make([]byte,int(n))
	if _,err:=io.ReadFull(r,buf);err!=nil{return sharecore.Manifest{},0,0,err}
	m,err:=sharecore.Decode(buf);return m,k,channels,err
}

// A browse request selects only an exact entry from the approved manifest.
// Never interpret it as a local path. Re-root the selected subtree.
func selectBatch(m sharecore.Manifest,path string)(sharecore.Manifest,[]uint32,error){
	if path=="."{
		idx:=make([]uint32,len(m.Entries));for i:=range idx{idx[i]=uint32(i)};return m,idx,nil
	}
	if len(path)==0||len(path)>sharecore.MaxPath{return sharecore.Manifest{},nil,errors.New("invalid browse selection")}
	found:=false
	out:=sharecore.Manifest{}
	var indices []uint32
	base:=path[strings.LastIndex(path,"/")+1:]
	for i,e:=range m.Entries{
		if e.Path==path{found=true}else if !strings.HasPrefix(e.Path,path+"/"){continue}
		e.Path=base+strings.TrimPrefix(e.Path,path)
		out.Entries=append(out.Entries,e);indices=append(indices,uint32(i))
	}
	if !found{return sharecore.Manifest{},nil,errors.New("entry not present in offered directory")}
	return out,indices,out.Validate()
}
func writeBrowseRequest(w io.Writer,path string)error{
	if len(path)>sharecore.MaxPath{return errors.New("browse selection too long")}
	var h [2]byte;binary.BigEndian.PutUint16(h[:],uint16(len(path)))
	if err:=writeAll(w,h[:]);err!=nil{return err};return writeAll(w,[]byte(path))
}
func readBrowseRequest(r io.Reader)(string,error){
	var h [2]byte;if _,err:=io.ReadFull(r,h[:]);err!=nil{return "",err}
	n:=int(binary.BigEndian.Uint16(h[:]));if n>sharecore.MaxPath{return "",errors.New("browse selection too long")}
	b:=make([]byte,n);_,err:=io.ReadFull(r,b);return string(b),err
}

type batchCheck func(context.Context)error
type batchApproval func(sharecore.Manifest,sharecore.ContentKind)(bool,error)
type batchPublish func(context.Context,*sharecore.Stage,sharecore.Manifest,sharecore.ContentKind)error

func batchSend(ctx context.Context,link *batchLink,source batchSource,kind sharecore.ContentKind,pin [32]byte,channels int,check batchCheck)error{
	ctx,cancel:=context.WithCancel(ctx);defer cancel()
	stop:=context.AfterFunc(ctx,link.close);defer stop()
	control:=link.control
	if err:=control.SetDeadline(time.Now().Add(batchDeadline));err!=nil{return err}
	if err:=check(ctx);err!=nil{return err}
	m:=source.m
	if err:=writeBatchOffer(control,m,kind,channels);err!=nil{return err}
	if kind==sharecore.RemoteDirectory{
		path,err:=readBrowseRequest(control);if err!=nil{return err}
		if err:=check(ctx);err!=nil{return err}
		if path==""{
			if err:=writeAll(control,[]byte{3});err!=nil{return err}
			return link.finish(ctx)
		}
		selected,indices,err:=selectBatch(m,path);if err!=nil{return err}
		old:=source.open
		source.open=func(ctx context.Context,i uint32)(io.ReaderAt,io.Closer,error){
			if uint64(i)>=uint64(len(indices)){return nil,nil,errors.New("invalid requested entry")}
			return old(ctx,indices[i])
		}
		m=selected
	}
	var approved [34]byte
	if _,err:=io.ReadFull(control,approved[:]);err!=nil{return err}
	if approved[0]!=1||approved[1]<1||int(approved[1])>channels{return errors.New("batch not approved or invalid channel limit")}
	channels=int(approved[1])
	wire,err:=m.Encode();if err!=nil{return err}
	tx:=sharecore.Transaction{Peer:pin,Manifest:sha256.Sum256(wire)};copy(tx.ID[:],approved[2:])
	budget,err:=sharecore.NewBudget(channels);if err!=nil{return err}
	sender,err:=sharecore.NewSender(tx,m,budget,source.open);if err!=nil{return err}
	var wg sync.WaitGroup
	active:=make(chan struct{},channels)
	var workErr error
	var mu sync.Mutex
	fail:=func(err error){mu.Lock();if workErr==nil{workErr=err};mu.Unlock();cancel()}
	defer func(){cancel();wg.Wait()}()
	var command [1]byte
	for{
		if _,err:=io.ReadFull(control,command[:]);err!=nil{
			mu.Lock();defer mu.Unlock();if workErr!=nil{return workErr};return err
		}
		switch command[0]{
		case 1:
			select{case active<-struct{}{}:case <-ctx.Done():return ctx.Err()}
			if err:=check(ctx);err!=nil{<-active;return err}
			dial,done:=context.WithTimeout(ctx,laneHandshakeTimeout)
			lane,err:=link.lane(dial);done()
			if err!=nil{<-active;return err}
			if err:=check(ctx);err!=nil{lane.Close();<-active;return err}
			wg.Add(1)
			go func(){
				defer wg.Done();defer func(){<-active}()
				err:=sender.ServeLane(ctx,lane)
				if err!=nil&&!sharecore.IsLaneInterrupted(err){fail(err)}
			}()
		case 2:
			wg.Wait()
			mu.Lock();e:=workErr;mu.Unlock();if e!=nil{return e}
			if err:=writeAll(control,[]byte{3});err!=nil{return err}
			return link.finish(ctx)
		default:return errors.New("invalid batch control command")
		}
	}
}

type batchReceiveOptions struct{
	spool,resume string
	channels int
	adaptive,allowClipboard,browse bool
	remotePath,clipboardType string
	offset int
}
func batchReceive(ctx context.Context,link *batchLink,o batchReceiveOptions,pin [32]byte,check batchCheck,approve batchApproval,publish batchPublish)error{
	stop:=context.AfterFunc(ctx,link.close);defer stop()
	control:=link.control
	if err:=control.SetDeadline(time.Now().Add(batchDeadline));err!=nil{return err}
	if err:=check(ctx);err!=nil{return err}
	m,kind,peerLimit,err:=readBatchOffer(control);if err!=nil{return err}
	if kind==sharecore.RemoteDirectory{
		if !o.browse{return errors.New("remote directory not enabled")}
		if err:=writeBrowseRequest(control,o.remotePath);err!=nil{return err}
		if o.remotePath==""{
			if o.offset<0||o.offset>len(m.Entries){return errors.New("invalid browse page")}
			end:=min(len(m.Entries),o.offset+20)
			for _,e:=range m.Entries[o.offset:end]{fmt.Printf("REMOTE %q directory=%t bytes=%d\n",e.Path,e.Directory,e.Size)}
			fmt.Printf("REMOTE PAGE %d-%d of %d\n",o.offset,end,len(m.Entries))
			if err:=readStatus(control,3);err!=nil{return err}
			return link.finish(ctx)
		}
		m,_,err=selectBatch(m,o.remotePath);if err!=nil{return err}
		kind=sharecore.Files
	}else if o.browse{return errors.New("expected an explicitly offered directory")}
	if kind!=sharecore.Files{
		if !o.allowClipboard{return errors.New("clipboard receive disabled")}
		if o.clipboardType!=""&&map[sharecore.ContentKind]string{sharecore.ClipboardText:"text",sharecore.ClipboardImage:"image",sharecore.ClipboardFiles:"files"}[kind]!=o.clipboardType{return errors.New("clipboard type not enabled")}
	}
	ok,err:=approve(m,kind);if err!=nil{return err}
	if !ok{return errors.New("local user declined batch")}
	if err:=check(ctx);err!=nil{return err}
	wire,err:=m.Encode();if err!=nil{return err}
	tx:=sharecore.Transaction{Peer:pin,Manifest:sha256.Sum256(wire)}
	channels:=min(o.channels,peerLimit)
	initial:=channels;if o.adaptive{initial=min(4,channels)}
	budget,err:=sharecore.NewBudget(initial);if err!=nil{return err}
	var stage *sharecore.Stage
	if o.resume!=""{
		tx.ID,err=sharecore.LocalStageID(o.resume);if err!=nil{return err}
		stage,err=sharecore.Reopen(ctx,o.resume,tx,m,budget)
	}else{
		if _,err=rand.Read(tx.ID[:]);err!=nil{return err}
		stage,err=sharecore.Create(o.spool,tx,m,budget)
	}
	if stage!=nil{defer stage.Close()}
	if err!=nil{return err}
	fmt.Printf("BATCH_STAGE %s\n",stage.Path())
	var approved [34]byte;approved[0]=1;approved[1]=byte(channels);copy(approved[2:],tx.ID[:])
	if err:=writeAll(control,approved[:]);err!=nil{return err}
	var openMu sync.Mutex
	open:=func(ctx context.Context,got sharecore.Transaction)(sharecore.LaneStream,error){
		openMu.Lock();defer openMu.Unlock()
		if got!=tx{return nil,errors.New("local transaction changed")}
		if err:=check(ctx);err!=nil{return nil,err}
		if err:=writeAll(control,[]byte{1});err!=nil{return nil,fmt.Errorf("control interrupted: %w",err)}
		lane,err:=link.lane(ctx);if err!=nil{return nil,fmt.Errorf("lane opening interrupted; resume explicit stage: %w",err)}
		if err:=check(ctx);err!=nil{lane.Close();return nil,err}
		return lane,nil
	}
	sampleCtx,stopSample:=context.WithCancel(ctx)
	var sampler sync.WaitGroup
	sampler.Add(1)
	go func(){
		defer sampler.Done()
		ticker:=time.NewTicker(time.Second);defer ticker.Stop()
		prev:=stage.VerifiedBytes()
		adaptive:=sharecore.Adaptive{Budget:budget,Ceiling:channels}
		consoleProgress(prev,m.TotalBytes())
		for{select{
		case <-sampleCtx.Done():return
		case <-ticker.C:
			now:=stage.VerifiedBytes()
			consoleProgress(now,m.TotalBytes())
			if o.adaptive{_ = adaptive.Observe(sharecore.Sample{BytesPerSecond:now-prev})}
			prev=now
		}}
	}()
	err=stage.TransferMissing(ctx,open,sharecore.ScheduleOptions{Workers:channels,Attempts:5})
	stopSample();sampler.Wait()
	if err!=nil{return fmt.Errorf("batch retained at %s: %w",stage.Path(),err)}
	consoleProgress(stage.VerifiedBytes(),m.TotalBytes())
	if err:=check(ctx);err!=nil{return err}
	if err:=publish(ctx,stage,m,kind);err!=nil{return err}
	if err:=stage.ClearPublishedPayloads();err!=nil{return fmt.Errorf("published, cleanup incomplete: %w",err)}
	if err:=writeAll(control,[]byte{2});err!=nil{return fmt.Errorf("published locally, peer receipt uncertain: %w",err)}
	if err:=readStatus(control,3);err!=nil{return fmt.Errorf("published locally, peer receipt uncertain: %w",err)}
	return link.finish(ctx)
}
