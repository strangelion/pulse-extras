package sharecore

import "errors"

// Delivery is a local choice made after authentication and content approval.
// It is never decoded from a remote offer. Shelf availability must come
// from an actual documented host adapter, not from pulse.staging V1.
type Delivery uint8
const(
	Ask Delivery=iota
	ToClipboard
	ToFolder
	ToTrayShelf
)

type DeliveryCapabilities struct{
	Clipboard bool
	Folder bool
	TrayShelf bool
}

// ValidateDelivery does not grant access or perform publication. Files must
// already have passed manifest verification and safe local publication before
// putting their local paths into the clipboard or an actual host shelf.
func ValidateDelivery(kind ContentKind,to Delivery,c DeliveryCapabilities)error{
	switch to{
	case Ask:return nil
	case ToClipboard:
		if c.Clipboard&&(kind==ClipboardText||kind==ClipboardImage||kind==ClipboardFiles||kind==Files){return nil}
	case ToFolder:
		if c.Folder&&(kind==Files||kind==ClipboardFiles||kind==ClipboardText||kind==ClipboardImage){return nil}
	case ToTrayShelf:
		if c.TrayShelf&&(kind==Files||kind==ClipboardFiles){return nil}
	}
	return errors.New("requested delivery destination unavailable")
}
