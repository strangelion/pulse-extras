package sharecore

import "errors"

// ContentKind identifies the locally reviewed source or requested action.
// These values are not permissions supplied by the network.
type ContentKind uint8

const (
	Files ContentKind = iota + 1
	ClipboardText
	ClipboardImage
	ClipboardFiles
	TrayShelf
	RemoteDirectory
	WebAccess
)

type Direction uint8

const (
	Send Direction = iota + 1
	Receive
)

// Features is an owner-controlled configuration. The zero value permits
// ordinary explicit file sharing only. Every other feature is opt-in.
// A feature switch is not a device grant or a filesystem authorization.
type Features struct {
	Clipboard bool
	ClipboardText bool
	ClipboardImage bool
	ClipboardFiles bool
	ClipboardSend bool
	ClipboardReceive bool
	AutoClipboard bool
	TrayShelf bool
	RemoteDirectory bool
	WebAccess bool
}

type AutoGrant struct {
	TextSend bool
	TextReceive bool
	ImageSend bool
	ImageReceive bool
}

// Admission must be constructed by a trusted local adapter after checking
// authentication, current grants and consent. Never decode it from a peer.
// For manual actions Approved means explicit local approval. For automatic
// clipboard actions it means a currently valid local per-peer authorization.
// Remote directory and Web access still require per-resource authorization.
type Admission struct {
	Kind ContentKind
	Direction Direction
	Authenticated bool
	Approved bool
	Automatic bool
	Auto AutoGrant
}

var ErrFeatureDisabled = errors.New("content sharing feature disabled")
var ErrUnauthorized = errors.New("content sharing not authorized")

func (f Features) Admit(a Admission) error {
	if a.Direction!=Send&&a.Direction!=Receive{return ErrUnauthorized}
	if !a.Authenticated||!a.Approved{return ErrUnauthorized}
	switch a.Kind {
	case Files:
		if a.Automatic{return ErrUnauthorized}
		return nil
	case TrayShelf:
		if !f.TrayShelf{return ErrFeatureDisabled}
		if a.Automatic{return ErrUnauthorized}
		return nil
	case RemoteDirectory:
		if !f.RemoteDirectory{return ErrFeatureDisabled}
		if a.Automatic{return ErrUnauthorized}
		return nil
	case WebAccess:
		if !f.WebAccess{return ErrFeatureDisabled}
		if a.Automatic{return ErrUnauthorized}
		return nil
	case ClipboardText, ClipboardImage, ClipboardFiles:
		if !f.Clipboard||a.Direction==Send&&!f.ClipboardSend||a.Direction==Receive&&!f.ClipboardReceive{return ErrFeatureDisabled}
		enabled:=false
		automatic:=false
		switch a.Kind {
		case ClipboardText:
			enabled=f.ClipboardText
			automatic=a.Direction==Send&&a.Auto.TextSend||a.Direction==Receive&&a.Auto.TextReceive
		case ClipboardImage:
			enabled=f.ClipboardImage
			automatic=a.Direction==Send&&a.Auto.ImageSend||a.Direction==Receive&&a.Auto.ImageReceive
		case ClipboardFiles:
			enabled=f.ClipboardFiles
			// File/folder references always need an explicit action.
		}
		if !enabled{return ErrFeatureDisabled}
		if a.Automatic{
			if !f.AutoClipboard{return ErrFeatureDisabled}
			if !automatic{return ErrUnauthorized}
		}
		return nil
	default:
		return ErrUnauthorized
	}
}
