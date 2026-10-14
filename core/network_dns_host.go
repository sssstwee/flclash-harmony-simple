//go:build !android && !openharmony

package main

import "github.com/metacubex/mihomo/component/resolver"

// Desktop DNS discovery remains owned by Mihomo's OS resolver. The desktop
// socket core has no VPN-service DNS bridge and must not replace OS DNS with a
// mobile-supplied list. Only resolver caches/connections are refreshed here.
func updateNativeNetworkDNS(_ []string) {
	resolver.ClearCache()
	resolver.ResetConnection()
}
