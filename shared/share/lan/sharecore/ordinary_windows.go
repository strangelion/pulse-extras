//go:build windows

package sharecore

import (
	"os"
	"syscall"
)

func ordinaryInfo(info os.FileInfo,dir bool)bool{
	raw,ok:=info.Sys().(*syscall.Win32FileAttributeData)
	if !ok||raw.FileAttributes&syscall.FILE_ATTRIBUTE_REPARSE_POINT!=0{return false}
	if dir{return info.IsDir()&&info.Mode()&os.ModeSymlink==0}
	return info.Mode().IsRegular()
}
