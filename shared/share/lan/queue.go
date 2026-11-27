package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"pulse-extras/share-lan/sharecore"
)

// A local private outbox. No automatic replay after publication may have
// occurred. Jobs bind the selected manifest, local identity and saved peer.
const queueLimit = 128
const queueRecordLimit = 64 * 1024

type queuedBatch struct {
	Version int
	ID string
	Bind, Endpoint, Label, Sources string
	Routed, QUIC bool
	Channels int
	Local, Peer, Manifest [32]byte
}

func validQueueID(s string) bool {
	if len(s)!=45||s[20]!='-'{return false}
	for _,c:=range s[:20]{if c<'0'||c>'9'{return false}}
	_,err:=hex.DecodeString(s[21:])
	return err==nil&&strings.ToLower(s)==s
}
func queueRoot(store string)(string,error){
	root,err:=storeRoot(store);if err!=nil{return "",err}
	if err=auditPrivateDirectory(root);err!=nil{return "",err}
	q:=filepath.Join(root,"outbox.v1")
	if _,err=os.Lstat(q);os.IsNotExist(err){
		if err=createPrivateDirectory(q);err!=nil{return "",err}
	}else if err!=nil{return "",err}
	if err=auditPrivateDirectory(q);err!=nil{return "",err}
	return q,nil
}
func queueIDs(root string)([]string,error){
	f,err:=os.Open(root);if err!=nil{return nil,err};defer f.Close()
	entries,err:=f.ReadDir(queueLimit+1)
	if err!=nil&&err!=io.EOF{return nil,err}
	if len(entries)>queueLimit{return nil,errors.New("outbox capacity exceeded")}
	ids:=make([]string,0,len(entries))
	for _,e:=range entries{
		if !e.IsDir()||!validQueueID(e.Name()){return nil,errors.New("unknown outbox entry; inspect locally")}
		ids=append(ids,e.Name())
	}
	sort.Strings(ids)
	return ids,nil
}
func decodeQueuedBatch(b []byte,id string)(queuedBatch,error){
	var j queuedBatch
	if !validQueueID(id)||len(b)>queueRecordLimit{return j,errors.New("invalid queue record")}
	d:=json.NewDecoder(bytes.NewReader(b));d.DisallowUnknownFields()
	if err:=d.Decode(&j);err!=nil{return j,err}
	var extra any
	if d.Decode(&extra)!=io.EOF{return j,errors.New("unexpected queue record data")}
	if j.Version!=1||j.ID!=id||j.Sources==""||j.Label==""||j.Bind==""||j.Endpoint==""||j.Local==([32]byte{})||j.Peer==([32]byte{})||j.Manifest==([32]byte{}){return j,errors.New("invalid queue record fields")}
	_,_,err:=batchChannelLimit(j.Channels)
	return j,err
}
func loadQueuedBatch(root,id string)(queuedBatch,error){
	if !validQueueID(id){return queuedBatch{},errors.New("invalid local job ID")}
	dir:=filepath.Join(root,id)
	if err:=auditPrivateDirectory(dir);err!=nil{return queuedBatch{},err}
	b,err:=readStoreFile(filepath.Join(dir,"job.json"),queueRecordLimit)
	if err!=nil{return queuedBatch{},err}
	return decodeQueuedBatch(b,id)
}
func queueState(dir string)(string,error){
	// Marker order matters: explicit discard is terminal, but started without
	// acknowledgement is uncertain after a crash or failed connection.
	for _,state:=range []string{"discarded","completed","started"}{
		p:=filepath.Join(dir,state)
		if _,err:=os.Lstat(p);os.IsNotExist(err){continue}else if err!=nil{return "",err}
		b,err:=readStoreFile(p,32)
		if err!=nil||string(b)!=state+"\n"{return "",errors.New("invalid job marker; inspect locally")}
		if state=="started"{return "uncertain",nil}
		return state,nil
	}
	return "pending",nil
}
func markQueue(dir,state string)error{
	return createStoreFile(filepath.Join(dir,state),[]byte(state+"\n"))
}
func queueEnqueue(ctx context.Context,root,store string,j queuedBatch)error{
	ids,err:=queueIDs(root);if err!=nil{return err}
	if len(ids)>=queueLimit{return errors.New("outbox full; prune terminal jobs")}
	b,err:=bindLocalMode(j.Bind,j.Routed);if err!=nil{return err}
	if _,err=b.peer(j.Endpoint);err!=nil{return err}
	if _,_,err=batchChannelLimit(j.Channels);err!=nil{return err}
	id,err:=loadStoredIdentity(store);if err!=nil{return err}
	pin,err:=loadPeer(store,j.Label);if err!=nil{return err}
	s,err:=scanBatch(ctx,strings.Split(j.Sources,"|"));if err!=nil{return err}
	wire,err:=s.m.Encode();if err!=nil{return err}
	j.Version=1;j.Local=id.pin;j.Peer=pin;j.Manifest=sha256.Sum256(wire)
	var nonce [12]byte;if _,err=rand.Read(nonce[:]);err!=nil{return err}
	j.ID=fmt.Sprintf("%020d-%x",time.Now().UnixNano(),nonce)
	raw,err:=json.Marshal(j);if err!=nil{return err}
	if len(raw)>queueRecordLimit{return errors.New("queue record exceeds limit")}
	dir:=filepath.Join(root,j.ID)
	if err=createPrivateDirectory(dir);err!=nil{return err}
	if err=createStoreFile(filepath.Join(dir,"job.json"),raw);err!=nil{return err}
	fmt.Println("QUEUE",j.ID,"pending")
	return nil
}
func runQueuedBatch(ctx context.Context,root,store string,j queuedBatch)error{
	dir:=filepath.Join(root,j.ID)
	if err:=ctx.Err();err!=nil{return err}
	b,err:=bindLocalMode(j.Bind,j.Routed);if err!=nil{return err}
	addr,err:=b.peer(j.Endpoint);if err!=nil{return err}
	id,err:=loadStoredIdentity(store);if err!=nil{return err}
	if id.pin!=j.Local{return errors.New("queued local identity changed")}
	check:=func(ctx context.Context)error{return batchGrant(ctx,store,j.Label,id,j.Peer)}
	if err=check(ctx);err!=nil{return err}
	s,err:=scanBatch(ctx,strings.Split(j.Sources,"|"));if err!=nil{return err}
	wire,err:=s.m.Encode();if err!=nil{return err}
	if sha256.Sum256(wire)!=j.Manifest{return errors.New("queued selection changed; discard and enqueue again")}
	limit,_,err:=batchChannelLimit(j.Channels);if err!=nil{return err}
	link,err:=openBatchSender(ctx,b,addr,id,j.Peer,j.QUIC)
	if err!=nil{return err} // no offer sent, remains pending
	defer link.close()
	if err=markQueue(dir,"started");err!=nil{return err}
	fmt.Println("QUEUE",j.ID,"started")
	if err=batchSend(ctx,link,s,sharecore.Files,j.Peer,limit,check);err!=nil{
		return fmt.Errorf("job %s uncertain: %w",j.ID,err)
	}
	if err=markQueue(dir,"completed");err!=nil{return err}
	fmt.Println("QUEUE",j.ID,"completed")
	return nil
}
func queueAction(ctx context.Context,action,store,jobID string,offset int,j queuedBatch)error{
	if !isManaged(ctx){release,err:=acquireTransferOwner();if err!=nil{return err};defer release()}
	root,err:=queueRoot(store);if err!=nil{return err}
	switch action{
	case "enqueue":return queueEnqueue(ctx,root,store,j)
	case "list","run","discard","prune":
	default:return errors.New("invalid queue action")
	}
	ids,err:=queueIDs(root);if err!=nil{return err}
	found:=false
	if action=="list"&&jobID==""{
		if offset<0||offset>len(ids){return errors.New("invalid queue offset")}
		end:=min(len(ids),offset+20)
		fmt.Printf("QUEUE page %d-%d of %d\n",offset,end,len(ids))
		ids=ids[offset:end]
	}
	for _,id:=range ids{
		if jobID!=""&&jobID!=id{continue}
		found=true
		job,err:=loadQueuedBatch(root,id);if err!=nil{return err}
		dir:=filepath.Join(root,id)
		state,err:=queueState(dir);if err!=nil{return err}
		switch action{
		case "list":fmt.Printf("QUEUE %s %s peer=%q\n",id,state,job.Label)
		case "run":
			if state=="uncertain"{return errors.New("uncertain job requires explicit discard after checking destination")}
			if state=="pending"{if err=runQueuedBatch(ctx,root,store,job);err!=nil{return err}}
		case "discard":
			if jobID==""{return errors.New("select a local job ID")}
			if state=="pending"||state=="uncertain"{if err=markQueue(dir,"discarded");err!=nil{return err}}
		case "prune":
			if state!="completed"&&state!="discarded"{continue}
			// Remove only recognized files, never an unknown directory tree.
			entries,err:=os.ReadDir(dir);if err!=nil{return err}
			for _,e:=range entries{
				switch e.Name(){case "job.json","started","completed","discarded":default:return errors.New("unknown job entry")}
				if !e.Type().IsRegular(){return errors.New("invalid job file")}
			}
			// Remove the job record first: interrupted cleanup cannot turn a
			// terminal job into a replayable pending job.
			if err=os.Remove(filepath.Join(dir,"job.json"));err!=nil{return err}
			for _,e:=range entries{if e.Name()!="job.json"{if err=os.Remove(filepath.Join(dir,e.Name()));err!=nil{return err}}}
			if err=os.Remove(dir);err!=nil{return err}
		}
	}
	if jobID!=""&&!found{return errors.New("queue job not found")}
	fmt.Println("QUEUE operation complete")
	return nil
}
