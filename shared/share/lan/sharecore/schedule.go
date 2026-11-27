package sharecore

import (
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"syscall"
	"time"
)

// ErrLaneDisconnected marks a transient transport interruption. An adapter
// may return it only for a known connectivity failure, never for authentication,
// protocol negotiation, revoked grants or local storage failures.
var ErrLaneDisconnected = errors.New("transient data lane interruption")

// OpenLane must recheck the current grant, pin, transaction and manifest on
// EVERY connection. The context bounds opening; a successful stream is owned
// by the scheduler. It must not select a weaker protocol on failure.
type OpenLane func(context.Context, Transaction) (LaneStream, error)

type ScheduleOptions struct {
	// Workers is a per-transaction ceiling; the shared Budget is authoritative.
	Workers int
	// Attempts includes the initial round. At most five bounded rounds.
	Attempts int
}

type watchedLane struct{ LaneStream }

func transportError(err error) error {
	if err==nil{return nil}
	var n net.Error
	if errors.Is(err,io.EOF)||errors.Is(err,io.ErrUnexpectedEOF)||errors.Is(err,io.ErrClosedPipe)||
		errors.Is(err,net.ErrClosed)||errors.Is(err,syscall.ECONNRESET)||errors.Is(err,syscall.EPIPE)||
		(errors.As(err,&n)&&n.Timeout()){
		return ErrLaneDisconnected
	}
	return err
}
func(w watchedLane) Read(p []byte)(int,error){n,err:=w.LaneStream.Read(p);return n,transportError(err)}
func(w watchedLane) Write(p []byte)(int,error){n,err:=w.LaneStream.Write(p);return n,transportError(err)}
func(w watchedLane) SetDeadline(t time.Time)error{return transportError(w.LaneStream.SetDeadline(t))}

// A joined local failure must not become retryable merely because a network
// interruption happened at the same time (e.g. a failed stage-file close).
func retryableOnly(err error)bool{
	if err==ErrLaneDisconnected{return true}
	if err==nil{return false}
	if multi,ok:=err.(interface{Unwrap() []error});ok{
		children:=multi.Unwrap()
		if len(children)==0{return false}
		for _,child:=range children{if !retryableOnly(child){return false}}
		return true
	}
	if child:=errors.Unwrap(err);child!=nil{return retryableOnly(child)}
	return false
}

// TransferMissing coordinates disjoint missing-block assignments. The owner
// must exclusively manage this Stage for the duration: do not invoke Receive,
// ReceiveLane, Close or Seal concurrently. A second scheduler is rejected.
// Each lane reserves the global budget BEFORE opening a transport stream.
// Retry uses only durable missing receipts, never a new transaction, and never
// publishes. Success means local blocks are complete, NOT peer acknowledgement
// or a committed destination. Reopen is still required after process restart.
func(s *Stage) TransferMissing(ctx context.Context,open OpenLane,options ScheduleOptions)error{
	if open==nil||options.Workers<1||options.Workers>MaxChannels||
		options.Attempts<1||options.Attempts>5{return errors.New("invalid lane schedule")}
	if !s.scheduleMu.TryLock(){return ErrBusy}
	defer s.scheduleMu.Unlock()
	for attempt:=0;attempt<options.Attempts;attempt++{
		if err:=ctx.Err();err!=nil{return err}
		missing,err:=s.Missing()
		if err!=nil{return err}
		if len(missing)==0{return nil}
		workers:=min(options.Workers,len(missing))
		// Partition by contiguous ranges; no duplicate request across lanes.
		round,stop:=context.WithCancel(ctx)
		results:=make(chan error,workers)
		var wg sync.WaitGroup
		for i:=0;i<workers;i++{
			blocks:=missing[i*len(missing)/workers:(i+1)*len(missing)/workers]
			wg.Add(1)
			go func(blocks []Block){
				defer wg.Done()
				err:=s.budget.run(round,func(buf []byte)error{
					dial,done:=context.WithTimeout(round,laneIdle)
					stream,err:=open(dial,s.tx)
					done()
					if err!=nil{
						if stream!=nil{err=errors.Join(err,stream.Close())}
						return err
					}
					if stream==nil{return errors.New("missing authenticated lane")}
					defer stream.Close()
					cancelIO:=context.AfterFunc(round,func(){stream.Close()})
					defer cancelIO()
					return s.receiveLane(round,watchedLane{stream},blocks,buf)
				})
				results<-err
				if err!=nil&&!retryableOnly(err){stop()}
			}(blocks)
		}
		wg.Wait()
		stop()
		close(results)
		var fatal,transient error
		for err:=range results{
			if err==nil{continue}
			if retryableOnly(err){transient=errors.Join(transient,err)}else{fatal=errors.Join(fatal,err)}
		}
		if err:=ctx.Err();err!=nil{return err}
		if fatal!=nil{return fatal}
		missing,err=s.Missing()
		if err!=nil{return err}
		if len(missing)==0{return nil}
		if transient==nil{return ErrIncomplete}
		if attempt+1==options.Attempts{return transient}
		timer:=time.NewTimer(time.Duration(1<<attempt)*250*time.Millisecond)
		select{
		case <-ctx.Done():timer.Stop();return ctx.Err()
		case <-timer.C:
		}
	}
	return ErrIncomplete
}
