package sharecore

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

func TestScheduledResumeAndAdmission(t *testing.T){
	ctx,cancel:=context.WithTimeout(context.Background(),10*time.Second);defer cancel()
	m,data,tx:=fixture(t)
	b:=budget(t,1)
	s,err:=Create(t.TempDir(),tx,m,b);if err!=nil{t.Fatal(err)}
	defer s.Close()
	if err:=s.Receive(ctx,Block{2,0},bytes.NewReader(data[:BlockSize]));err!=nil{t.Fatal(err)}
	var opened,reads atomic.Int32
	sender,err:=NewSender(tx,m,budget(t,1),func(_ context.Context,i uint32)(io.ReaderAt,io.Closer,error){
		reads.Add(1)
		if i!=2{return nil,nil,errors.New("unexpected source")}
		return bytes.NewReader(data),io.NopCloser(bytes.NewReader(nil)),nil
	})
	if err!=nil{t.Fatal(err)}
	open:=func(_ context.Context,got Transaction)(LaneStream,error){
		if got!=tx{return nil,errors.New("wrong transaction")}
		if _,active:=b.Status();active!=1{return nil,errors.New("opened without budget")}
		if opened.Add(1)==1{
			a,c:=net.Pipe();a.Close();return c,nil
		}
		a,c:=net.Pipe()
		go func(){_ = sender.ServeLane(ctx,a)}()
		return c,nil
	}
	if err:=s.TransferMissing(ctx,open,ScheduleOptions{Workers:2,Attempts:3});err!=nil{t.Fatal(err)}
	if opened.Load()!=2||reads.Load()!=1{t.Fatalf("unexpected opens/reads %d/%d",opened.Load(),reads.Load())}
	if missing,err:=s.Missing();err!=nil||len(missing)!=0{t.Fatal("missing receipts")}
	if _,active:=b.Status();active!=0{t.Fatal("leaked budget")}
}

func TestScheduleDoesNotRetryPermanentFailure(t *testing.T){
	m,_,tx:=fixture(t)
	s,err:=Create(t.TempDir(),tx,m,budget(t,1));if err!=nil{t.Fatal(err)}
	defer s.Close()
	denied:=errors.New("grant revoked")
	var calls int
	err=s.TransferMissing(context.Background(),func(context.Context,Transaction)(LaneStream,error){
		calls++;return nil,denied
	},ScheduleOptions{Workers:1,Attempts:5})
	if !errors.Is(err,denied)||calls!=1{t.Fatalf("unexpected retry: %v (%d)",err,calls)}
	if retryableOnly(errors.Join(ErrLaneDisconnected,denied)){t.Fatal("local failure treated as transport failure")}
}

func TestScheduleCancellationAndRetryLimit(t *testing.T){
	m,_,tx:=fixture(t)
	b:=budget(t,1)
	s,err:=Create(t.TempDir(),tx,m,b);if err!=nil{t.Fatal(err)}
	defer s.Close()
	var calls int
	open:=func(context.Context,Transaction)(LaneStream,error){calls++;return nil,ErrLaneDisconnected}
	if err:=s.TransferMissing(context.Background(),open,ScheduleOptions{Workers:1,Attempts:2});!errors.Is(err,ErrLaneDisconnected)||calls!=2{t.Fatalf("retry bound failed: %v (%d)",err,calls)}
	ctx,cancel:=context.WithCancel(context.Background());cancel()
	if err:=s.TransferMissing(ctx,open,ScheduleOptions{Workers:1,Attempts:5});!errors.Is(err,context.Canceled)||calls!=2{t.Fatal("cancelled schedule opened stream")}
	if _,active:=b.Status();active!=0{t.Fatal("leaked budget")}
}
