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
	sddl, err := syscall.UTF16PtrFromString("D:P(A;OICI;FA;;;"+sid+")")
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
