//go:build windows

package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"pulse-extras/share-lan/sharecore"
)

var shareMutex=kernel32.NewProc("CreateMutexW")

// Managed device user has one transfer owner across processes and sessions.
func acquireTransferOwner()(func(),error){
	token,err:=syscall.OpenCurrentProcessToken();if err!=nil{return nil,err}
	defer token.Close()
	user,err:=token.GetTokenUser();if err!=nil{return nil,err}
	sid,err:=user.User.Sid.String();if err!=nil{return nil,err}
	name,err:=syscall.UTF16PtrFromString("Global\\PulseExtras.Share."+sid);if err!=nil{return nil,err}
	h,_,e:=shareMutex.Call(0,0,uintptr(unsafe.Pointer(name)))
	if h==0{return nil,e}
	if e==syscall.ERROR_ALREADY_EXISTS{syscall.CloseHandle(syscall.Handle(h));return nil,errors.New("another Share transfer owns this user")}
	return func(){syscall.CloseHandle(syscall.Handle(h))},nil
}
func auditBatchSource(path string)error{
	if !filepath.IsAbs(path){return errors.New("absolute local source required")}
	info,err:=os.Lstat(path);if err!=nil{return err}
	parent:=filepath.Dir(path);if info.IsDir(){parent=path}
	_,err=plainDirectoryPath(parent);return err
}
func moveBatchNoReplace(from,to string)error{
	a,err:=syscall.UTF16PtrFromString(from);if err!=nil{return err}
	b,err:=syscall.UTF16PtrFromString(to);if err!=nil{return err}
	return syscall.MoveFile(a,b)
}
func verifiedClipboardBytes(path string,e sharecore.Entry)([]byte,error){
	f,err:=openSource(path);if err!=nil{return nil,err};defer f.Close()
	b,err:=io.ReadAll(io.LimitReader(f,int64(e.Size)+1))
	if err!=nil||uint64(len(b))!=e.Size||sha256.Sum256(b)!=e.Hash{return nil,errors.New("clipboard payload changed")}
	return b,nil
}
func publishBatch(ctx context.Context,s *sharecore.Stage,m sharecore.Manifest,kind sharecore.ContentKind,native nativeCommit,delivery string,seq uint32)error{
	if err:=validateBatchContent(m,kind);err!=nil{return err}
	if delivery=="clipboard"&&(kind==sharecore.ClipboardText||kind==sharecore.ClipboardImage){
		return s.Seal(ctx,func(ctx context.Context,e sharecore.Entry,path string)error{
			if err:=ctx.Err();err!=nil{return err}
			b,err:=verifiedClipboardBytes(path,e);if err!=nil{return err};defer clear(b)
			return writeLocalClipboard(kind,b,nil,seq)
		})
	}
	dest,err:=plainDirectoryPath(native.destination);if err!=nil{return err}
	var roots []string
	for _,e:=range m.Entries{if !strings.Contains(e.Path,"/"){roots=append(roots,e.Path)}}
	if len(roots)==0{return errors.New("empty batch")}
	var paths []string
	if len(m.Entries)==1&&!m.Entries[0].Directory{
		native.destination=dest
		err=s.Seal(ctx,func(ctx context.Context,e sharecore.Entry,path string)error{
			native.ctx=ctx
			if kind==sharecore.ClipboardText||kind==sharecore.ClipboardImage{
				b,err:=verifiedClipboardBytes(path,e);if err!=nil{return err};defer clear(b)
				if kind==sharecore.ClipboardText{encoded,err:=encodeClipboardText(b);if err!=nil{return err};clear(encoded)}else{
					dib,err:=dibFromBMP(b);if err!=nil{return err};defer clear(dib)
					if !bytes.Equal(dib,b[14:]){return errors.New("noncanonical clipboard bitmap")}
				}
			}
			return native.commit(offer{e.Path,e.Size,e.Hash},path)
		})
		if err!=nil{return err}
		paths=[]string{filepath.Join(dest,roots[0])}
	}else{
		var nonce [12]byte;if _,err:=rand.Read(nonce[:]);err!=nil{return err}
		work:=filepath.Join(dest,fmt.Sprintf(".pulse-share-batch-%x",nonce))
		var final,from string
		if len(roots)==1{
			from=filepath.Join(work,roots[0]);final=filepath.Join(dest,roots[0])
			paths=[]string{final}
		}else{
			from=work;final=filepath.Join(dest,fmt.Sprintf("Received-%x",nonce))
			for _,r:=range roots{paths=append(paths,filepath.Join(final,r))}
		}
		if _,err:=os.Lstat(final);!os.IsNotExist(err){return errors.New("destination exists or cannot be checked")}
		if err:=createPrivateDirectory(work);err!=nil{return err}
		fmt.Printf("BATCH_PUBLISH_STAGE %s\n",work)
		index:=0
		err=s.Seal(ctx,func(ctx context.Context,e sharecore.Entry,path string)error{
			if err:=ctx.Err();err!=nil{return err}
			target:=filepath.Join(work,filepath.FromSlash(e.Path))
			parent,err:=plainDirectoryPath(filepath.Dir(target));if err!=nil{return err}
			rel,err:=filepath.Rel(work,parent)
			if err!=nil||rel==".."||strings.HasPrefix(rel,".."+string(filepath.Separator)){return errors.New("destination escaped staging root")}
			if e.Directory{
				if err:=os.Mkdir(target,0700);err!=nil{return err}
			}else{
				n:=native;n.ctx=ctx;n.destination=parent
				if err:=n.commit(offer{filepath.Base(target),e.Size,e.Hash},path);err!=nil{return err}
			}
			index++
			if index==len(m.Entries){
				if err:=ctx.Err();err!=nil{return err}
				if _,err:=plainDirectoryPath(dest);err!=nil{return err}
				if err:=moveBatchNoReplace(from,final);err!=nil{return err}
			}
			return nil
		})
		if err!=nil{return err}
		if from!=work{if err:=os.Remove(work);err!=nil{return fmt.Errorf("published, empty work directory cleanup: %w",err)}}
	}
	if delivery=="clipboard"{
		if err:=writeLocalClipboard(sharecore.ClipboardFiles,nil,paths,seq);err!=nil{return fmt.Errorf("files published; clipboard unchanged or uncertain: %w",err)}
	}
	return nil
}
