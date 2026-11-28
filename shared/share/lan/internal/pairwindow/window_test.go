package pairwindow

import (
	"errors"
	"testing"
	"time"
)

func TestRFC6238SHA256(t *testing.T) {
	seed := []byte("12345678901234567890123456789012")
	for _, tc := range []struct{ seconds int64; want string }{
		{59,"46119246"}, {1111111109,"68084774"}, {1111111111,"67062674"},
		{1234567890,"91819424"}, {2000000000,"90698825"}, {20000000000,"77737706"},
	} {
		// RFC test vectors use 30-second steps; production uses 60.
		if got := code(seed,uint64(tc.seconds/30)); got != tc.want { t.Fatalf("got %s want %s",got,tc.want) }
	}
}

func TestWindow(t *testing.T) {
	start := time.Unix(120,0)
	w := &Window{started:start,seed:[32]byte{1,2,3}}
	first, remaining, err := w.current(start)
	if err != nil || len(first)!=8 || remaining!=Step { t.Fatal("initial window") }
	ticket, password, _, err := w.begin(start)
	if err != nil || first!=password { t.Fatal("attempt password") }
	if _,_,_,err=w.begin(start); !errors.Is(err,ErrClosed) { t.Fatal("parallel attempt") }
	if w.finish(start.Add(Step),ticket,true) { t.Fatal("expired attempt accepted") }
	second, _, err := w.current(start.Add(Step))
	if err != nil || first==second { t.Fatal("rotation") }
	next,_,_,err := w.begin(start.Add(Step))
	if err != nil || w.finish(start.Add(Step),ticket,true) { t.Fatal("stale ticket") }
	if !w.finish(start.Add(Step),next,true) { t.Fatal("valid local completion") }
	if _,_,err=w.current(start.Add(Step)); !errors.Is(err,ErrClosed) { t.Fatal("consumed code reused") }
	if w.seed != [32]byte{} { t.Fatal("seed retained after close") }
}

func TestAttemptLimitAndExpiry(t *testing.T) {
	start:=time.Unix(120,0)
	w:=&Window{started:start,seed:[32]byte{1}}
	for i:=0;i<MaxAttempts;i++ {
		ticket,_,_,err:=w.begin(start)
		if err!=nil || w.finish(start,ticket,false) { t.Fatal("failed attempt") }
	}
	if _,_,_,err:=w.begin(start); !errors.Is(err,ErrClosed) { t.Fatal("attempt limit") }
	w=&Window{started:start,seed:[32]byte{1}}
	if _,_,err:=w.current(start.Add(Lifetime)); !errors.Is(err,ErrClosed) { t.Fatal("expired window") }
	w=&Window{started:start,seed:[32]byte{1}}
	w.Close()
	if _,_,_,err:=w.begin(start); !errors.Is(err,ErrClosed) { t.Fatal("closed window") }
}

func TestIndependentSeeds(t *testing.T) {
	a,err:=New(); if err!=nil {t.Fatal(err)}; defer a.Close()
	b,err:=New(); if err!=nil {t.Fatal(err)}; defer b.Close()
	if a.seed==b.seed || a.seed==[32]byte{} || b.seed==[32]byte{} {t.Fatal("invalid random seed")}
}
