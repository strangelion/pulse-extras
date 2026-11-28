package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const journalName = "transaction.v1"
const journalLimit = 2048

var phases = []string{"receiving","verified","committing","committed"}

type journal struct {
	path string
	phase int
}

func newJournal(dir string,o offer)(*journal,error){
	if !validName(o.name) || o.size>maxFile{return nil,errors.New("invalid journal offer")}
	j:=&journal{path:filepath.Join(dir,journalName)}
	f,err:=os.OpenFile(j.path,os.O_WRONLY|os.O_CREATE|os.O_EXCL,0600)
	if err!=nil{return nil,err}
	record:=fmt.Sprintf("PSJ1\n%d\n%x\n%s\nreceiving\n",o.size,o.digest,o.name)
	err=writeAll(f,[]byte(record))
	if err==nil{err=f.Sync()}
	err=errors.Join(err,f.Close())
	if err!=nil{return nil,err}
	return j,nil
}

func(j *journal) advance(next string)error{
	if j.phase+1>=len(phases) || phases[j.phase+1]!=next{return errors.New("invalid journal transition")}
	f,err:=os.OpenFile(j.path,os.O_WRONLY|os.O_APPEND,0)
	if err!=nil{return err}
	err=writeAll(f,[]byte(next+"\n"))
	if err==nil{err=f.Sync()}
	err=errors.Join(err,f.Close())
	if err==nil{j.phase++}
	return err
}

type journalRecord struct{
	offer offer
	phase string
}

// A valid record is not proof of ownership or process liveness.
func readJournal(dir string)(journalRecord,error){
	var record journalRecord
	data,err:=readStoreFile(filepath.Join(dir,journalName),journalLimit)
	if err!=nil{return record,err}
	lines:=strings.Split(string(data),"\n")
	if len(lines)<6 || len(lines)>9 || lines[len(lines)-1]!="" || lines[0]!="PSJ1"{return record,errors.New("invalid journal framing")}
	size,err:=strconv.ParseUint(lines[1],10,64)
	if err!=nil || size>maxFile{return record,errors.New("invalid journal size")}
	pin,err:=parsePin(lines[2])
	if err!=nil || !validName(lines[3]){return record,errors.New("invalid journal metadata")}
	for i,phase:=range lines[4:len(lines)-1]{
		if i>=len(phases) || phase!=phases[i]{return record,errors.New("invalid journal phase sequence")}
		record.phase=phase
	}
	record.offer=offer{name:lines[3],size:size,digest:pin}
	return record,nil
}
