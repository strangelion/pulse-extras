package main

import (
	"encoding/binary"
	"errors"
	"strings"
	"unicode/utf16"
	"unicode/utf8"

	"pulse-extras/share-lan/sharecore"
)
const maxClipboardText=1024*1024
const maxClipboardImage=32*1024*1024
type clipboardPayload struct{
	kind sharecore.ContentKind
	data []byte
	paths []string
}

func decodeClipboardText(raw []byte)([]byte,error){
	if len(raw)%2!=0||len(raw)>2*maxClipboardText+2{return nil,errors.New("invalid clipboard text size")}
	u:=make([]uint16,0,len(raw)/2)
	for i:=0;i<len(raw);i+=2{
		v:=binary.LittleEndian.Uint16(raw[i:])
		if v==0{
			b:=[]byte(string(utf16.Decode(u)))
			if len(b)>maxClipboardText{return nil,errors.New("clipboard text too large")}
			return b,nil
		}
		u=append(u,v)
	}
	return nil,errors.New("unterminated clipboard text")
}
func encodeClipboardText(data []byte)([]byte,error){
	if len(data)>maxClipboardText||!utf8.Valid(data)||strings.IndexByte(string(data),0)>=0{return nil,errors.New("invalid clipboard text")}
	u:=utf16.Encode([]rune(string(data)))
	b:=make([]byte,(len(u)+1)*2)
	for i,v:=range u{binary.LittleEndian.PutUint16(b[2*i:],v)}
	return b,nil
}

// Normalize a bounded uncompressed 24/32-bit BITMAPINFOHEADER into a
// bottom-up 24-bit BMP; reject compressed, indexed and extended formats.
func bmpFromDIB(raw []byte)([]byte,error){
	if len(raw)<40||len(raw)>maxClipboardImage||binary.LittleEndian.Uint32(raw)!=40||
		binary.LittleEndian.Uint16(raw[12:])!=1||binary.LittleEndian.Uint32(raw[16:])!=0{
		return nil,errors.New("unsupported clipboard bitmap format")
	}
	w:=int64(int32(binary.LittleEndian.Uint32(raw[4:])))
	h:=int64(int32(binary.LittleEndian.Uint32(raw[8:])))
	bpp:=int64(binary.LittleEndian.Uint16(raw[14:]))
	top:=h<0;if top{h=-h}
	if w<1||w>4096||h<1||h>4096||(bpp!=24&&bpp!=32){return nil,errors.New("unsupported clipboard bitmap dimensions")}
	srcStride:=(w*(bpp/8)+3)&^3
	dstStride:=(w*3+3)&^3
	size:=dstStride*h
	if srcStride*h>int64(len(raw)-40)||size+54>maxClipboardImage{return nil,errors.New("truncated or oversized bitmap")}
	out:=make([]byte,int(size)+54)
	copy(out[:2],"BM")
	binary.LittleEndian.PutUint32(out[2:],uint32(len(out)))
	binary.LittleEndian.PutUint32(out[10:],54)
	binary.LittleEndian.PutUint32(out[14:],40)
	binary.LittleEndian.PutUint32(out[18:],uint32(w))
	binary.LittleEndian.PutUint32(out[22:],uint32(h))
	binary.LittleEndian.PutUint16(out[26:],1)
	binary.LittleEndian.PutUint16(out[28:],24)
	binary.LittleEndian.PutUint32(out[34:],uint32(size))
	for y:=int64(0);y<h;y++{
		sy:=y;if top{sy=h-1-y}
		src:=raw[40+sy*srcStride:];dst:=out[54+y*dstStride:]
		for x:=int64(0);x<w;x++{copy(dst[x*3:x*3+3],src[x*(bpp/8):x*(bpp/8)+3])}
	}
	return out,nil
}
func dibFromBMP(raw []byte)([]byte,error){
	if len(raw)<54||len(raw)>maxClipboardImage||string(raw[:2])!="BM"||
		binary.LittleEndian.Uint32(raw[2:])!=uint32(len(raw))||binary.LittleEndian.Uint32(raw[10:])!=54{
		return nil,errors.New("invalid clipboard BMP")
	}
	norm,err:=bmpFromDIB(raw[14:]);if err!=nil{return nil,err}
	return norm[14:],nil
}
