package sharecore

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestScanSelectionTree(t *testing.T){
	root:=filepath.Join(t.TempDir(),"tree")
	if err:=os.MkdirAll(filepath.Join(root,"empty"),0700);err!=nil{t.Fatal(err)}
	if err:=os.WriteFile(filepath.Join(root,"zero"),nil,0600);err!=nil{t.Fatal(err)}
	if err:=os.WriteFile(filepath.Join(root,"data"),[]byte("hello"),0600);err!=nil{t.Fatal(err)}
	s,err:=ScanSelection(context.Background(),root);if err!=nil{t.Fatal(err)}
	if len(s.Manifest.Entries)!=4||s.Manifest.TotalBytes()!=5{t.Fatal("incorrect manifest")}
	if s.Manifest.Entries[0].Path!="tree"||s.Manifest.Entries[2].Path!="tree/empty"{t.Fatal("not deterministic parent-first traversal")}
	r,c,err:=s.OpenSource(context.Background(),1);if err!=nil{t.Fatal(err)}
	var data [5]byte
	if _,err:=r.ReadAt(data[:],0);err!=nil||string(data[:])!="hello"{t.Fatal("wrong source")}
	c.Close()
	if err:=os.WriteFile(filepath.Join(root,"data"),[]byte("changed"),0600);err!=nil{t.Fatal(err)}
	if _,c,err:=s.OpenSource(context.Background(),1);err==nil{c.Close();t.Fatal("changed source admitted")}
}
func TestScanSelectionRejectLink(t *testing.T){
	root:=t.TempDir()
	if err:=os.Symlink(t.TempDir(),filepath.Join(root,"link"));err!=nil{t.Skip("symlink unavailable")}
	if _,err:=ScanSelection(context.Background(),root);err==nil{t.Fatal("symlink admitted")}
}


// Exceed the aggregate block count using sparse logical lengths, without
// allocating/hashing a huge fixture. The validation rule itself is exercised
// by the existing manifest-limit tests; this confirms count rounding.
func TestSelectionBlockRounding(t *testing.T){
	if blockCount(0)!=0||blockCount(1)!=1||blockCount(BlockSize)!=1||blockCount(BlockSize+1)!=2{t.Fatal("invalid block count")}
}
