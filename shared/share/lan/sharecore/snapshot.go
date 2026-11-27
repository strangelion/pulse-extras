package sharecore

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Snapshot is an explicitly chosen ordinary file or directory tree.
// It retains local metadata only; source paths never appear in the wire
// manifest. Host adapters must audit ancestors and private local policy.
type Snapshot struct{
	Manifest Manifest
	root string
	items []snapshotItem
}
type snapshotItem struct{path string;info os.FileInfo}
type pendingEntry struct{absolute,relative string}

// ScanSelection uses an explicit bounded DFS stack and chunked directory
// enumeration. Reject rather than omit unsupported entries. No publication,
// network access, or remote path resolution occurs here.
func ScanSelection(ctx context.Context,root string)(*Snapshot,error){
	if !filepath.IsAbs(root){return nil,errors.New("absolute selection required")}
	root=filepath.Clean(root)
	leaf:=filepath.Base(root)
	if !validLeaf(leaf){return nil,errors.New("invalid selected root name")}
	s:=&Snapshot{root:root}
	pending:=[]pendingEntry{{root,leaf}}
	var total uint64
	for len(pending)>0{
		if err:=ctx.Err();err!=nil{return nil,err}
		last:=len(pending)-1;item:=pending[last];pending=pending[:last]
		if !validPath(item.relative)||len(s.items)>=MaxEntries{return nil,errors.New("selection exceeds manifest limits")}
		info,err:=os.Lstat(item.absolute);if err!=nil{return nil,err}
		if !ordinaryInfo(info,info.IsDir()){return nil,errors.New("unsupported source entry")}
		s.items=append(s.items,snapshotItem{item.absolute,info})
		if info.IsDir(){
			s.Manifest.Entries=append(s.Manifest.Entries,Entry{Path:item.relative,Directory:true})
			f,err:=os.Open(item.absolute);if err!=nil{return nil,err}
			opened,err:=f.Stat()
			if err!=nil||!ordinaryInfo(opened,true)||!os.SameFile(info,opened){f.Close();return nil,errors.New("source directory changed")}
			var names []string
			for{
				entries,e:=f.ReadDir(64)
				for _,child:=range entries{
					if !validLeaf(child.Name())||len(names)+len(pending)+len(s.items)>=MaxEntries{f.Close();return nil,errors.New("directory entry limit or unsupported name")}
					names=append(names,child.Name())
				}
				if e==io.EOF{break};if e!=nil{f.Close();return nil,e}
				if err:=ctx.Err();err!=nil{f.Close();return nil,err}
			}
			if err:=f.Close();err!=nil{return nil,err}
			sort.Strings(names)
			for i:=len(names)-1;i>=0;i--{
				pending=append(pending,pendingEntry{filepath.Join(item.absolute,names[i]),item.relative+"/"+names[i]})
			}
			continue
		}
		if info.Size()<0||uint64(info.Size())>MaxBytes-total{return nil,errors.New("selection byte limit exceeded")}
		total+=uint64(info.Size())
		f,err:=openOrdinary(item.absolute,os.O_RDONLY);if err!=nil{return nil,err}
		opened,err:=f.Stat()
		if err!=nil||!os.SameFile(info,opened)||opened.Size()!=info.Size(){f.Close();return nil,errors.New("source file changed")}
		e,err:=InspectFile(ctx,item.relative,uint64(info.Size()),f)
		after,statErr:=f.Stat()
		err=errors.Join(err,statErr,f.Close())
		if err!=nil{return nil,err}
		if after.Size()!=info.Size()||!after.ModTime().Equal(info.ModTime()){return nil,errors.New("source changed during hashing")}
		s.Manifest.Entries=append(s.Manifest.Entries,e)
	}
	if err:=s.Manifest.Validate();err!=nil{return nil,err}
	return s,nil
}

// OpenSource checks every traversed component against the snapshot metadata
// and the final opened file identity. The sender independently checks each
// block digest. This is not a sandbox against hostile same-user path races.
func(s *Snapshot) OpenSource(ctx context.Context,index uint32)(io.ReaderAt,io.Closer,error){
	if err:=ctx.Err();err!=nil{return nil,nil,err}
	if uint64(index)>=uint64(len(s.items)){return nil,nil,errors.New("invalid source index")}
	item:=s.items[index]
	if item.info.IsDir(){return nil,nil,errors.New("source is directory")}
	relative,err:=filepath.Rel(s.root,item.path);if err!=nil||relative==".."||strings.HasPrefix(relative,".."+string(filepath.Separator)){return nil,nil,errors.New("source escaped root")}
	for _,ancestor:=range s.items{
		if !ancestor.info.IsDir(){continue}
		rel,err:=filepath.Rel(ancestor.path,item.path)
		if err!=nil||rel==".."||strings.HasPrefix(rel,".."+string(filepath.Separator)){continue}
		info,err:=ordinary(ancestor.path,true)
		if err!=nil||!os.SameFile(info,ancestor.info){return nil,nil,errors.New("source ancestor changed")}
	}
	f,err:=openOrdinary(item.path,os.O_RDONLY);if err!=nil{return nil,nil,err}
	info,err:=f.Stat()
	if err!=nil||!os.SameFile(info,item.info)||info.Size()!=item.info.Size()||!info.ModTime().Equal(item.info.ModTime()){
		f.Close();return nil,nil,errors.New("source identity changed")
	}
	return f,f,nil
}
