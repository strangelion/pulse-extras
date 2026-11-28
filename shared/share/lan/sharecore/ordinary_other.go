//go:build !windows

package sharecore

import "os"

func ordinaryInfo(info os.FileInfo,dir bool)bool{
	if dir{return info.IsDir()&&info.Mode()&os.ModeSymlink==0}
	return info.Mode().IsRegular()
}
