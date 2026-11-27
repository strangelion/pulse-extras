package sharecore

import (
	"context"
	"errors"
	"sync"
)

// Budget is shared by all incoming/outgoing transfers of one engine owner.
// It limits active data lanes and their streaming buffers. It is NOT a
// cross-process lock; the client/service adapter must enforce single owner.
// SetLimit changes admission only; in-flight work drains normally.
type Budget struct {
	mu sync.Mutex
	limit,active int
	changed chan struct{}
}

func NewBudget(limit int)(*Budget,error){
	if limit<1||limit>MaxChannels{return nil,errors.New("invalid global channel limit")}
	return &Budget{limit:limit,changed:make(chan struct{})},nil
}

func(b *Budget) signal(){close(b.changed);b.changed=make(chan struct{})}

func(b *Budget) SetLimit(limit int)error{
	if limit<1||limit>MaxChannels{return errors.New("invalid global channel limit")}
	b.mu.Lock();defer b.mu.Unlock()
	b.limit=limit;b.signal();return nil
}

func(b *Budget) Status()(limit,active int){
	b.mu.Lock();defer b.mu.Unlock();return b.limit,b.active
}

// run owns exactly one reusable stream buffer for this data lane.
// It deliberately never allocates 4 MiB * concurrency.
func(b *Budget) run(ctx context.Context,work func([]byte)error)error{
	if b==nil{return errors.New("missing shared budget")}
	for{
		if err:=ctx.Err();err!=nil{return err}
		b.mu.Lock()
		if b.active<b.limit{
			b.active++
			b.mu.Unlock()
			break
		}
		ch:=b.changed;b.mu.Unlock()
		select{case <-ctx.Done():return ctx.Err();case <-ch:}
	}
	defer func(){b.mu.Lock();b.active--;b.signal();b.mu.Unlock()}()
	buf:=make([]byte,BufferSize)
	defer clear(buf)
	if err:=ctx.Err();err!=nil{return err}
	return work(buf)
}

// Controller consumes real measured samples, not hardware names alone.
// Conservative additive increase / multiplicative decrease with a cooldown
// supplied by the caller's sampling cadence. No auto-tuning of auth limits.
type Sample struct{
	BytesPerSecond uint64
	RetryOrPressure bool
}

type Adaptive struct{
	Budget *Budget
	Ceiling int
	previous uint64
	stable int
}

func(a *Adaptive) Observe(s Sample)error{
	if a.Budget==nil||a.Ceiling<1||a.Ceiling>MaxChannels{return errors.New("invalid adaptive policy")}
	limit,_:=a.Budget.Status()
	next:=min(limit,a.Ceiling)
	if s.RetryOrPressure||(a.previous>0&&s.BytesPerSecond<a.previous-a.previous/4){
		next=max(1,next/2);a.stable=0
	}else if s.BytesPerSecond>0&&a.previous>0&&s.BytesPerSecond>=a.previous-a.previous/20{
		a.stable++
		if a.stable>=3{next=min(a.Ceiling,next+1);a.stable=0}
	}else{a.stable=0}
	a.previous=s.BytesPerSecond
	if next!=limit{return a.Budget.SetLimit(next)}
	return nil
}
