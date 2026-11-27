package sharecore

import (
	"errors"
	"testing"
)

func TestFeaturesDefaultOff(t *testing.T){
	var f Features
	a:=Admission{Kind:Files,Direction:Send,Authenticated:true,Approved:true}
	if err:=f.Admit(a);err!=nil{t.Fatal(err)}
	for _,kind:=range []ContentKind{ClipboardText,ClipboardImage,ClipboardFiles,TrayShelf,RemoteDirectory,WebAccess}{
		a.Kind=kind
		if !errors.Is(f.Admit(a),ErrFeatureDisabled){t.Fatalf("feature enabled by default: %d",kind)}
	}
	a.Kind=Files;a.Approved=false
	if !errors.Is(f.Admit(a),ErrUnauthorized){t.Fatal("unapproved file accepted")}
}

func TestClipboardSwitchesAndPeerGrants(t *testing.T){
	f:=Features{Clipboard:true,ClipboardText:true,ClipboardSend:true}
	a:=Admission{Kind:ClipboardText,Direction:Send,Authenticated:true,Approved:true}
	if err:=f.Admit(a);err!=nil{t.Fatal(err)}
	a.Direction=Receive
	if !errors.Is(f.Admit(a),ErrFeatureDisabled){t.Fatal("receive implicitly enabled")}
	a.Direction=Send;a.Kind=ClipboardImage
	if !errors.Is(f.Admit(a),ErrFeatureDisabled){t.Fatal("image implicitly enabled")}
	a.Kind=ClipboardText;a.Automatic=true
	if !errors.Is(f.Admit(a),ErrFeatureDisabled){t.Fatal("auto sync implicitly enabled")}
	f.AutoClipboard=true
	if !errors.Is(f.Admit(a),ErrUnauthorized){t.Fatal("missing per-peer grant accepted")}
	a.Auto.TextSend=true
	if err:=f.Admit(a);err!=nil{t.Fatal(err)}
	a.Authenticated=false
	if !errors.Is(f.Admit(a),ErrUnauthorized){t.Fatal("untrusted peer accepted")}
	a.Authenticated=true;f.Clipboard=false
	if !errors.Is(f.Admit(a),ErrFeatureDisabled){t.Fatal("master switch bypassed")}
	f.Clipboard=true;f.ClipboardFiles=true;a.Kind=ClipboardFiles
	if !errors.Is(f.Admit(a),ErrUnauthorized){t.Fatal("automatic clipboard file send accepted")}
	a.Automatic=false
	if err:=f.Admit(a);err!=nil{t.Fatal(err)}
}
