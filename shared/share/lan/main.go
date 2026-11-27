// Pulse Share experimental LAN developer tool. No automatic listener,
// firewall changes, shell commands or Pulse UI launch. Persistent device
// identities are opt-in and protected by Windows DPAPI.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

type console struct {
	ctx context.Context
	scanner *bufio.Scanner
}

func (c console) prompt(s string) (string,error) {
	fmt.Println(s)
	type answer struct {text string; err error}
	done:=make(chan answer,1)
	go func(){
		if c.scanner.Scan(){done<-answer{text:strings.TrimSpace(c.scanner.Text())};return}
		err:=c.scanner.Err()
		if err==nil{err=io.EOF}
		done<-answer{err:err}
	}()
	timer := time.NewTimer(90*time.Second)
	defer timer.Stop()
	select {
	case <-c.ctx.Done():return "",c.ctx.Err()
	case <-timer.C:return "",errors.New("confirmation timed out")
	case a:=<-done:return a.text,a.err
	}
}

func (c console) pair(id identity) ([32]byte,error) {
	fmt.Printf("FINGERPRINT %x\n",id.pin)
	line,err:=c.prompt("Enter the other device's full fingerprint from its own console (not discovery):")
	if err!=nil{return [32]byte{},err}
	pin,err:=parsePin(line)
	if err==nil && pin==id.pin{return pin,errors.New("cannot pair with this session's own identity")}
	return pin,err
}

// A saved peer is selected explicitly for each session. It does not
// authorize automatic receiving, directory access, or new peer enrollment.
func sessionIdentity(c console, store, label string) (identity, [32]byte, error) {
	if store == "" && label == "" {
		id, err := newIdentity()
		if err != nil { return identity{}, [32]byte{}, err }
		pin, err := c.pair(id)
		return id, pin, err
	}
	if store == "" || label == "" { return identity{}, [32]byte{}, errors.New("use both --store and --paired") }
	root, err := storeRoot(store)
	if err != nil { return identity{}, [32]byte{}, err }
	id, err := loadStoredIdentity(root)
	if err != nil { return identity{}, [32]byte{}, err }
	pin, err := loadPeer(root, label)
	if err != nil { return identity{}, [32]byte{}, err }
	if pin == id.pin { return identity{}, [32]byte{}, errors.New("cannot select own identity") }
	fmt.Printf("PAIRED %s %x\n", label, pin)
	return id, pin, nil
}

func manageTrust(c console, operation string, args []string) error {
	f := flags(operation)
	store := f.String("store", "", "existing absolute user-private device store")
	label := f.String("name", "", "local peer label")
	if err := noExtra(f, args); err != nil { return err }
	root, err := storeRoot(*store)
	if err != nil { return err }
	if operation == "identity-init" {
		id, err := initStoredIdentity(root)
		if err != nil { return err }
		fmt.Printf("FINGERPRINT %x\n", id.pin)
		return nil
	}
	id, err := loadStoredIdentity(root)
	if err != nil { return err }
	switch operation {
	case "identity-show":
		fmt.Printf("FINGERPRINT %x\n", id.pin)
		return nil
	case "peer-add":
		if _, err := peerFile(root, *label); err != nil { return err }
		pin, err := c.pair(id)
		if err != nil { return err }
		answer, err := c.prompt(fmt.Sprintf("Trust %s fingerprint %x? Enter yes:", *label, pin))
		if err != nil { return err }
		if answer != "yes" { return errors.New("pairing declined") }
		return addPeer(root, *label, pin)
	case "peer-list":
		return listPeers(root)
	case "peer-revoke":
		pin, err := loadPeer(root, *label)
		if err != nil { return err }
		answer, err := c.prompt(fmt.Sprintf("Revoke %s fingerprint %x? Enter yes:", *label, pin))
		if err != nil { return err }
		if answer != "yes" { return errors.New("revocation declined") }
		return revokePeer(root, *label)
	}
	return errors.New("unknown trust operation")
}

func flags(name string) *flag.FlagSet {
	return flag.NewFlagSet(name,flag.ContinueOnError)
}

func noExtra(f *flag.FlagSet,args []string) error {
	if err:=f.Parse(args);err!=nil{return err}
	if f.NArg()!=0{return errors.New("unexpected positional arguments")}
	return nil
}

func openSource(path string) (*os.File,error) {
	info,err:=os.Lstat(path)
	if err!=nil{return nil,err}
	if !info.Mode().IsRegular(){return nil,errors.New("choose a regular local file")}
	f,err:=os.Open(path)
	if err!=nil{return nil,err}
	opened,err:=f.Stat()
	if err!=nil || !os.SameFile(info,opened) || !opened.Mode().IsRegular(){
		f.Close()
		return nil,errors.New("source changed during open")
	}
	return f,nil
}

func sender(ctx context.Context,c console,args []string) error {
	f:=flags("send")
	local:=f.String("bind","","local interface IP")
	peer:=f.String("peer","","numeric receiver IP:port")
	source:=f.String("source","","explicit local source file")
	store:=f.String("store","","existing user-private device store")
	paired:=f.String("paired","","explicit saved peer label")
	if err:=noExtra(f,args);err!=nil{return err}
	b,err:=bindLocal(*local)
	if err!=nil{return err}
	addr,err:=b.peer(*peer)
	if err!=nil{return err}
	file,err:=openSource(*source)
	if err!=nil{return err}
	defer file.Close()
	name:=filepath.Base(*source)
	if !validName(name){return errors.New("unsupported Windows filename")}
	size,digest,err:=digestFile(file)
	if err!=nil{return err}
	id,pin,err:=sessionIdentity(c,*store,*paired)
	if err!=nil{return err}
	dialer:=net.Dialer{Timeout:10*time.Second,LocalAddr:net.TCPAddrFromAddrPort(netip.AddrPortFrom(b.ip,0))}
	raw,err:=dialer.DialContext(ctx,b.network(),addr.String())
	if err!=nil{return err}
	defer raw.Close()
	stop:=context.AfterFunc(ctx,func(){raw.Close()})
	defer stop()
	conn:=tls.Client(raw,tlsConfig(id,pin,false))
	if err:=raw.SetDeadline(time.Now().Add(10*time.Second));err!=nil{return err}
	if err:=conn.HandshakeContext(ctx);err!=nil{return fmt.Errorf("pairing failed: %w",err)}
	if err:=sendFile(conn,file,offer{name:name,size:size,digest:digest});err!=nil{return err}
	fmt.Println("COMPLETED remote commit acknowledged")
	return nil
}

func existingPath(path string, directory bool) (string,error) {
	if path==""{return "",errors.New("explicit local path required")}
	abs,err:=filepath.Abs(path)
	if err!=nil{return "",err}
	abs,err=filepath.EvalSymlinks(abs)
	if err!=nil{return "",err}
	info,err:=os.Stat(abs)
	if err!=nil{return "",err}
	if directory && !info.IsDir() || !directory && !info.Mode().IsRegular(){
		return "",errors.New("unexpected local path type")
	}
	return abs,nil
}

func verifyBinary(path string,pin [32]byte) error {
	f,err:=openSource(path)
	if err!=nil{return err}
	defer f.Close()
	_,digest,err:=digestFile(f)
	if err!=nil{return err}
	if !bytes.Equal(digest[:],pin[:]){return errors.New("local executable digest mismatch")}
	return nil
}

type nativeCommit struct {
	supervisor,worker,destination string
	supervisorPin,workerPin [32]byte
	ctx context.Context
}

func (n nativeCommit) commit(o offer,path string) error {
	if !validName(o.name){return errors.New("invalid destination leaf")}
	// All executable paths and digests were explicitly supplied by the
	// local operator. The remote peer controls only the checked basename.
	// P1 pins its own worker through CreateProcess. This developer tool
	// assumes its local supervisor installation is trusted and unchanged.
	if err:=verifyBinary(n.supervisor,n.supervisorPin);err!=nil{return err}
	if err:=verifyBinary(n.worker,n.workerPin);err!=nil{return err}
	ctx,cancel:=context.WithTimeout(n.ctx,10*time.Minute)
	defer cancel()
	cmd:=exec.CommandContext(ctx,n.supervisor,"--confirm-verified-copy",n.worker,
		fmt.Sprintf("%x",n.workerPin),path,n.destination,o.name,fmt.Sprintf("%x",o.digest))
	cmd.Stdout=io.Discard
	cmd.Stderr=os.Stderr
	if err:=cmd.Run();err!=nil{return fmt.Errorf("native commit failed: %w",err)}
	return nil
}

func receiver(ctx context.Context,c console,args []string) error {
	f:=flags("receive")
	local:=f.String("bind","","local interface IP")
	port:=f.Uint("port",0,"local TCP port (0 selects a free port)")
	advert:=f.Bool("advertise",false,"opt-in multicast discovery on selected interface")
	directory:=f.String("directory","","explicit destination directory")
	spool:=f.String("spool","","existing, trusted, user-private local spool directory")
	supervisor:=f.String("supervisor","","absolute local P1 supervisor executable")
	supervisorSHA:=f.String("supervisor-sha256","","locally verified supervisor SHA-256")
	worker:=f.String("worker","","absolute local P1 worker executable")
	workerSHA:=f.String("worker-sha256","","locally verified worker SHA-256")
	store:=f.String("store","","existing user-private device store")
	paired:=f.String("paired","","explicit saved peer label")
	if err:=noExtra(f,args);err!=nil{return err}
	if runtime.GOOS!="windows"{return errors.New("native receiving commit requires Windows")}
	if *port>65535{return errors.New("invalid port")}
	b,err:=bindLocal(*local)
	if err!=nil{return err}
	dest,err:=existingPath(*directory,true)
	if err!=nil{return err}
	sp,err:=existingPath(*spool,true)
	if err!=nil{return err}
	sup,err:=existingPath(*supervisor,false)
	if err!=nil{return err}
	work,err:=existingPath(*worker,false)
	if err!=nil{return err}
	supPin,err:=parsePin(*supervisorSHA)
	if err!=nil{return err}
	workPin,err:=parsePin(*workerSHA)
	if err!=nil{return err}
	if err:=verifyBinary(sup,supPin);err!=nil{return err}
	if err:=verifyBinary(work,workPin);err!=nil{return err}
	native:=nativeCommit{sup,work,dest,supPin,workPin,ctx}
	listener,err:=net.ListenTCP(b.network(),net.TCPAddrFromAddrPort(netip.AddrPortFrom(b.ip,uint16(*port))))
	if err!=nil{return err}
	defer listener.Close()
	stop:=context.AfterFunc(ctx,func(){listener.Close()})
	defer stop()
	bound:=listener.Addr().(*net.TCPAddr).AddrPort()
	fmt.Println("LISTEN",bound)
	announceCtx,stopAnnounce:=context.WithCancel(ctx)
	defer stopAnnounce()
	if *advert{
		go func(){
			if err:=advertise(announceCtx,b,bound.Port());err!=nil && announceCtx.Err()==nil{
				fmt.Fprintln(os.Stderr,"Discovery unavailable; use numeric address:",err)
			}
		}()
	}
	id,pin,err:=sessionIdentity(c,*store,*paired)
	if err!=nil{return err}
	if err:=listener.SetDeadline(time.Now().Add(2*time.Minute));err!=nil{return err}
	for attempts:=0;attempts<8;attempts++{
		raw,err:=listener.AcceptTCP()
		if err!=nil{return err}
		if !b.allows(raw.RemoteAddr().(*net.TCPAddr).AddrPort().Addr()){
			raw.Close()
			continue
		}
		conn:=tls.Server(raw,tlsConfig(id,pin,true))
		if err:=raw.SetDeadline(time.Now().Add(10*time.Second));err!=nil{raw.Close();return err}
		if err:=conn.HandshakeContext(ctx);err!=nil{
			raw.Close()
			fmt.Fprintln(os.Stderr,"Rejected unauthenticated connection")
			continue
		}
		defer raw.Close()
		stopTransfer:=context.AfterFunc(ctx,func(){raw.Close()})
		defer stopTransfer()
		stopAnnounce()
		listener.Close()
		err=receiveFile(conn,sp,func(o offer)(bool,error){
			line,err:=c.prompt(fmt.Sprintf("OFFER %q (%d bytes), accept? Enter yes:",o.name,o.size))
			return line=="yes",err
		},native.commit)
		if err!=nil{return err}
		fmt.Println("COMPLETED local file committed")
		return nil
	}
	return errors.New("too many unauthenticated connections")
}

func run(ctx context.Context,args []string) error {
	if len(args)==0{return errors.New("usage: pulse-share-lan {send|receive|discover|identity-init|identity-show|peer-add|peer-list|peer-revoke} [flags]")}
	scanner:=bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte,256),256)
	c:=console{ctx,scanner}
	switch args[0]{
	case "identity-init","identity-show","peer-add","peer-list","peer-revoke":return manageTrust(c,args[0],args[1:])
	case "send":return sender(ctx,c,args[1:])
	case "receive":return receiver(ctx,c,args[1:])
	case "discover":
		f:=flags("discover")
		local:=f.String("bind","","local interface IP")
		if err:=noExtra(f,args[1:]);err!=nil{return err}
		b,err:=bindLocal(*local)
		if err!=nil{return err}
		return discover(ctx,b)
	default:return errors.New("unknown operation")
	}
}

func main(){
	ctx,cancel:=signal.NotifyContext(context.Background(),os.Interrupt)
	defer cancel()
	managed,args,closeManaged,err:=managedContext(ctx,os.Args[1:])
	if err==nil{
		err=run(managed,args)
	}
	closeManaged()
	if err!=nil{
		fmt.Fprintln(os.Stderr,"Pulse Share:",err)
		os.Exit(1)
	}
}
