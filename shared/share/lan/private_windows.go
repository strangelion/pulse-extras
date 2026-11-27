//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
	"unsafe"
)

var advapi = syscall.NewLazyDLL("advapi32.dll")
var convertSD = advapi.NewProc("ConvertStringSecurityDescriptorToSecurityDescriptorW")
var createDir = kernel32.NewProc("CreateDirectoryW")
var attrsW = kernel32.NewProc("GetFileAttributesW")

type securityAttributes struct {
	length uint32
	descriptor uintptr
	inherit uint32
}

// Create only a new directory with a protected current-user DACL. Never
// change permissions on an existing directory or follow a selected junction.
func createPrivateDirectory(path string) error {
	if !filepath.IsAbs(path) || len(filepath.VolumeName(path)) != 2 {
		return errors.New("choose a new absolute local directory")
	}
	path = filepath.Clean(path)
	parent := filepath.Dir(path)
	info, err := os.Lstat(parent)
	if err != nil { return err }
	if !info.IsDir() { return errors.New("parent must be an existing local directory") }
	canonical, err := filepath.EvalSymlinks(parent)
	if err != nil { return err }
	if !equalLocalPath(canonical,parent) { return errors.New("parent must not resolve through a reparse point") }
	parentW, err := syscall.UTF16PtrFromString(parent)
	if err != nil { return err }
	attrs, _, err := attrsW.Call(uintptr(unsafe.Pointer(parentW)))
	if uint32(attrs) == ^uint32(0) { return err }
	if attrs & 0x400 != 0 { return errors.New("reparse parent not supported") }
	token, err := syscall.OpenCurrentProcessToken()
	if err != nil { return err }
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil { return err }
	sid, err := user.User.Sid.String()
	if err != nil { return err }
	sddl, err := syscall.UTF16PtrFromString("O:"+sid+"D:P(A;OICI;FA;;;"+sid+")")
	if err != nil { return err }
	var descriptor uintptr
	ok, _, err := convertSD.Call(uintptr(unsafe.Pointer(sddl)),1,uintptr(unsafe.Pointer(&descriptor)),0)
	if ok == 0 { return err }
	defer localFree.Call(descriptor)
	sa := securityAttributes{uint32(unsafe.Sizeof(securityAttributes{})),descriptor,0}
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil { return err }
	ok, _, err = createDir.Call(uintptr(unsafe.Pointer(name)),uintptr(unsafe.Pointer(&sa)))
	runtime.KeepAlive(sa)
	runtime.KeepAlive(name)
	if ok == 0 { return err }
	fmt.Println("PRIVATE DIRECTORY CREATED", path)
	return nil
}


// Require the protected current-user directory policy created by private-init.
// This is an admission check, not a hostile same-user containment boundary.
var namedSecurity = advapi.NewProc("GetNamedSecurityInfoW")
var descriptorControl = advapi.NewProc("GetSecurityDescriptorControl")
var aclInformation = advapi.NewProc("GetAclInformation")
var getACE = advapi.NewProc("GetAce")
var equalSID = advapi.NewProc("EqualSid")
var validSID = advapi.NewProc("IsValidSid")
var lengthSID = advapi.NewProc("GetLengthSid")

func auditPrivateDirectory(path string)error{
	reject:=errors.New("managed mode requires a protected current-user private directory; use private-init with a new path")
	if !filepath.IsAbs(path) || len(filepath.VolumeName(path))!=2{return reject}
	path=filepath.Clean(path)
	canonical,err:=filepath.EvalSymlinks(path)
	if err!=nil || !equalLocalPath(canonical,path){return reject}
	w,err:=syscall.UTF16PtrFromString(path)
	if err!=nil{return err}
	attrs,_,_:=attrsW.Call(uintptr(unsafe.Pointer(w)))
	if uint32(attrs)==^uint32(0) || attrs&0x10==0 || attrs&0x400!=0{return reject}
	token,err:=syscall.OpenCurrentProcessToken()
	if err!=nil{return err}
	defer token.Close()
	user,err:=token.GetTokenUser()
	if err!=nil{return err}
	var owner,dacl,sd unsafe.Pointer
	status,_,_:=namedSecurity.Call(uintptr(unsafe.Pointer(w)),1,5,uintptr(unsafe.Pointer(&owner)),0,uintptr(unsafe.Pointer(&dacl)),0,uintptr(unsafe.Pointer(&sd)))
	if sd!=nil{defer localFree.Call(uintptr(sd))}
	if status!=0{return syscall.Errno(status)}
	if sd==nil || dacl==nil || owner==nil{return reject}
	var control uint16
	var revision uint32
	ok,_,_:=descriptorControl.Call(uintptr(sd),uintptr(unsafe.Pointer(&control)),uintptr(unsafe.Pointer(&revision)))
	if ok==0 || control&0x1000==0{return reject}
	sid:=uintptr(unsafe.Pointer(user.User.Sid))
	ok,_,_=equalSID.Call(uintptr(owner),sid)
	if ok==0{return reject}
	var info [3]uint32
	ok,_,_=aclInformation.Call(uintptr(dacl),uintptr(unsafe.Pointer(&info[0])),12,2)
	if ok==0 || info[0]!=1{return reject}
	var ace unsafe.Pointer
	ok,_,_=getACE.Call(uintptr(dacl),0,uintptr(unsafe.Pointer(&ace)))
	if ok==0 || ace==nil{return reject}
	header:=unsafe.Slice((*byte)(ace),8)
	size:=uint32(header[2])|uint32(header[3])<<8
	mask:=uint32(header[4])|uint32(header[5])<<8|uint32(header[6])<<16|uint32(header[7])<<24
	if header[0]!=0 || header[1]!=3 || size<16 || size>76 || mask!=0x1f01ff{return reject}
	aceSID:=uintptr(unsafe.Add(ace,8))
	ok,_,_=validSID.Call(aceSID)
	if ok==0{return reject}
	n,_,_:=lengthSID.Call(aceSID)
	if n!=uintptr(size-8){return reject}
	ok,_,_=equalSID.Call(aceSID,sid)
	runtime.KeepAlive(user)
	if ok==0{return reject}
	return nil
}
