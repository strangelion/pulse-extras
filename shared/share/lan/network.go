package main

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"time"
)

const discoveryPort = 45842

type binding struct {
	ip netip.Addr
	iface *net.Interface
	prefix netip.Prefix
}

// Concrete on-link local addresses only. Public addresses and wildcards
// are intentionally unsupported by this initial LAN transport.
func lanIP(ip netip.Addr) bool {
	return ip.IsValid() && !ip.Is4In6() && (ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLoopback())
}

func bindLocal(s string) (binding,error) {
	ip,err:=netip.ParseAddr(s)
	if err!=nil || !lanIP(ip){return binding{},errors.New("bind a specific private, link-local or loopback IP")}
	if ip.Is6() && ip.IsLinkLocalUnicast() && ip.Zone()=="" {
		return binding{},errors.New("IPv6 link-local bind requires interface zone")
	}
	interfaces,err:=net.Interfaces()
	if err!=nil{return binding{},err}
	for _,iface:=range interfaces {
		if iface.Flags&net.FlagUp==0 {continue}
		if ip.Zone()!="" && ip.Zone()!=iface.Name && ip.Zone()!=strconv.Itoa(iface.Index){continue}
		addrs,err:=iface.Addrs()
		if err!=nil{continue}
		for _,addr:=range addrs{
			p,err:=netip.ParsePrefix(addr.String())
			if err!=nil{continue}
			if p.Addr()==ip.WithZone("") {
				if ip.Is6() && ip.IsLinkLocalUnicast(){ip=ip.WithZone(strconv.Itoa(iface.Index))}
				return binding{ip:ip,iface:&iface,prefix:p.Masked()},nil
			}
		}
	}
	return binding{},errors.New("bind address not found on an active local interface")
}

func (b binding) allows(ip netip.Addr) bool {
	ip=ip.Unmap()
	if !lanIP(ip) || ip.Is4()!=b.ip.Is4() || ip.IsLoopback()!=b.ip.IsLoopback(){return false}
	if ip.Zone()!="" && ip.Zone()!=b.iface.Name && ip.Zone()!=strconv.Itoa(b.iface.Index){return false}
	return b.prefix.Contains(ip.WithZone(""))
}

func (b binding) peer(s string) (netip.AddrPort,error) {
	a,err:=netip.ParseAddrPort(s)
	if err!=nil || a.Port()==0 || !b.allows(a.Addr()) {
		return netip.AddrPort{},errors.New("peer must be a numeric on-link address and port")
	}
	if a.Addr().Is6() && a.Addr().IsLinkLocalUnicast(){
		a=netip.AddrPortFrom(a.Addr().WithZone(strconv.Itoa(b.iface.Index)),a.Port())
	}
	return a,nil
}

func (b binding) network() string {if b.ip.Is4(){return "tcp4"};return "tcp6"}

func (b binding) multicast() (*net.UDPConn,*net.UDPAddr,error) {
	if b.ip.IsLoopback() || b.iface.Flags&net.FlagMulticast==0 {
		return nil,nil,errors.New("selected interface has no LAN multicast")
	}
	network,group:="udp4","239.255.77.44"
	zone:=""
	if b.ip.Is6(){network,group,zone="udp6","ff02::5053:4831",strconv.Itoa(b.iface.Index)}
	addr:=&net.UDPAddr{IP:net.ParseIP(group),Port:discoveryPort,Zone:zone}
	c,err:=net.ListenMulticastUDP(network,b.iface,addr)
	return c,addr,err
}

// Only a fixed magic/version/port; never a fingerprint or command. Source
// address is an untrusted hint, never automatically connected or paired.
func announcement(port uint16) [8]byte {
	var data [8]byte
	copy(data[:6],"PSLAN1")
	binary.BigEndian.PutUint16(data[6:],port)
	return data
}

func parseAnnouncement(data []byte) (uint16,bool) {
	if len(data)!=8 || string(data[:6])!="PSLAN1"{return 0,false}
	port:=binary.BigEndian.Uint16(data[6:])
	return port,port!=0
}

func advertise(ctx context.Context,b binding,port uint16) error {
	c,group,err:=b.multicast()
	if err!=nil{return err}
	defer c.Close()
	data:=announcement(port)
	ticker:=time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		if err:=c.SetWriteDeadline(time.Now().Add(time.Second));err!=nil{return err}
		if _,err:=c.WriteToUDP(data[:],group);err!=nil{return err}
		select{case <-ctx.Done():return nil;case <-ticker.C:}
	}
}

func discover(ctx context.Context,b binding) error {
	c,_,err:=b.multicast()
	if err!=nil{return err}
	defer c.Close()
	stop:=context.AfterFunc(ctx,func(){c.Close()})
	defer stop()
	if err:=c.SetReadDeadline(time.Now().Add(5*time.Second));err!=nil{return err}
	seen:=make(map[netip.AddrPort]struct{})
	var data [64]byte
	for len(seen)<64{
		n,src,err:=c.ReadFromUDPAddrPort(data[:])
		if err!=nil{
			if e,ok:=err.(net.Error);ok && e.Timeout(){return nil}
			if ctx.Err()!=nil{return ctx.Err()}
			return err
		}
		port,ok:=parseAnnouncement(data[:n])
		if !ok || !b.allows(src.Addr()){continue}
		ip:=src.Addr()
		if ip.Is6() && ip.IsLinkLocalUnicast(){ip=ip.WithZone(strconv.Itoa(b.iface.Index))}
		endpoint:=netip.AddrPortFrom(ip,port)
		if _,ok=seen[endpoint];ok{continue}
		seen[endpoint]=struct{}{}
		fmt.Println("UNVERIFIED",endpoint)
	}
	return nil
}
