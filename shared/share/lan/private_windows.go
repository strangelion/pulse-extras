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
var driveTypeW = kernel32.NewProc("GetDriveTypeW")

type securityAttributes struct {
	length uint32
	descriptor uintptr
	inherit uint32
}

// Windows may expand an 8.3 DOS alias or normalize case when resolving
// an ordinary directory. A string difference is not evidence of a junction.
// Check every existing component explicitly before and after normalization;
// require the same directory identity and a fixed local drive. This is an
// admission check, not an atomic path lock against same-user mutations.
func plainDirectoryPath(path string) (string,error) {
	if !filepath.IsAbs(path) || len(filepath.VolumeName(path))!=2 || filepath.VolumeName(path)[1]!=':' {
		return "",errors.New("expected absolute local DOS directory")
	}
	path=filepath.Clean(path)
	check:=func(candidate string)error{
		volume:=filepath.VolumeName(candidate)
		if len(volume)!=2 || volume[1]!=':' || !filepath.IsAbs(candidate){
			return errors.New("expected absolute local DOS directory")
		}
		drive,err:=syscall.UTF16PtrFromString(volume+"\\")
		if err!=nil{return err}
		kind,_,_:=driveTypeW.Call(uintptr(unsafe.Pointer(drive)))
		if kind!=3{return errors.New("private directory requires a fixed local drive")}
		for current:=candidate;;current=filepath.Dir(current){
			w,err:=syscall.UTF16PtrFromString(current)
			if err!=nil{return err}
			attrs,_,err:=attrsW.Call(uintptr(unsafe.Pointer(w)))
			if uint32(attrs)==^uint32(0){return err}
			if attrs&0x10==0{return errors.New("expected an existing directory component")}
			if attrs&0x400!=0{return errors.New("reparse directory component not supported")}
			if filepath.Dir(current)==current{break}
		}
		return nil
	}
	if err:=check(path);err!=nil{return "",err}
	before,err:=os.Stat(path)
	if err!=nil{return "",err}
	canonical,err:=filepath.EvalSymlinks(path)
	if err!=nil{return "",err}
	canonical=filepath.Clean(canonical)
	if !equalLocalPath(filepath.VolumeName(path),filepath.VolumeName(canonical)){
		return "",errors.New("directory resolved to a different volume")
	}
	if err:=check(canonical);err!=nil{return "",err}
	after,err:=os.Stat(canonical)
	if err!=nil{return "",err}
	if !os.SameFile(before,after){return "",errors.New("directory identity changed during normalization")}
	return canonical,nil
}

// Create only a new directory with a protected current-user DACL. Never
// change permissions on an existing directory or follow a selected junction.
func createPrivateDirectory(path string) error {
	if !filepath.IsAbs(path) || len(filepath.VolumeName(path)) != 2 {
		return errors.New("choose a new absolute local directory")
	}
	path = filepath.Clean(path)
	leaf:=filepath.Base(path)
	if !validName(leaf){return errors.New("invalid private directory name")}
	parent,err:=plainDirectoryPath(filepath.Dir(path))
	if err!=nil{return err}
	path=filepath.Join(parent,leaf)
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
	path,err:=plainDirectoryPath(path)
	if err!=nil{return fmt.Errorf("private directory path rejected: %w",err)}
	w,err:=syscall.UTF16PtrFromString(path)
	if err!=nil{return err}
	token,err:=syscall.OpenCurrentProcessToken()
	if err!=nil{return err}
	defer token.Close()
	user,err:=token.GetTokenUser()
	if err!=nil{return err}
	var owner,dacl,sd unsafe.Pointer
	status,_,_:=namedSecurity.Call(uintptr(unsafe.Pointer(w)),1,5,uintptr(unsafe.Pointer(&owner)),0,uintptr(unsafe.Pointer(&dacl)),0,uintptr(unsafe.Pointer(&sd)))
	if sd!=nil{defer localFree.Call(uintptr(sd))}
	if status!=0{return syscall.Errno(status)}
	if sd==nil || dacl==nil || owner==nil{return fmt.Errorf("%w: missing security descriptor",reject)}
	var control uint16
	var revision uint32
	ok,_,_:=descriptorControl.Call(uintptr(sd),uintptr(unsafe.Pointer(&control)),uintptr(unsafe.Pointer(&revision)))
	if ok==0 || control&0x1000==0{return fmt.Errorf("%w: DACL not protected",reject)}
	sid:=uintptr(unsafe.Pointer(user.User.Sid))
	ok,_,_=equalSID.Call(uintptr(owner),sid)
	if ok==0{return fmt.Errorf("%w: owner mismatch",reject)}
	var info [3]uint32
	ok,_,_=aclInformation.Call(uintptr(dacl),uintptr(unsafe.Pointer(&info[0])),12,2)
	if ok==0 || info[0]!=1{return fmt.Errorf("%w: expected exactly one ACE",reject)}
	var ace unsafe.Pointer
	ok,_,_=getACE.Call(uintptr(dacl),0,uintptr(unsafe.Pointer(&ace)))
	if ok==0 || ace==nil{return reject}
	header:=unsafe.Slice((*byte)(ace),8)
	size:=uint32(header[2])|uint32(header[3])<<8
	mask:=uint32(header[4])|uint32(header[5])<<8|uint32(header[6])<<16|uint32(header[7])<<24
	if header[0]!=0 || header[1]!=3 || size<16 || size>76 || mask!=0x1f01ff{
		return fmt.Errorf("%w: unexpected ACE type, inheritance or access mask",reject)
	}
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
