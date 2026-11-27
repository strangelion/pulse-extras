package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"sync"
	"sync/atomic"
	"time"

	quic "github.com/quic-go/quic-go"
)

// A separate ALPN prevents accidental TCP/QUIC protocol interchange. The
// existing TLS config verifies both pins, the hybrid group and this ALPN.
const quicFileALPN = "pulse-share-quic/1"

func quicNetwork(b binding)string{
	if b.ip.Is4(){return "udp4"};return "udp6"
}

// Only the selected local interface and admitted source may carry packets.
// Once authenticated, freeze the complete remote tuple for this session.
// Rebinding/migration requires a new explicit connection, not silent trust.
// Hide UDP OOB fast paths so all packet I/O goes through this filter.
type admittedPackets struct{
	net.PacketConn
	mu sync.RWMutex
	allow func(netip.Addr)bool
	peer netip.AddrPort
}
func(p *admittedPackets) admitted(a net.Addr)bool{
	u,ok:=a.(*net.UDPAddr);if !ok{return false}
	ap:=u.AddrPort()
	p.mu.RLock();defer p.mu.RUnlock()
	if p.peer.IsValid(){return ap==p.peer}
	return p.allow!=nil&&p.allow(ap.Addr())
}
func(p *admittedPackets) freeze(a net.Addr)error{
	u,ok:=a.(*net.UDPAddr);if !ok||!p.admitted(a){return errors.New("QUIC endpoint denied")}
	p.mu.Lock();defer p.mu.Unlock()
	if p.peer.IsValid()&&p.peer!=u.AddrPort(){return errors.New("QUIC endpoint changed")}
	p.peer=u.AddrPort();return nil
}
func(p *admittedPackets) ReadFrom(b []byte)(int,net.Addr,error){
	for{n,a,e:=p.PacketConn.ReadFrom(b);if e!=nil||p.admitted(a){return n,a,e}}
}
func(p *admittedPackets) WriteTo(b []byte,a net.Addr)(int,error){
	if !p.admitted(a){return 0,errors.New("QUIC destination denied")}
	return p.PacketConn.WriteTo(b,a)
}

func fileQUICConfig(server bool)*quic.Config{
	incoming:=int64(-1);if server{incoming=1}
	return &quic.Config{
		HandshakeIdleTimeout:5*time.Second,MaxIdleTimeout:2*time.Minute,
		KeepAlivePeriod:15*time.Second,Allow0RTT:false,
		MaxIncomingStreams:incoming,MaxIncomingUniStreams:-1,
		RequireStreamCreditRelease:true,
		InitialStreamReceiveWindow:256*1024,MaxStreamReceiveWindow:1024*1024,
		InitialConnectionReceiveWindow:256*1024,MaxConnectionReceiveWindow:2*1024*1024,
	}
}

func finishQUICClient(s *quic.Stream)error{
	if err:=s.SetDeadline(time.Now().Add(10*time.Second));err!=nil{return err}
	if err:=s.Close();err!=nil{return err}
	// The receiver sends FIN only after its final application receipt.
	// Waiting for it prevents discarding queued bytes by closing early.
	var b [1]byte
	if n,err:=s.Read(b[:]);n!=0||err!=io.EOF{return errors.New("QUIC completion uncertain")}
	return nil
}

func finishQUICServer(ctx context.Context,c *quic.Conn,s *quic.Stream)error{
	if err:=s.SetDeadline(time.Now().Add(10*time.Second));err!=nil{return err}
	var b [1]byte
	if n,err:=s.Read(b[:]);n!=0||err!=io.EOF{return errors.New("local commit complete; QUIC peer completion uncertain")}
	if err:=s.Close();err!=nil{return err}
	// Keep the transport alive while the client's FIN acknowledgement
	// arrives. The local commit has already completed; no rollback.
	timer:=time.NewTimer(10*time.Second);defer timer.Stop()
	select{
	case <-c.Context().Done():return nil
	case <-ctx.Done():return ctx.Err()
	case <-timer.C:return errors.New("local commit complete; QUIC shutdown uncertain")
	}
}

func sendQUICFile(ctx context.Context,b binding,addr netip.AddrPort,id identity,pin [32]byte,file *os.File,o offer)error{
	raw,err:=net.ListenUDP(quicNetwork(b),net.UDPAddrFromAddrPort(netip.AddrPortFrom(b.ip,0)))
	if err!=nil{return err};defer raw.Close()
	packets:=&admittedPackets{PacketConn:raw,peer:addr}
	tr:=&quic.Transport{Conn:packets};defer tr.Close()
	dial,stopDial:=context.WithTimeout(ctx,laneHandshakeTimeout);defer stopDial()
	c,err:=tr.Dial(dial,net.UDPAddrFromAddrPort(addr),tlsConfigForProtocol(id,pin,false,quicFileALPN),fileQUICConfig(false))
	if err!=nil{return err}
	defer c.CloseWithError(0,"transfer ended")
	stop:=context.AfterFunc(ctx,func(){c.CloseWithError(1,"cancelled")});defer stop()
	if err:=packets.freeze(c.RemoteAddr());err!=nil{return err}
	s,err:=c.OpenStreamSync(dial);if err!=nil{return err}
	fmt.Println("TLS",c.ConnectionState().TLS.CurveID)
	fmt.Println("TRANSPORT QUIC")
	if err:=sendFileProgress(s,file,o,consoleProgress);err!=nil{return err}
	return finishQUICClient(s)
}

func receiveQUICFile(ctx context.Context,c console,b binding,port uint16,store,label,spool string,commit commitFunc)error{
	raw,err:=net.ListenUDP(quicNetwork(b),net.UDPAddrFromAddrPort(netip.AddrPortFrom(b.ip,port)))
	if err!=nil{return err};defer raw.Close()
	fmt.Println("LISTEN",raw.LocalAddr())
	id,pin,err:=sessionIdentity(c,store,label);if err!=nil{return err}
	packets:=&admittedPackets{PacketConn:raw,allow:b.allowsRemote}
	var handshakes atomic.Int32
	tr:=&quic.Transport{Conn:packets,VerifySourceAddress:func(net.Addr)bool{return true},
		ConnContext:func(ctx context.Context,info *quic.ClientInfo)(context.Context,error){
			if !packets.admitted(info.RemoteAddr)||handshakes.Add(1)>8{return nil,errors.New("QUIC admission limit")}
			return ctx,nil
		}}
	defer tr.Close()
	listener,err:=tr.Listen(tlsConfigForProtocol(id,pin,true,quicFileALPN),fileQUICConfig(true))
	if err!=nil{return err};defer listener.Close()
	wait,stopWait:=context.WithTimeout(ctx,2*time.Minute);defer stopWait()
	conn,err:=listener.Accept(wait);if err!=nil{return err}
	defer conn.CloseWithError(0,"transfer ended")
	stop:=context.AfterFunc(ctx,func(){conn.CloseWithError(1,"cancelled")});defer stop()
	if err:=packets.freeze(conn.RemoteAddr());err!=nil{return err}
	// Stop accepting new connections; Transport.Listen keeps this one alive.
	if err:=listener.Close();err!=nil{return err}
	stream,err:=conn.AcceptStream(wait);if err!=nil{return err}
	fmt.Println("TLS",conn.ConnectionState().TLS.CurveID)
	fmt.Println("TRANSPORT QUIC")
	if err:=receiveFileProgress(stream,spool,func(o offer)(bool,error){
		line,err:=c.prompt(fmt.Sprintf("OFFER %q (%d bytes), accept? Enter yes:",o.name,o.size))
		return line=="yes",err
	},commit,consoleProgress);err!=nil{return err}
	return finishQUICServer(ctx,conn,stream)
}
