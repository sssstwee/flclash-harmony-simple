package main

import (
	"context"
	"core/internal/recovery"
	"encoding/json"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/tunnel"
)

var networkRecovery = recovery.New(recovery.SystemClock{}, recovery.Options{
	Debounce: 750 * time.Millisecond,
	Cooldown: 5 * time.Second,
	Timeout: 8 * time.Second,
}, refreshManagedGroup)

// Sent by the VPN extension over the existing updateDns bridge, so recovery does
// not depend on Flutter timers, a foreground UI, or an additional native ABI.
type nativeNetworkChange struct {
	Kind string `json:"kind"`
	DNS []string `json:"dns"`
	Online bool `json:"online"`
	CaptivePortal bool `json:"captivePortal"`
	Validated bool `json:"validated"`
}

var nativeNetworkMu sync.Mutex
var nativeDNS string
var nativeObservedNetwork *nativeNetworkChange

func getNativeNetworkState() string {
	nativeNetworkMu.Lock()
	defer nativeNetworkMu.Unlock()
	var connected *bool
	portal := false
	if nativeObservedNetwork != nil {
		connected = &nativeObservedNetwork.Online
		portal = nativeObservedNetwork.CaptivePortal
	}
	encoded, _ := json.Marshal(struct {
		Connected *bool `json:"connected"`
		CaptivePortal bool `json:"captivePortal"`
	}{connected, portal})
	return string(encoded)
}

func handleNativeNetworkChange(value string) bool {
	var change nativeNetworkChange
	if json.Unmarshal([]byte(value), &change) != nil { return false }
	if change.Kind == "recovery-stop" {
		networkRecovery.SetEnabled(false)
		networkRecovery.SetBackgroundActive(false)
		return true
	}
	if change.Kind == "network-stop" {
		nativeNetworkMu.Lock()
		nativeObservedNetwork = nil
		nativeNetworkMu.Unlock()
		networkRecovery.SetEnabled(false)
		networkRecovery.SetBackgroundActive(false)
		// A stopped observer has no current physical-network observation.
		networkRecovery.NetworkChanged(true, false)
		return true
	}
	if change.Kind != "network-change" { return false }
	// Synchronous serialization keeps DNS refresh ahead of the coalesced probe
	// and prevents older asynchronous callbacks overwriting the latest DNS list.
	nativeNetworkMu.Lock()
	defer nativeNetworkMu.Unlock()
	nativeObservedNetwork = &change
	encodedDNS, _ := json.Marshal(change.DNS)
	if nativeDNS != string(encodedDNS) {
		nativeDNS = string(encodedDNS)
		dns.UpdateSystemDNS(change.DNS)
		dns.FlushCacheWithDefaultResolver()
	}
	networkRecovery.NetworkChanged(change.Online, change.CaptivePortal)
	return true
}

// Must be called with runLock held. The marker is emitted only by the app's
// managed rule compiler. Imported groups and manual selectors are never warmed
// or reselected merely because their name looks like an automatic group.
func managedRecoveryGroup() *outboundgroup.URLTest {
	for _, proxy := range tunnel.AllProxies() {
		group, ok := proxy.Adapter().(*outboundgroup.URLTest)
		if !ok || group.Icon() != recovery.ManagedGroupIcon { continue }
		encoded, err := group.MarshalJSON()
		if err != nil { continue }
		var descriptor struct {
			TestURL string `json:"testUrl"`
			ExpectedStatus string `json:"expectedStatus"`
			EmptyFallback string `json:"emptyFallback"`
		}
		if json.Unmarshal(encoded, &descriptor) != nil { continue }
		if recovery.ManagedGroup(group.Icon(), descriptor.TestURL, descriptor.ExpectedStatus, descriptor.EmptyFallback) {
			return group
		}
	}
	return nil
}

var recoveryCursorGroup *outboundgroup.URLTest
var recoveryCursor int

func refreshManagedGroup(ctx context.Context) bool {
	runLock.Lock()
	if !isInit || currentConfig == nil || ctx.Err() != nil { runLock.Unlock(); return false }
	group := managedRecoveryGroup()
	if group == nil { runLock.Unlock(); return false }
	// A fixed batch cap bounds work even for very large subscriptions. Mihomo's
	// periodic managed URL-test still covers the entire candidate set.
	const maximumCandidates = 32
	allCandidates := make([]constant.Proxy, 0)
	selected := -1
	current := group.Now()
	for _, proxy := range group.Proxies() {
		// Adapter types before Shadowsocks are DIRECT/REJECT/compatibility and
		// groups. Never probe or force a nested selector or DIRECT route here.
		if proxy.Type() < constant.Shadowsocks { continue }
		if proxy.Name() == current { selected = len(allCandidates) }
		allCandidates = append(allCandidates, proxy)
	}
	if recoveryCursorGroup != group { recoveryCursorGroup = group; recoveryCursor = 0 }
	indices, _ := recovery.CandidateIndices(len(allCandidates), maximumCandidates, recoveryCursor, selected)
	startCursor := recoveryCursor
	candidates := make([]constant.Proxy, 0, len(indices))
	for _, index := range indices { candidates = append(candidates, allCandidates[index]) }
	runLock.Unlock()
	if len(candidates) == 0 { return false }
	expectedStatus, _ := utils.NewUnsignedRanges[uint16]("204")
	var dispatched atomic.Int32
	recovery.RunBounded(ctx, len(candidates), 4, func(parent context.Context, index int) {
		for previous := dispatched.Load(); int32(index+1) > previous; previous = dispatched.Load() {
			if dispatched.CompareAndSwap(previous, int32(index+1)) { break }
		}
		probeCtx, cancel := context.WithTimeout(parent, 2500 * time.Millisecond)
		defer cancel()
		// URLTest updates exactly this leaf's HTTPS/204 health history; its
		// returned delay alone is not used as a connectivity success signal.
		_, _ = candidates[index].URLTest(probeCtx, recovery.ManagedTestURL, expectedStatus)
	})
	runLock.Lock()
	defer runLock.Unlock()
	if managedRecoveryGroup() == group {
		recoveryCursor = recovery.NextCursor(len(allCandidates), startCursor, selected, indices[:int(dispatched.Load())])
	}
	if !isInit || currentConfig == nil || ctx.Err() != nil || managedRecoveryGroup() != group { return false }
	// Clears only this app-owned URL-test group's cached choice. It retains
	// Mihomo's tolerance logic and does not close any existing connection.
	group.ForceSet("")
	return true
}
