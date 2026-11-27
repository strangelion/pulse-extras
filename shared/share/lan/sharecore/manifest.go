// Package sharecore is the host-independent batch content/transfer core.
// Transport adapters must authenticate peers and obtain local consent before
// allocating a Stage or accepting data. This package does not grant access.
package sharecore

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"io"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	Version = 2
	BlockSize = 4 * 1024 * 1024
	BufferSize = 256 * 1024
	MaxChannels = 32
	MaxEntries = 4096
	MaxDepth = 32
	MaxPath = 1024
	MaxBytes = uint64(1) << 40
	MaxBlocks = 262144
	MaxManifest = 16 * 1024 * 1024
)

type Digest = [32]byte

type Entry struct {
	Path string
	Directory bool
	Size uint64
	Hash Digest
	Blocks []Digest
}

type Manifest struct {
	Entries []Entry
}

type Block struct {
	File uint32
	Index uint32
}

func blockCount(size uint64) uint64 {return (size+BlockSize-1)/BlockSize}

// The actual Windows publisher must still check opened identities and
// filesystem-specific aliases. Metadata is never used as a spool pathname.
func validLeaf(s string) bool {
	if len(s)==0||len(s)>240||!utf8.ValidString(s)||strings.HasSuffix(s,".")||strings.HasSuffix(s," ")||strings.ContainsAny(s,"\\/:*?\"<>|~"){return false}
	for _,r:=range s{if unicode.IsControl(r)||unicode.Is(unicode.Cf,r){return false}}
	stem:=strings.ToUpper(strings.TrimRight(strings.SplitN(s,".",2)[0]," "))
	switch stem{case "CON","PRN","AUX","NUL","CONIN$","CONOUT$":return false}
	r:=[]rune(stem)
	return !(len(r)==4&&(string(r[:3])=="COM"||string(r[:3])=="LPT")&&((r[3]>='0'&&r[3]<='9')||strings.ContainsRune("¹²³",r[3])))
}

func validPath(s string)bool{
	if len(s)==0||len(s)>MaxPath{return false}
	parts:=strings.Split(s,"/")
	if len(parts)>MaxDepth{return false}
	for _,p:=range parts{if !validLeaf(p){return false}}
	return true
}

// Validate requires ordered parent-before-child entries, explicit directory
// records, canonical slash-separated names and case-insensitive uniqueness.
func (m Manifest) Validate() error{
	if len(m.Entries)==0||len(m.Entries)>MaxEntries{return errors.New("invalid manifest entry count")}
	seen:=make(map[string]Entry,len(m.Entries))
	var total,blocks uint64
	for _,e:=range m.Entries{
		if !validPath(e.Path){return errors.New("invalid relative path")}
		key:=strings.ToUpper(e.Path)
		if _,ok:=seen[key];ok{return errors.New("duplicate or case-alias path")}
		if i:=strings.LastIndex(e.Path,"/");i>=0{
			parent,ok:=seen[strings.ToUpper(e.Path[:i])]
			if !ok||!parent.Directory||parent.Path!=e.Path[:i]{return errors.New("missing or ambiguous parent directory")}
		}
		if e.Directory{
			if e.Size!=0||e.Hash!=(Digest{})||len(e.Blocks)!=0{return errors.New("directory has file data")}
		}else{
			if e.Size>MaxBytes||total>MaxBytes-e.Size{return errors.New("manifest byte budget exceeded")}
			total+=e.Size
			n:=blockCount(e.Size)
			if uint64(len(e.Blocks))!=n||n>MaxBlocks-blocks{return errors.New("manifest block budget exceeded")}
			blocks+=n
			if e.Size==0&&e.Hash!=sha256.Sum256(nil){return errors.New("invalid empty file digest")}
		}
		seen[key]=e
	}
	return nil
}

func(m Manifest) TotalBytes()uint64{
	var n uint64
	for _,e:=range m.Entries{n+=e.Size}
	return n
}

func(m Manifest) blockInfo(b Block)(offset int64,size int,digest Digest,err error){
	if uint64(b.File)>=uint64(len(m.Entries)){err=errors.New("invalid file index");return}
	e:=m.Entries[b.File]
	if e.Directory||uint64(b.Index)>=uint64(len(e.Blocks)){err=errors.New("invalid block index");return}
	offset=int64(b.Index)*BlockSize
	size=int(min(uint64(BlockSize),e.Size-uint64(offset)))
	digest=e.Blocks[b.Index]
	return
}

// Canonical binary format, bounded before allocating. No JSON parser,
// implicit filenames or platform-dependent serialization on the wire.
func(m Manifest) Encode()([]byte,error){
	if err:=m.Validate();err!=nil{return nil,err}
	var buf bytes.Buffer
	buf.WriteString("PSM2")
	var b [8]byte
	binary.BigEndian.PutUint32(b[:4],uint32(len(m.Entries)));buf.Write(b[:4])
	for _,e:=range m.Entries{
		if e.Directory{buf.WriteByte(1)}else{buf.WriteByte(0)}
		binary.BigEndian.PutUint16(b[:2],uint16(len(e.Path)));buf.Write(b[:2])
		buf.WriteString(e.Path)
		binary.BigEndian.PutUint64(b[:],e.Size);buf.Write(b[:])
		buf.Write(e.Hash[:])
		binary.BigEndian.PutUint32(b[:4],uint32(len(e.Blocks)));buf.Write(b[:4])
		for _,hash:=range e.Blocks{buf.Write(hash[:])}
	}
	if buf.Len()>MaxManifest{return nil,errors.New("manifest encoding budget exceeded")}
	return buf.Bytes(),nil
}

func Decode(data []byte)(Manifest,error){
	var m Manifest
	if len(data)<8||len(data)>MaxManifest||string(data[:4])!="PSM2"{return m,errors.New("invalid manifest framing")}
	n:=binary.BigEndian.Uint32(data[4:8])
	if n==0||n>MaxEntries{return m,errors.New("invalid manifest entry count")}
	r:=bytes.NewReader(data[8:])
	m.Entries=make([]Entry,0,n)
	var count uint64
	for i:=uint32(0);i<n;i++{
		var h [3]byte
		if _,err:=io.ReadFull(r,h[:]);err!=nil{return Manifest{},err}
		if h[0]>1{return Manifest{},errors.New("invalid entry kind")}
		nameLen:=int(binary.BigEndian.Uint16(h[1:]))
		if nameLen==0||nameLen>MaxPath{return Manifest{},errors.New("invalid path length")}
		name:=make([]byte,nameLen)
		if _,err:=io.ReadFull(r,name);err!=nil{return Manifest{},err}
		var fixed [44]byte
		if _,err:=io.ReadFull(r,fixed[:]);err!=nil{return Manifest{},err}
		e:=Entry{Path:string(name),Directory:h[0]==1,Size:binary.BigEndian.Uint64(fixed[:8])}
		copy(e.Hash[:],fixed[8:40])
		blocks:=uint64(binary.BigEndian.Uint32(fixed[40:]))
		if blocks>MaxBlocks-count||blocks*32>uint64(r.Len())||e.Size>MaxBytes||blocks!=blockCount(e.Size){return Manifest{},errors.New("invalid block count")}
		count+=blocks
		e.Blocks=make([]Digest,int(blocks))
		for j:=range e.Blocks{if _,err:=io.ReadFull(r,e.Blocks[j][:]);err!=nil{return Manifest{},err}}
		m.Entries=append(m.Entries,e)
	}
	if r.Len()!=0{return Manifest{},errors.New("trailing manifest bytes")}
	if err:=m.Validate();err!=nil{return Manifest{},err}
	return m,nil
}

// InspectFile hashes an exact-sized ReaderAt without loading a whole block.
// The source adapter must hold a reviewed ordinary file and revalidate it
// when opening/sending. Block hashes detect later changed contents.
func InspectFile(ctx context.Context,path string,size uint64,r io.ReaderAt)(Entry,error){
	e:=Entry{Path:path,Size:size}
	if !validPath(path)||size>MaxBytes||r==nil{return Entry{},errors.New("invalid source metadata")}
	buf:=make([]byte,BufferSize)
	whole:=sha256.New()
	for offset:=uint64(0);offset<size;{
		if err:=ctx.Err();err!=nil{return Entry{},err}
		n:=int64(min(uint64(BlockSize),size-offset))
		h:=sha256.New()
		if err:=copyExact(ctx,io.MultiWriter(whole,h),io.NewSectionReader(r,int64(offset),n),n,buf);err!=nil{return Entry{},err}
		var sum Digest;copy(sum[:],h.Sum(nil));e.Blocks=append(e.Blocks,sum)
		offset+=uint64(n)
	}
	copy(e.Hash[:],whole.Sum(nil))
	var extra [1]byte
	if n,err:=r.ReadAt(extra[:],int64(size));n!=0||err!=io.EOF{return Entry{},errors.New("source size changed")}
	if err:=ctx.Err();err!=nil{return Entry{},err}
	return e,nil
}

func copyExact(ctx context.Context,w io.Writer,r io.Reader,n int64,buf []byte)error{
	for n>0{
		if err:=ctx.Err();err!=nil{return err}
		want:=int(min(n,int64(len(buf))))
		got,err:=io.ReadFull(r,buf[:want])
		if err!=nil{return err}
		if wrote,err:=w.Write(buf[:got]);err!=nil{return err}else if wrote!=got{return io.ErrShortWrite}
		n-=int64(got)
	}
	return ctx.Err()
}
