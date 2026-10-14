package main

import (
	"context"
	"core/internal/recovery"
	"errors"
	"net"
	"net/url"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/constant"
)

// probeHealth checks the actual HTTP status without mutating Mihomo's proxy
// delay/alive history. A domestic DIRECT probe must not change proxy health.
// URLTest cannot serve this purpose: at the pinned Mihomo revision it returns a
// positive delay even for an unexpected status, and publishes it through a hook.
func probeHealth(ctx context.Context, proxy constant.Proxy, rawURL string) (uint16, error) {
	return probeHealthWithTransport(ctx, proxy, rawURL, newHealthTransport)
}

func newHealthTransport(proxy constant.Proxy, metadata *constant.Metadata) (http.RoundTripper, error) {
	tlsConfig, err := ca.GetTLSConfig(ca.Option{})
	if err != nil {
		return nil, err
	}
	return &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return proxy.DialContext(ctx, metadata)
		},
		TLSClientConfig:     tlsConfig,
		DisableKeepAlives:   true,
		TLSHandshakeTimeout: 4 * time.Second,
	}, nil
}

// Transport injection keeps the actual status/redirect and selected-leaf path
// testable with an in-memory RoundTripper instead of real network traffic.
func probeHealthWithTransport(ctx context.Context, proxy constant.Proxy, rawURL string,
	factory func(constant.Proxy, *constant.Metadata) (http.RoundTripper, error)) (uint16, error) {
	u, err := url.Parse(rawURL)
	if err != nil || !recovery.HealthyStatus(rawURL, 204) {
		return 0, errors.New("health probe requires HTTPS")
	}
	port := u.Port()
	if port == "" {
		port = "443"
	}
	var metadata constant.Metadata
	if err := metadata.SetRemoteAddress(net.JoinHostPort(u.Hostname(), port)); err != nil {
		return 0, err
	}
	// Probe the actual selected leaf of our own group. Calling the group's
	// DialContext would also trigger Mihomo's unbounded failure health-check,
	// bypassing the recovery scheduler. Other/nested groups are not health routes.
	if proxy.Type() >= constant.Relay && proxy.Type() <= constant.LoadBalance {
		runLock.Lock()
		group := managedRecoveryGroup()
		if group == nil || proxy.Adapter() != group {
			runLock.Unlock()
			return 0, errors.New("health group is not app-managed")
		}
		selected := group.Unwrap(&metadata, false)
		runLock.Unlock()
		if selected == nil || selected.Type() < constant.Shadowsocks {
			return 0, errors.New("health group has no eligible leaf")
		}
		proxy = selected
	}
	transport, err := factory(proxy, &metadata)
	if err != nil {
		return 0, err
	}
	client := &http.Client{
		Transport:     transport,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
	}
	defer client.CloseIdleConnections()
	request, err := http.NewRequest(http.MethodHead, rawURL, nil)
	if err != nil {
		return 0, err
	}
	start := time.Now()
	response, err := client.Do(request.WithContext(ctx))
	if err != nil {
		return 0, err
	}
	defer response.Body.Close()
	if !recovery.HealthyStatus(rawURL, response.StatusCode) {
		return 0, errors.New("unexpected health status")
	}
	elapsed := time.Since(start).Milliseconds()
	if elapsed < 1 {
		elapsed = 1
	}
	if elapsed > 65535 {
		elapsed = 65535
	}
	return uint16(elapsed), nil
}
