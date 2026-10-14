package recovery

import (
	"context"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type fakeTimer struct {
	clock   *fakeClock
	at      time.Time
	fn      func()
	stopped bool
}

func (t *fakeTimer) Stop() bool {
	t.clock.mu.Lock()
	defer t.clock.mu.Unlock()
	wasActive := !t.stopped
	t.stopped = true
	return wasActive
}

type fakeClock struct {
	mu     sync.Mutex
	now    time.Time
	timers []*fakeTimer
}

func newClock() *fakeClock          { return &fakeClock{now: time.Unix(100, 0)} }
func (c *fakeClock) Now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.now }
func (c *fakeClock) AfterFunc(d time.Duration, fn func()) Timer {
	c.mu.Lock()
	defer c.mu.Unlock()
	timer := &fakeTimer{clock: c, at: c.now.Add(d), fn: fn}
	c.timers = append(c.timers, timer)
	return timer
}
func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	var callbacks []func()
	for _, timer := range c.timers {
		if !timer.stopped && !timer.at.After(c.now) {
			timer.stopped = true
			callbacks = append(callbacks, timer.fn)
		}
	}
	c.mu.Unlock()
	for _, callback := range callbacks {
		callback()
	}
}
func options() Options {
	return Options{Debounce: time.Second, Cooldown: 5 * time.Second, Timeout: 8 * time.Second}
}

// No probe or logical timing uses wall time. This watchdog only turns a broken
// goroutine/channel assertion into a test failure rather than hanging CI.
func receive[T any](t *testing.T, c <-chan T) T {
	t.Helper()
	select {
	case value := <-c:
		return value
	case <-time.After(2 * time.Second):
		t.Fatal("goroutine did not reach checkpoint")
	}
	var zero T
	return zero
}
func idle(t *testing.T, scheduler *Scheduler) {
	t.Helper()
	deadline := time.After(2 * time.Second)
	for {
		scheduler.mu.Lock()
		running := scheduler.running
		scheduler.mu.Unlock()
		if !running {
			return
		}
		select {
		case <-deadline:
			t.Fatal("refresh never completed")
		default:
			runtime.Gosched()
		}
	}
}

func TestBurstDebouncedWithoutStarvation(t *testing.T) {
	clock := newClock()
	started := make(chan struct{}, 2)
	scheduler := New(clock, options(), func(context.Context) bool { started <- struct{}{}; return true })
	scheduler.SetEnabled(true)
	scheduler.SetBackgroundActive(true)
	for i := 0; i < 100; i++ {
		scheduler.NetworkChanged(true, false)
	}
	clock.advance(900 * time.Millisecond)
	select {
	case <-started:
		t.Fatal("ran before debounce")
	default:
	}
	for i := 0; i < 100; i++ {
		scheduler.NetworkChanged(true, false)
	}
	clock.advance(100 * time.Millisecond)
	receive(t, started)
	idle(t, scheduler)
	clock.advance(time.Minute)
	select {
	case <-started:
		t.Fatal("burst created duplicate refresh")
	default:
	}
}

func TestSingleFlightOnePendingAndCooldown(t *testing.T) {
	clock := newClock()
	started := make(chan struct{}, 2)
	release := make(chan struct{})
	var active, maximum atomic.Int32
	scheduler := New(clock, options(), func(context.Context) bool {
		n := active.Add(1)
		if n > maximum.Load() {
			maximum.Store(n)
		}
		started <- struct{}{}
		<-release
		active.Add(-1)
		return true
	})
	scheduler.SetEnabled(true)
	scheduler.SetBackgroundActive(true)
	scheduler.NetworkChanged(true, false)
	clock.advance(time.Second)
	receive(t, started)
	for i := 0; i < 100; i++ {
		scheduler.NetworkChanged(true, false)
	}
	release <- struct{}{}
	idle(t, scheduler)
	clock.advance(4 * time.Second)
	select {
	case <-started:
		t.Fatal("cooldown skipped")
	default:
	}
	clock.advance(time.Second)
	receive(t, started)
	release <- struct{}{}
	idle(t, scheduler)
	if maximum.Load() != 1 {
		t.Fatal("overlapping refreshes")
	}
	clock.advance(time.Minute)
	select {
	case <-started:
		t.Fatal("more than one pending refresh")
	default:
	}
}

func TestTimeoutCancelsWithoutDetachedOverlap(t *testing.T) {
	clock := newClock()
	started := make(chan context.Context, 2)
	release := make(chan struct{})
	scheduler := New(clock, options(), func(ctx context.Context) bool { started <- ctx; <-release; return true })
	scheduler.SetEnabled(true)
	scheduler.SetBackgroundActive(true)
	scheduler.NetworkChanged(true, false)
	clock.advance(time.Second)
	ctx := receive(t, started)
	scheduler.NetworkChanged(true, false)
	clock.advance(8 * time.Second)
	if ctx.Err() == nil {
		t.Fatal("time budget did not cancel probe")
	}
	clock.advance(time.Hour)
	select {
	case <-started:
		t.Fatal("detached timed-out work overlapped")
	default:
	}
	close(release)
	idle(t, scheduler)
	scheduler.SetEnabled(false)
}

func TestOfflinePortalStopAndConfigReplacementCancel(t *testing.T) {
	for _, reason := range []string{"offline", "portal", "stop", "config"} {
		t.Run(reason, func(t *testing.T) {
			clock := newClock()
			started := make(chan context.Context, 2)
			scheduler := New(clock, options(), func(ctx context.Context) bool { started <- ctx; <-ctx.Done(); return false })
			scheduler.SetEnabled(true)
			scheduler.SetBackgroundActive(true)
			scheduler.NetworkChanged(true, false)
			clock.advance(time.Second)
			ctx := receive(t, started)
			scheduler.NetworkChanged(true, false)
			switch reason {
			case "offline":
				scheduler.NetworkChanged(false, false)
			case "portal":
				scheduler.NetworkChanged(true, true)
			case "stop":
				scheduler.SetEnabled(false)
			case "config":
				scheduler.SetEnabled(false)
				scheduler.SetEnabled(true)
				scheduler.SetBackgroundActive(true)
			}
			if ctx.Err() == nil {
				t.Fatal("lifecycle change failed to cancel")
			}
			idle(t, scheduler)
			clock.advance(time.Minute)
			select {
			case <-started:
				t.Fatal("stale pending refresh survived invalidation")
			default:
			}
		})
	}
}

func TestAwaitableRefreshJoinsBackground(t *testing.T) {
	clock := newClock()
	started := make(chan struct{}, 2)
	release := make(chan struct{})
	scheduler := New(clock, options(), func(context.Context) bool { started <- struct{}{}; <-release; return true })
	scheduler.SetEnabled(true)
	scheduler.SetBackgroundActive(true)
	scheduler.NetworkChanged(true, false)
	clock.advance(time.Second)
	receive(t, started)
	result := make(chan bool, 1)
	go func() { result <- scheduler.Refresh(context.Background()) }()
	waitForWaiters(t, scheduler, 1)
	close(release)
	if !receive(t, result) {
		t.Fatal("joined refresh should succeed")
	}
	idle(t, scheduler)
	clock.advance(time.Minute)
	select {
	case <-started:
		t.Fatal("joining caused duplicate refresh")
	default:
	}
}

func TestBoundedFanoutAndCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	started := make(chan int, 32)
	finished := make(chan struct{})
	var active, maximum atomic.Int32
	go func() {
		RunBounded(ctx, 1000, 4, func(ctx context.Context, i int) {
			n := active.Add(1)
			for old := maximum.Load(); n > old; old = maximum.Load() {
				if maximum.CompareAndSwap(old, n) {
					break
				}
			}
			started <- i
			<-ctx.Done()
			active.Add(-1)
		})
		close(finished)
	}()
	for i := 0; i < 4; i++ {
		receive(t, started)
	}
	cancel()
	receive(t, finished)
	if maximum.Load() != 4 || active.Load() != 0 {
		t.Fatalf("fanout max=%d active=%d", maximum.Load(), active.Load())
	}
	select {
	case <-started:
		t.Fatal("canceled queue started another probe")
	default:
	}
}

func TestCanceledFanoutDoesNoWork(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	RunBounded(ctx, 10, 4, func(context.Context, int) { t.Fatal("probe after cancellation") })
}

func waitForWaiters(t *testing.T, scheduler *Scheduler, count int) {
	t.Helper()
	deadline := time.After(2 * time.Second)
	for {
		scheduler.mu.Lock()
		size := len(scheduler.waiters)
		scheduler.mu.Unlock()
		if size == count {
			return
		}
		select {
		case <-deadline:
			t.Fatal("waiter checkpoint not reached")
		default:
			runtime.Gosched()
		}
	}
}

func TestRestartRefreshWaitsForCanceledPreviousGeneration(t *testing.T) {
	clock := newClock()
	started := make(chan context.Context, 2)
	release := make(chan struct{}, 2)
	scheduler := New(clock, options(), func(ctx context.Context) bool { started <- ctx; <-release; return true })
	scheduler.SetEnabled(true)
	scheduler.SetBackgroundActive(true)
	scheduler.NetworkChanged(true, false)
	clock.advance(time.Second)
	old := receive(t, started)
	scheduler.SetEnabled(false)
	scheduler.SetEnabled(true)
	result := make(chan bool, 1)
	go func() { result <- scheduler.Refresh(context.Background()) }()
	waitForWaiters(t, scheduler, 1)
	if old.Err() == nil {
		t.Fatal("old generation was not canceled")
	}
	release <- struct{}{}
	idle(t, scheduler)
	clock.advance(5 * time.Second)
	fresh := receive(t, started)
	if fresh.Err() != nil {
		t.Fatal("new generation inherited cancellation")
	}
	release <- struct{}{}
	if !receive(t, result) {
		t.Fatal("new generation was never refreshed")
	}
	idle(t, scheduler)
}

func TestExplicitPreflightWithoutBackgroundService(t *testing.T) {
	clock := newClock()
	started := make(chan struct{}, 1)
	scheduler := New(clock, options(), func(context.Context) bool { started <- struct{}{}; return true })
	scheduler.SetEnabled(true) // parsed config, VPN not started
	scheduler.NetworkChanged(true, false)
	clock.advance(time.Minute)
	select {
	case <-started:
		t.Fatal("background work before service started")
	default:
	}
	result := make(chan bool, 1)
	go func() { result <- scheduler.Refresh(context.Background()) }()
	waitForWaiters(t, scheduler, 1)
	clock.advance(time.Second)
	receive(t, started)
	if !receive(t, result) {
		t.Fatal("preflight did not run")
	}
	idle(t, scheduler)
}

func TestCanceledCallerDoesNotRetainWaiter(t *testing.T) {
	clock := newClock()
	scheduler := New(clock, options(), func(context.Context) bool { return true })
	scheduler.SetEnabled(true)
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan bool, 1)
	go func() { result <- scheduler.Refresh(ctx) }()
	waitForWaiters(t, scheduler, 1)
	cancel()
	if receive(t, result) {
		t.Fatal("canceled caller succeeded")
	}
	waitForWaiters(t, scheduler, 0)
	scheduler.SetEnabled(false)
}
