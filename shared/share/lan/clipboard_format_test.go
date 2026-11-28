package main

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestClipboardTextFormat(t *testing.T){
	raw:=[]byte("中文 hello 🌎")
	b,err:=encodeClipboardText(raw);if err!=nil{t.Fatal(err)}
	out,err:=decodeClipboardText(b);if err!=nil||!bytes.Equal(out,raw){t.Fatal("text roundtrip",err)}
	if _,err:=encodeClipboardText([]byte{0});err==nil{t.Fatal("embedded NUL accepted")}
	if _,err:=decodeClipboardText([]byte{1,0});err==nil{t.Fatal("unterminated text accepted")}
}
func TestClipboardBitmapFormat(t *testing.T){
	b:=make([]byte,44)
	binary.LittleEndian.PutUint32(b,40);binary.LittleEndian.PutUint32(b[4:],1);binary.LittleEndian.PutUint32(b[8:],1)
	binary.LittleEndian.PutUint16(b[12:],1);binary.LittleEndian.PutUint16(b[14:],24)
	copy(b[40:],[]byte{1,2,3,0})
	bmp,err:=bmpFromDIB(b);if err!=nil{t.Fatal(err)}
	dib,err:=dibFromBMP(bmp);if err!=nil||!bytes.Equal(dib[40:],b[40:]){t.Fatal("bitmap roundtrip",err)}
	if _,err:=bmpFromDIB(b[:43]);err==nil{t.Fatal("truncated bitmap accepted")}
	binary.LittleEndian.PutUint32(b[16:],1)
	if _,err:=bmpFromDIB(b);err==nil{t.Fatal("compressed input accepted")}
}
