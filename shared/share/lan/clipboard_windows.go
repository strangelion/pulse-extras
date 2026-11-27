//go:build windows

package main

import (
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
	"unicode/utf16"
	"unsafe"

	"pulse-extras/share-lan/sharecore"
)

var clipboardUser32=syscall.NewLazyDLL("user32.dll")
var clipboardShell32=syscall.NewLazyDLL("shell32.dll")
var clipOpen=clipboardUser32.NewProc("OpenClipboard")
var clipClose=clipboardUser32.NewProc("CloseClipboard")
var clipGet=clipboardUser32.NewProc("GetClipboardData")
var clipSet=clipboardUser32.NewProc("SetClipboardData")
var clipEmpty=clipboardUser32.NewProc("EmptyClipboard")
var clipSequence=clipboardUser32.NewProc("GetClipboardSequenceNumber")
var clipWindow=clipboardUser32.NewProc("CreateWindowExW")
var clipDestroy=clipboardUser32.NewProc("DestroyWindow")
var clipQuery=clipboardShell32.NewProc("DragQueryFileW")
var clipSize=kernel32.NewProc("GlobalSize")
var clipLock=kernel32.NewProc("GlobalLock")
var clipUnlock=kernel32.NewProc("GlobalUnlock")
var clipAlloc=kernel32.NewProc("GlobalAlloc")
var clipFree=kernel32.NewProc("GlobalFree")
const cfUnicode=13
const cfDIB=8
const cfHDrop=15

func localClipboardSequence()(uint32,error){
	n,_,_:=clipSequence.Call();if n==0{return 0,errors.New("clipboard sequence unavailable")};return uint32(n),nil
}
func withClipboard(write bool,fn func()error)error{
	runtime.LockOSThread();defer runtime.UnlockOSThread()
	var hwnd uintptr
	if write{
		class,_:=syscall.UTF16PtrFromString("STATIC")
		h,_,err:=clipWindow.Call(0,uintptr(unsafe.Pointer(class)),0,0,0,0,0,0,^uintptr(2),0,0,0)
		if h==0{return err};hwnd=h;defer clipDestroy.Call(hwnd)
	}
	if ok,_,err:=clipOpen.Call(hwnd);ok==0{return err}
	defer clipClose.Call()
	return fn()
}
func clipboardBytes(format uintptr,max uintptr)([]byte,error){
	h,_,_:=clipGet.Call(format);if h==0{return nil,errors.New("requested clipboard format unavailable")}
	n,_,_:=clipSize.Call(h);if n==0||n>max{return nil,errors.New("clipboard format exceeds size limit")}
	p,_,err:=clipLock.Call(h);if p==0{return nil,err};defer clipUnlock.Call(h)
	return append([]byte(nil),unsafe.Slice((*byte)(unsafe.Pointer(p)),int(n))...),nil
}
func readLocalClipboard(kind string)(clipboardPayload,error){
	var out clipboardPayload
	err:=withClipboard(false,func()error{
		switch kind{
		case "text":
			b,err:=clipboardBytes(cfUnicode,2*maxClipboardText+2);if err!=nil{return err};defer clear(b)
			out.kind=sharecore.ClipboardText;out.data,err=decodeClipboardText(b);return err
		case "image":
			b,err:=clipboardBytes(cfDIB,maxClipboardImage);if err!=nil{return err};defer clear(b)
			out.kind=sharecore.ClipboardImage;out.data,err=bmpFromDIB(b);return err
		case "files":
			h,_,_:=clipGet.Call(cfHDrop);if h==0{return errors.New("clipboard has no file references")}
			n,_,_:=clipQuery.Call(h,0xffffffff,0,0)
			if n==0||n>64{return errors.New("clipboard file selection exceeds 64 roots")}
			for i:=uintptr(0);i<n;i++{
				length,_,_:=clipQuery.Call(h,i,0,0);if length==0||length>32766{return errors.New("invalid clipboard file path")}
				buf:=make([]uint16,int(length)+1)
				got,_,_:=clipQuery.Call(h,i,uintptr(unsafe.Pointer(&buf[0])),uintptr(len(buf)))
				if got!=length{return errors.New("clipboard file path changed")}
				path:=syscall.UTF16ToString(buf);if !filepath.IsAbs(path){return errors.New("nonlocal clipboard path")}
				out.paths=append(out.paths,path)
			}
			out.kind=sharecore.ClipboardFiles;return nil
		default:return errors.New("clipboard type must be text, image or files")
		}
	})
	return out,err
}
func clipboardDropBytes(paths []string)([]byte,error){
	if len(paths)==0||len(paths)>64{return nil,errors.New("invalid local file references")}
	u:=make([]uint16,0)
	for _,p:=range paths{
		if !filepath.IsAbs(p){return nil,errors.New("absolute local file required")}
		if _,err:=os.Lstat(p);err!=nil{return nil,err}
		v:=utf16.Encode([]rune(p));if len(v)>32766||len(u)+len(v)>maxClipboardText/2{return nil,errors.New("clipboard file reference limit")}
		u=append(u,v...);u=append(u,0)
	}
	u=append(u,0)
	b:=make([]byte,20+len(u)*2)
	binary.LittleEndian.PutUint32(b,20);binary.LittleEndian.PutUint32(b[16:],1)
	for i,v:=range u{binary.LittleEndian.PutUint16(b[20+i*2:],v)}
	return b,nil
}
func writeLocalClipboard(kind sharecore.ContentKind,data []byte,paths []string,sequence uint32)error{
	var format uintptr;var b []byte;var err error
	switch kind{
	case sharecore.ClipboardText:format=cfUnicode;b,err=encodeClipboardText(data)
	case sharecore.ClipboardImage:format=cfDIB;b,err=dibFromBMP(data)
	case sharecore.ClipboardFiles:format=cfHDrop;b,err=clipboardDropBytes(paths)
	default:return errors.New("unsupported clipboard destination")
	}
	if err!=nil{return err};defer clear(b)
	h,_,err:=clipAlloc.Call(2,uintptr(len(b)));if h==0{return err}
	owned:=true;defer func(){if owned{clipFree.Call(h)}}()
	p,_,err:=clipLock.Call(h);if p==0{return err}
	copy(unsafe.Slice((*byte)(unsafe.Pointer(p)),len(b)),b);clipUnlock.Call(h)
	return withClipboard(true,func()error{
		current,err:=localClipboardSequence();if err!=nil{return err}
		if current!=sequence{return errors.New("local clipboard changed during transfer; refusing overwrite")}
		if ok,_,err:=clipEmpty.Call();ok==0{return err}
		if ok,_,err:=clipSet.Call(format,h);ok==0{return err}
		owned=false;return nil
	})
}
