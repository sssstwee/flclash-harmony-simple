package main

import (
	"context"
	"core/internal/recovery"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
)

type memoryRoundTripper func(*http.Request) (*http.Response, error)

func (fn memoryRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

// Embed the pinned interface to keep intentionally unused network methods inert.
// Any unexpected call to one of them fails the test instead of doing real I/O.
type memoryProxy struct {
	constant.Proxy
	mu     sync.Mutex
	name   string
	kind   constant.AdapterType
	alive  bool
	delay  uint16
	status int
	tests  int
	dials  int
}

func (p *memoryProxy) Name() string                   { return p.name }
func (p *memoryProxy) Type() constant.AdapterType     { return p.kind }
func (p *memoryProxy) Adapter() constant.ProxyAdapter { return p }
func (p *memoryProxy) AliveForTestUrl(string) bool    { p.mu.Lock(); defer p.mu.Unlock(); return p.alive }
func (p *memoryProxy) LastDelayForTestUrl(string) uint16 {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.alive {
		return 65535
	}
	return p.delay
}
func (p *memoryProxy) URLTest(_ context.Context, _ string, expected utils.IntRanges[uint16]) (uint16, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.tests++
	p.alive = expected.Check(uint16(p.status))
	return p.delay, nil // Mimics Mihomo's positive-delay/unexpected-status behavior.
}
func (p *memoryProxy) DialContext(context.Context, *constant.Metadata) (constant.Conn, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.dials++
	return nil, errors.New("synthetic dial failure")
}

type memoryProvider struct {
	P.ProxyProvider
	proxies []constant.Proxy
}

func (p *memoryProvider) Proxies() []constant.Proxy  { return p.proxies }
func (p *memoryProvider) Version() uint32            { return 1 }
func (p *memoryProvider) VehicleType() P.VehicleType { return P.Compatible }
func (p *memoryProvider) Name() string               { return "memory" }
func (p *memoryProvider) Touch()                     {}
func (p *memoryProvider) HealthCheck()               { panic("unbounded provider health check must not run") }

func installedGroup(t *testing.T, candidates []constant.Proxy, marker string) *outboundgroup.URLTest {
	t.Helper()
	reject := &memoryProxy{name: "REJECT", kind: constant.Reject}
	provider := &memoryProvider{proxies: candidates}
	group, err := outboundgroup.NewURLTest(outboundgroup.GroupCommonOption{
		Name: "Managed Test", Icon: marker, URL: recovery.ManagedTestURL, ExpectedStatus: "204",
	}, outboundgroup.URLTestOption{Tolerance: 50}, reject, []P.ProxyProvider{provider})
	if err != nil {
		t.Fatal(err)
	}
	oldProxies, oldProviders := tunnel.Proxies(), tunnel.Providers()
	oldInit, oldConfig := isInit, currentConfig
	tunnel.UpdateProxies(map[string]constant.Proxy{group.Name(): adapter.NewProxy(group)}, nil)
	isInit, currentConfig = true, &config.Config{}
	t.Cleanup(func() {
		tunnel.UpdateProxies(oldProxies, oldProviders)
		isInit, currentConfig = oldInit, oldConfig
		recoveryCursorGroup, recoveryCursor = nil, 0
	})
	return group
}

func TestHealthTransportStatusAndRedirectRejection(t *testing.T) {
	for _, status := range []int{204, 200, 302, 503} {
		calls := 0
		proxy := &memoryProxy{name: "leaf", kind: constant.Shadowsocks}
		factory := func(selected constant.Proxy, metadata *constant.Metadata) (http.RoundTripper, error) {
			if selected != proxy || metadata.Host != "www.gstatic.com" {
				t.Fatal("wrong route or target")
			}
			return memoryRoundTripper(func(request *http.Request) (*http.Response, error) {
				calls++
				if request.Method != http.MethodHead {
					t.Fatal("unexpected probe method")
				}
				return &http.Response{StatusCode: status, Header: http.Header{"Location": {"https://portal.test/login"}},
					Body: io.NopCloser(strings.NewReader("")), Request: request}, nil
			}), nil
		}
		delay, err := probeHealthWithTransport(context.Background(), proxy, recovery.ManagedTestURL, factory)
		if (err == nil) != (status == 204) {
			t.Fatalf("status=%d delay=%d error=%v", status, delay, err)
		}
		if calls != 1 {
			t.Fatal("followed redirect")
		}
		if proxy.tests != 0 || proxy.dials != 0 {
			t.Fatal("status validation mutated delay history")
		}
	}
}

func TestHealthTransportKeepsTLSVerificationAndUsesProxyDialer(t *testing.T) {
	proxy := &memoryProxy{name: "DIRECT", kind: constant.Direct}
	transport, err := newHealthTransport(proxy, &constant.Metadata{Host: "example.test", DstPort: 443})
	if err != nil {
		t.Fatal(err)
	}
	httpTransport := transport.(*http.Transport)
	if httpTransport.TLSClientConfig.InsecureSkipVerify {
		t.Fatal("TLS verification disabled")
	}
	if !httpTransport.DisableKeepAlives {
		t.Fatal("health connection retained")
	}
	conn, err := httpTransport.DialContext(context.Background(), "tcp", net.JoinHostPort("example.test", "443"))
	if conn != nil || err == nil || proxy.dials != 1 {
		t.Fatal("did not use configured proxy dialer")
	}
}

func TestHealthProbeUnwrapsOnlyManagedGroupAndDoesNotTriggerProviderChecks(t *testing.T) {
	leaf := &memoryProxy{name: "actual-leaf", kind: constant.Shadowsocks, alive: true, delay: 10}
	group := installedGroup(t, []constant.Proxy{leaf}, recovery.ManagedGroupIcon)
	factoryCalls := 0
	factory := func(selected constant.Proxy, _ *constant.Metadata) (http.RoundTripper, error) {
		factoryCalls++
		if selected != leaf {
			t.Fatal("health probe did not resolve actual selected leaf")
		}
		return memoryRoundTripper(func(*http.Request) (*http.Response, error) { return nil, errors.New("synthetic failure") }), nil
	}
	_, _ = probeHealthWithTransport(context.Background(), adapter.NewProxy(group), recovery.ManagedTestURL, factory)
	if factoryCalls != 1 || leaf.tests != 0 {
		t.Fatal("group probe triggered a health sweep")
	}
}

func TestHealthProbeRejectsImportedGroupsAndDirectFallback(t *testing.T) {
	for _, marker := range []string{"", recovery.ManagedGroupIcon} {
		t.Run(marker, func(t *testing.T) {
			direct := &memoryProxy{name: "DIRECT", kind: constant.Direct, alive: true, delay: 1}
			group := installedGroup(t, []constant.Proxy{direct}, marker)
			_, err := probeHealthWithTransport(context.Background(), adapter.NewProxy(group), recovery.ManagedTestURL,
				func(constant.Proxy, *constant.Metadata) (http.RoundTripper, error) {
					t.Fatal("unsafe group reached transport")
					return nil, nil
				})
			if err == nil {
				t.Fatal("unsafe group accepted")
			}
		})
	}
}

func TestManagedRefreshMovesStaleChoiceAfterStrictLeafWarm(t *testing.T) {
	stale := &memoryProxy{name: "stale", kind: constant.Shadowsocks, alive: true, delay: 5, status: 503}
	healthy := &memoryProxy{name: "healthy", kind: constant.Shadowsocks, alive: true, delay: 20, status: 204}
	group := installedGroup(t, []constant.Proxy{stale, healthy}, recovery.ManagedGroupIcon)
	if group.Now() != stale.name {
		t.Fatal("test did not start with stale cached choice")
	}
	if !refreshManagedGroup(context.Background()) {
		t.Fatal("refresh failed")
	}
	if group.Now() != healthy.name || stale.alive || stale.tests != 1 || healthy.tests != 1 {
		t.Fatal("strict warm-up did not invalidate stale cached choice")
	}
	if stale.dials != 0 || healthy.dials != 0 {
		t.Fatal("test unexpectedly made a real dial")
	}
}

func TestProviderCollisionCannotHideManagedRuleTarget(t *testing.T) {
	// Provider leaf names are not globally unique. A leaf can legitimately have
	// the same name as our static group; object/type identity must decide routing.
	colliding := &memoryProxy{name: "Managed Test", kind: constant.Shadowsocks, alive: true, delay: 10, status: 204}
	group := installedGroup(t, []constant.Proxy{colliding}, recovery.ManagedGroupIcon)
	static := tunnel.Proxies()
	provider := &memoryProvider{proxies: []constant.Proxy{colliding}}
	tunnel.UpdateProxies(static, map[string]P.ProxyProvider{"memory": provider})
	if tunnel.AllProxies()[group.Name()] != colliding {
		t.Fatal("fixture did not reproduce provider overlay")
	}
	if managedRecoveryGroup() != group {
		t.Fatal("provider leaf hid managed group discovery")
	}
	root := appProxies()[group.Name()]
	if root.Adapter() != group {
		t.Fatal("named lookup differs from actual rule routing")
	}
	if handleGetProxies().Proxies[group.Name()].Adapter() != group {
		t.Fatal("UI proxy view hid static group")
	}
	_, err := probeHealthWithTransport(context.Background(), root, recovery.ManagedTestURL,
		func(selected constant.Proxy, _ *constant.Metadata) (http.RoundTripper, error) {
			if selected != colliding {
				t.Fatal("strict probe lost actual selected leaf identity")
			}
			return memoryRoundTripper(func(request *http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: 204, Header: http.Header{}, Body: io.NopCloser(strings.NewReader("")), Request: request}, nil
			}), nil
		})
	if err != nil {
		t.Fatal(err)
	}
	if !refreshManagedGroup(context.Background()) || colliding.tests != 1 {
		t.Fatal("colliding managed group did not refresh")
	}
	result := make(chan string, 1)
	handleChangeProxy(`{"group-name":"Managed Test","proxy-name":""}`, func(value string) { result <- value })
	select {
	case message := <-result:
		if message != "" {
			t.Fatalf("selector lookup targeted provider leaf: %s", message)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("selector lookup did not finish")
	}
}

func TestStaticDirectWinsProviderNameAndReturnedMapIsIndependent(t *testing.T) {
	leaf := &memoryProxy{name: "leaf", kind: constant.Shadowsocks, alive: true, delay: 10}
	group := installedGroup(t, []constant.Proxy{leaf}, recovery.ManagedGroupIcon)
	direct := &memoryProxy{name: "DIRECT", kind: constant.Direct}
	shadow := &memoryProxy{name: "DIRECT", kind: constant.Shadowsocks}
	static := map[string]constant.Proxy{group.Name(): tunnel.Proxies()[group.Name()], "DIRECT": direct}
	tunnel.UpdateProxies(static, map[string]P.ProxyProvider{"memory": &memoryProvider{proxies: []constant.Proxy{shadow}}})
	view := appProxies()
	if view["DIRECT"] != direct {
		t.Fatal("domestic DIRECT lookup was shadowed by a provider")
	}
	delete(view, "DIRECT")
	if tunnel.Proxies()["DIRECT"] != direct {
		t.Fatal("application view mutated static registry")
	}
}
