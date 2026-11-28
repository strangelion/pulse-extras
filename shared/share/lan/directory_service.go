package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"pulse-extras/share-lan/sharecore"
)

func directoryServiceCLI(ctx context.Context,c console,b binding,port uint16,store,label,source string,quic bool,channels int)error{
	if port==0{return errors.New("directory service requires a fixed port")}
	if store==""||label==""||source==""||strings.Contains(source,"|"){return errors.New("directory service requires one selected directory and saved peer")}
	if err:=auditBatchSource(source);err!=nil{return err}
	root:=filepath.Clean(source)
	info,err:=os.Lstat(root);if err!=nil{return err};if !info.IsDir(){return errors.New("select a directory")}
	limit,_,err:=batchChannelLimit(channels);if err!=nil{return err}
	id,pin,err:=sessionIdentity(c,store,label);if err!=nil{return err}
	check:=func(ctx context.Context)error{
		if err:=batchGrant(ctx,store,label,id,pin);err!=nil{return err}
		if err:=auditBatchSource(root);err!=nil{return err}
		now,err:=os.Lstat(root);if err!=nil{return err}
		if !os.SameFile(info,now)||!now.IsDir(){return errors.New("approved root changed")}
		return nil
	}
	answer,err:=c.prompt(fmt.Sprintf("OFFER expose read-only selected directory %q to saved peer %x until cancelled? Enter yes:",root,pin))
	if err!=nil{return err};if answer!="yes"{return errors.New("directory service declined")}
	for{
		if err:=check(ctx);err!=nil{return err}
		link,err:=openBatchReceiver(ctx,b,port,id,pin,quic,func(s string){fmt.Println("LISTEN",s)})
		if err==nil{
			// Rebuild the manifest for each authenticated session, but keep
			// root identity pinned. No remote filesystem path is resolved.
			s,scanErr:=scanBatch(ctx,[]string{root})
			if scanErr!=nil{link.close();return scanErr}
			err=batchSend(ctx,link,s,sharecore.RemoteDirectory,pin,limit,check)
			link.close()
			if err==nil{fmt.Println("DIRECTORY session complete; service remains active")}
		}
		if ctx.Err()!=nil{return ctx.Err()}
		if err:=check(ctx);err!=nil{return err}
		if err!=nil{fmt.Println("DIRECTORY session ended; retrying listener")}
		// Bound retries even when bind fails or an incompatible client connects.
		timer:=time.NewTimer(time.Second)
		select{case <-ctx.Done():timer.Stop();return ctx.Err();case <-timer.C:}
	}
}
