package main

import (
	"fmt"
	"net"
	"net/netip"
	"strings"
)

// Explicit local inventory only; no packets, no scanning or default listen.
func listLocalInterfaces()error{
	interfaces,err:=net.Interfaces()
	if err!=nil{return err}
	count:=0
	for _,iface:=range interfaces{
		if iface.Flags&net.FlagUp==0{continue}
		addrs,err:=iface.Addrs()
		if err!=nil{continue}
		for _,addr:=range addrs{
			prefix,err:=netip.ParsePrefix(addr.String())
			if err!=nil{continue}
			ip:=prefix.Addr().Unmap()
			if !routedIP(ip){continue}
			if ip.Is6()&&ip.IsLinkLocalUnicast(){ip=ip.WithZone(fmt.Sprint(iface.Index))}
			name:=strings.Map(func(r rune)rune{if r<32||r==127{return ' '};return r},iface.Name)
			fmt.Printf("LOCAL %s  %q\n",ip,name)
			count++
			if count>=64{fmt.Println("LOCAL INVENTORY TRUNCATED");return nil}
		}
	}
	if count==0{fmt.Println("No supported active local address")}
	return nil
}
