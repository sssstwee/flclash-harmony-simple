// Package recovery contains the network-change scheduler, without platform or
// Mihomo dependencies. Timers and probes are injectable for deterministic tests.
package recovery

import (
	"context"
	"sync"
	"time"
)

type Timer interface{ Stop() bool }
type Clock interface {
	Now() time.Time
	AfterFunc(time.Duration, func()) Timer
}
type SystemClock struct{}

func (SystemClock) Now() time.Time                            { return time.Now() }
func (SystemClock) AfterFunc(d time.Duration, f func()) Timer { return time.AfterFunc(d, f) }

type Options struct {
	Debounce time.Duration
	Cooldown time.Duration
	Timeout  time.Duration
}

// Scheduler permits one refresh at a time. Repeated events share one pending
// refresh; a continuous event stream cannot postpone it indefinitely. Disable,
// offline, portal and config replacement cancel pending and in-flight work.
// A probe must honor its context. An uncooperative probe keeps the single-flight
// slot until it returns, rather than leaking more goroutines on every event.
type Scheduler struct {
	mu                sync.Mutex
	clock             Clock
	options           Options
	run               func(context.Context) bool
	enabled           bool
	backgroundActive  bool
	available         bool
	pending           bool
	running           bool
	generation        uint64
	runningGeneration uint64
	timer             Timer
	cancel            context.CancelFunc
	nextStart         time.Time
	waiters           []chan bool
}

func New(clock Clock, options Options, run func(context.Context) bool) *Scheduler {
	return &Scheduler{clock: clock, options: options, run: run, available: true}
}

func (s *Scheduler) SetEnabled(enabled bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.invalidateLocked()
	s.enabled = enabled
}

// SetBackgroundActive restricts unsolicited network-event work to an active
// service while allowing explicit preflight checks against an installed config.
func (s *Scheduler) SetBackgroundActive(active bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.backgroundActive = active
}

func (s *Scheduler) invalidateLocked() {
	s.generation++
	s.pending = false
	for _, waiter := range s.waiters {
		waiter <- false
		close(waiter)
	}
	s.waiters = nil
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}
}

func (s *Scheduler) NetworkChanged(online, portal bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.available = online && !portal
	if !s.enabled || !s.available {
		s.invalidateLocked()
		return
	}
	if s.backgroundActive {
		s.pending = true
		s.scheduleLocked()
	}
}

// Refresh joins the current refresh or requests one using the same bounded
// scheduler. The buffered result cannot retain a canceled RPC caller.
func (s *Scheduler) Refresh(ctx context.Context) bool {
	result := make(chan bool, 1)
	s.mu.Lock()
	if !s.enabled || !s.available || ctx.Err() != nil || len(s.waiters) >= 32 {
		s.mu.Unlock()
		return false
	}
	s.waiters = append(s.waiters, result)
	if !s.running || s.runningGeneration != s.generation {
		s.pending = true
	}
	s.scheduleLocked()
	s.mu.Unlock()
	select {
	case success := <-result:
		return success
	case <-ctx.Done():
		s.mu.Lock()
		for index, waiter := range s.waiters {
			if waiter == result {
				s.waiters = append(s.waiters[:index], s.waiters[index+1:]...)
				break
			}
		}
		s.mu.Unlock()
		return false
	}
}

func (s *Scheduler) scheduleLocked() {
	if !s.enabled || !s.available || !s.pending || s.running || s.timer != nil {
		return
	}
	delay := s.options.Debounce
	if wait := s.nextStart.Sub(s.clock.Now()); wait > delay {
		delay = wait
	}
	generation := s.generation
	s.timer = s.clock.AfterFunc(delay, func() { s.start(generation) })
}

func (s *Scheduler) start(generation uint64) {
	s.mu.Lock()
	if generation != s.generation {
		s.mu.Unlock()
		return
	}
	s.timer = nil
	if !s.enabled || !s.available || !s.pending || s.running {
		s.mu.Unlock()
		return
	}
	s.pending = false
	s.running = true
	s.runningGeneration = generation
	s.nextStart = s.clock.Now().Add(s.options.Cooldown)
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	timeout := s.clock.AfterFunc(s.options.Timeout, cancel)
	s.mu.Unlock()
	go func() {
		success := false
		defer func() {
			timeout.Stop()
			cancel()
			s.mu.Lock()
			s.running = false
			if generation == s.generation {
				s.cancel = nil
				for _, waiter := range s.waiters {
					waiter <- success
					close(waiter)
				}
				s.waiters = nil
			}
			s.scheduleLocked()
			s.mu.Unlock()
		}()
		success = s.run(ctx) && ctx.Err() == nil
	}()
}

// RunBounded uses a fixed worker count and stops dispatching when canceled.
// It never starts one goroutine per candidate and never detaches timed-out work.
func RunBounded(ctx context.Context, count, concurrency int, probe func(context.Context, int)) {
	if count <= 0 || concurrency <= 0 || ctx.Err() != nil {
		return
	}
	if concurrency > count {
		concurrency = count
	}
	jobs := make(chan int)
	var workers sync.WaitGroup
	for i := 0; i < concurrency; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for index := range jobs {
				if ctx.Err() != nil {
					return
				}
				probe(ctx, index)
			}
		}()
	}
loop:
	for i := 0; i < count; i++ {
		select {
		case <-ctx.Done():
			break loop
		case jobs <- i:
		}
	}
	close(jobs)
	workers.Wait()
}
