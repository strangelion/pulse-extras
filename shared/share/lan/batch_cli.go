package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"strings"

	"pulse-extras/share-lan/sharecore"
)

func batchGrant(ctx context.Context,store,label string,id identity,pin [32]byte)error{
	if err:=ctx.Err();err!=nil{return err}
	root,err:=storeRoot(store);if err!=nil{return err}
	if isManaged(ctx){if err:=auditPrivateDirectory(root);err!=nil{return err}}
	now,err:=loadPeer(root,label);if err!=nil{return err}
	if now!=pin{return errors.New("saved peer changed")}
	current,err:=loadStoredIdentity(root);if err!=nil{return err}
	if current.pin!=id.pin{return errors.New("local identity changed")}
	return nil
}
func scanBatch(ctx context.Context,paths []string)(batchSource,error){
	if len(paths)==0||len(paths)>64{return batchSource{},errors.New("select 1 to 64 local roots")}
	var scans []*sharecore.Snapshot
	var starts []int
	m:=sharecore.Manifest{}
	var total,blocks uint64
	for _,path:=range paths{
		if err:=auditBatchSource(path);err!=nil{return batchSource{},err}
		s,err:=sharecore.ScanSelection(ctx,path);if err!=nil{return batchSource{},err}
		if len(s.Manifest.Entries)>sharecore.MaxEntries-len(m.Entries){return batchSource{},errors.New("batch entry limit")}
		for _,e:=range s.Manifest.Entries{
			if e.Size>sharecore.MaxBytes-total||uint64(len(e.Blocks))>sharecore.MaxBlocks-blocks{return batchSource{},errors.New("aggregate batch byte/block limit")}
			total+=e.Size;blocks+=uint64(len(e.Blocks))
		}
		starts=append(starts,len(m.Entries));scans=append(scans,s)
		m.Entries=append(m.Entries,s.Manifest.Entries...)
		if len(m.Entries)>sharecore.MaxEntries{return batchSource{},errors.New("batch entry limit")}
	}
	if err:=m.Validate();err!=nil{return batchSource{},err}
	return batchSource{m,func(ctx context.Context,i uint32)(io.ReaderAt,io.Closer,error){
		if uint64(i)>=uint64(len(m.Entries)){return nil,nil,errors.New("invalid source index")}
		for j:=len(starts)-1;j>=0;j--{if int(i)>=starts[j]{return scans[j].OpenSource(ctx,i-uint32(starts[j]))}}
		return nil,nil,errors.New("invalid source index")
	}},nil
}
func batchChannelLimit(n int)(int,bool,error){
	if n==0{return sharecore.MaxChannels,true,nil}
	if n<1||n>sharecore.MaxChannels{return 0,false,errors.New("channels must be 0 (adaptive) or 1..32")}
	return n,false,nil
}
func makeClipboardSource(ctx context.Context,store,kind string)(batchSource,sharecore.ContentKind,func(),error){
	c,err:=readLocalClipboard(kind);if err!=nil{return batchSource{},0,nil,err}
	if c.kind==sharecore.ClipboardFiles{
		s,err:=scanBatch(ctx,c.paths);return s,c.kind,func(){},err
	}
	defer clear(c.data)
	if err:=auditPrivateDirectory(store);err!=nil{return batchSource{},0,nil,err}
	var nonce [12]byte;if _,err:=rand.Read(nonce[:]);err!=nil{return batchSource{},0,nil,err}
	dir:=filepath.Join(store,fmt.Sprintf("clipboard-%x",nonce))
	if err:=createPrivateDirectory(dir);err!=nil{return batchSource{},0,nil,err}
	leaf:="clipboard.txt";if c.kind==sharecore.ClipboardImage{leaf="clipboard.bmp"}
	path:=filepath.Join(dir,leaf)
	clean:=func(){_ = os.Remove(path);_ = os.Remove(dir)}
	f,err:=os.OpenFile(path,os.O_CREATE|os.O_EXCL|os.O_WRONLY,0600)
	if err!=nil{clean();return batchSource{},0,nil,err}
	err=writeAll(f,c.data);if err==nil{err=f.Sync()};err=errors.Join(err,f.Close())
	if err!=nil{clean();return batchSource{},0,nil,err}
	s,err:=scanBatch(ctx,[]string{path});if err!=nil{clean();return batchSource{},0,nil,err}
	return s,c.kind,clean,nil
}
func sendBatchCLI(ctx context.Context,c console,b binding,addr netip.AddrPort,store,label,source,sources,clip string,browse,quic bool,channels int)error{
	if store==""||label==""{return errors.New("batch requires a saved peer")}
	limit,_,err:=batchChannelLimit(channels);if err!=nil{return err}
	id,pin,err:=sessionIdentity(c,store,label);if err!=nil{return err}
	check:=func(ctx context.Context)error{return batchGrant(ctx,store,label,id,pin)}
	if err:=check(ctx);err!=nil{return err}
	var s batchSource
	kind:=sharecore.Files
	if clip!=""{
		if source!=""||sources!=""||browse{return errors.New("clipboard and filesystem selection are separate")}
		var clean func()
		s,kind,clean,err=makeClipboardSource(ctx,store,clip)
		if clean!=nil{defer clean()}
	}else{
		if source!=""&&sources!=""{return errors.New("select source or sources, not both")}
		selected:=[]string{source}
		if sources!=""{selected=strings.Split(sources,"|")}
		s,err=scanBatch(ctx,selected)
		if browse{kind=sharecore.RemoteDirectory}
	}
	if err!=nil{return err}
	if browse{
		if len(s.m.Entries)==0||!s.m.Entries[0].Directory{return errors.New("select one directory to offer read-only")}
		roots:=0;for _,e:=range s.m.Entries{if !strings.Contains(e.Path,"/"){roots++}}
		if roots!=1{return errors.New("browse requires one root")}
	}
	link,err:=openBatchSender(ctx,b,addr,id,pin,quic);if err!=nil{return err};defer link.close()
	if err:=batchSend(ctx,link,s,kind,pin,limit,check);err!=nil{return err}
	fmt.Println("COMPLETED batch session");return nil
}
func receiveBatchCLI(ctx context.Context,c console,b binding,port uint16,store,label string,native nativeCommit,o batchReceiveOptions,delivery string,quic bool)error{
	if store==""||label==""{return errors.New("batch requires a saved peer")}
	limit,adaptive,err:=batchChannelLimit(o.channels);if err!=nil{return err};o.channels=limit;o.adaptive=adaptive
	if err:=auditPrivateDirectory(o.spool);err!=nil{return err}
	if o.resume!=""{
		if !filepath.IsAbs(o.resume)||!equalLocalPath(filepath.Dir(o.resume),o.spool){return errors.New("resume must select a direct child of the private spool")}
		if err:=auditBatchSource(o.resume);err!=nil{return err}
	}
	if delivery!="folder"&&delivery!="clipboard"{return errors.New("delivery must be folder or clipboard; host shelf write API unavailable")}
	if delivery=="clipboard"&&!o.allowClipboard{return errors.New("explicit clipboard receive required")}
	if o.clipboardType!=""&&(!o.allowClipboard||(o.clipboardType!="text"&&o.clipboardType!="image"&&o.clipboardType!="files")){return errors.New("invalid clipboard receive type")}
	seq:=uint32(0);if delivery=="clipboard"{seq,err=localClipboardSequence();if err!=nil{return err}}
	id,pin,err:=sessionIdentity(c,store,label);if err!=nil{return err}
	check:=func(ctx context.Context)error{return batchGrant(ctx,store,label,id,pin)}
	if err:=check(ctx);err!=nil{return err}
	var link *batchLink
	if o.connect.IsValid(){link,err=openBatchSender(ctx,b,o.connect,id,pin,quic)}else{
		link,err=openBatchReceiver(ctx,b,port,id,pin,quic,func(s string){fmt.Println("LISTEN",s)})
	}
	if err!=nil{return err};defer link.close()
	approve:=func(m sharecore.Manifest,kind sharecore.ContentKind)(bool,error){
		if err:=validateBatchContent(m,kind);err!=nil{return false,err}
		wire,err:=m.Encode();if err!=nil{return false,err}
		line,err:=c.prompt(fmt.Sprintf("OFFER batch kind=%d entries=%d bytes=%d manifest=%x destination=%s; accept? Enter yes:",kind,len(m.Entries),m.TotalBytes(),sha256.Sum256(wire),delivery))
		return line=="yes",err
	}
	pub:=func(ctx context.Context,s *sharecore.Stage,m sharecore.Manifest,k sharecore.ContentKind)error{
		return publishBatch(ctx,s,m,k,native,delivery,seq)
	}
	if err:=batchReceive(ctx,link,o,pin,check,approve,pub);err!=nil{return err}
	if !o.browse||o.remotePath!=""{fmt.Println("COMPLETED local batch committed")}
	return nil
}

func validateBatchContent(m sharecore.Manifest,kind sharecore.ContentKind)error{
	if err:=m.Validate();err!=nil{return err}
	roots:=0;for _,e:=range m.Entries{if !strings.Contains(e.Path,"/"){roots++}}
	if roots<1||roots>64{return errors.New("batch root limit")}
	if kind==sharecore.ClipboardText||kind==sharecore.ClipboardImage{
		leaf,limit:="clipboard.txt",uint64(maxClipboardText)
		if kind==sharecore.ClipboardImage{leaf,limit="clipboard.bmp",uint64(maxClipboardImage)}
		if len(m.Entries)!=1||m.Entries[0].Directory||m.Entries[0].Path!=leaf||m.Entries[0].Size>limit{
			return errors.New("invalid clipboard manifest")
		}
	}
	return nil
}
