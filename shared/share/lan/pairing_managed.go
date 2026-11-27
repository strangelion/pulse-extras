package main

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"path/filepath"
	"sync/atomic"
	"time"
)

// This command is intended for the native managed supervisor only.
// The supervisor pins the exact sibling helper executable and holds the
// handle until the job drains. Never accept a helper path from UI input.
// Private PAIRCODE/PAIRINPUT records are consumed by the supervisor and
// must not be forwarded to host progress, logs, history or settings.
func managedPair(c console, mode string,args []string)error{
	if !isManaged(c.ctx){return errors.New("dynamic pairing requires the managed local supervisor")}
	f:=flags(mode)
	local:=f.String("bind","","local LAN or explicitly selected private overlay interface")
	routed:=f.Bool("routed",false,"explicit private overlay pairing")
	advert:=f.Bool("advertise",false,"opt-in LAN pairing endpoint discovery")
	source:=f.String("allowed-source","","exact private TCP source for overlay host")
	store:=f.String("store","","existing user-private identity store")
	label:=f.String("name","","local peer label")
	helper:=f.String("pake","","verified sibling helper path")
	port:=f.Uint("port",0,"local port")
	peer:=f.String("peer","","numeric pairing endpoint")
	if err:=noExtra(f,args);err!=nil{return err}
	if *advert&&(*routed||mode!="pair-host"){return errors.New("pair discovery is only available for LAN hosts")}
	if *port>65535||!filepath.IsAbs(*helper)||filepath.Base(*helper)!="pulse-share-pake.exe"{return errors.New("invalid managed pairing configuration")}
	root,err:=storeRoot(*store)
	if err!=nil{return err}
	if err=auditPrivateDirectory(root);err!=nil{return err}
	id,err:=loadStoredIdentity(root)
	if err!=nil{return err}
	b,err:=bindLocalMode(*local,*routed)
	if err!=nil{return err}
	if *routed{
		if !privatePairIP(b.ip){return errors.New("dynamic pairing requires a private or overlay address")}
		if mode=="pair-host"{
			if err:=b.setAllowedSource(*source);err!=nil{return err}
			if !privatePairIP(b.source){return errors.New("overlay pairing requires a private source")}
		}else{
			endpoint,err:=b.peer(*peer)
			if err!=nil{return err}
			if !privatePairIP(endpoint.Addr()){return errors.New("public dynamic pairing disabled; use independently verified fingerprints")}
		}
	}else if *source!=""{return errors.New("source requires routed mode")}
	p:=pairConfig{id:id,root:root,label:*label,helper:*helper,
		consent:func(ctx context.Context,pin [32]byte)(bool,error){
			// The scanner is only read here after authentication; no
			// overlapping prompt goroutines.
			prompt:=console{ctx:ctx,scanner:c.scanner}
			answer,err:=prompt.prompt(fmt.Sprintf("Trust %s authenticated fingerprint %x? Enter yes:",*label,pin))
			return answer=="yes",err
		}}
	var result pairResult
	if mode=="pair-host"{
		var lastEndpoint netip.AddrPort
		var visible atomic.Bool
		discoveryCtx,stopDiscovery:=context.WithCancel(c.ctx)
		defer stopDiscovery()
		var discoveryDone chan struct{}
		result,err=hostPair(c.ctx,b,uint16(*port),p,func(endpoint netip.AddrPort,code string,remaining time.Duration){
			if endpoint!=lastEndpoint{
				fmt.Println("LISTEN",endpoint)
				lastEndpoint=endpoint
				if *advert{
					discoveryDone=make(chan struct{})
					go func(port uint16){
						defer close(discoveryDone)
						if err:=advertiseRecord(discoveryCtx,b,pairingAnnouncement(port),visible.Load);err!=nil&&discoveryCtx.Err()==nil{
							// Do not replace the active consent prompt or expose codes.
							// Numeric endpoint remains available as a fallback.
						}
					}(endpoint.Port())
				}
			}
			visible.Store(code!="")
			if code==""{fmt.Println("PAIRCODE CLEAR");return}
			seconds:=int((remaining+time.Second-1)/time.Second)
			fmt.Printf("PAIRCODE %s %d\n",code,seconds)
		})
		stopDiscovery()
		if discoveryDone!=nil{<-discoveryDone}
	}else{
		// Private input is requested via stdin, never a process argument.
		line,readErr:=c.prompt("PAIRINPUT")
		if readErr!=nil{return readErr}
		secret:=[]byte(line)
		defer clear(secret)
		result,err=joinPair(c.ctx,b,*peer,p,secret)
	}
	if err!=nil{
		if errors.Is(err,errPairUncertain)||result.localWriteAttempted{
			return fmt.Errorf("enrollment incomplete: local saved=%t, peer report known=%t, peer reported saved=%t; inspect both stores",result.localSaved,result.peerReportKnown,result.peerReportedSaved)
		}
		return err
	}
	fmt.Printf("COMPLETED paired %s %x\n",*label,result.pin)
	return nil
}
