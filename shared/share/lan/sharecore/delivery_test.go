package sharecore

import "testing"
func TestDeliveryCapability(t *testing.T){
	if ValidateDelivery(ClipboardFiles,ToTrayShelf,DeliveryCapabilities{Folder:true})==nil{t.Fatal("filesystem staging mistaken for shelf")}
	if ValidateDelivery(ClipboardFiles,ToClipboard,DeliveryCapabilities{Clipboard:true})!=nil{t.Fatal("clipboard rejected")}
	if ValidateDelivery(ClipboardText,ToTrayShelf,DeliveryCapabilities{TrayShelf:true})==nil{t.Fatal("text incorrectly treated as file")}
	if ValidateDelivery(ClipboardFiles,Ask,DeliveryCapabilities{})!=nil{t.Fatal("ask rejected")}
}
