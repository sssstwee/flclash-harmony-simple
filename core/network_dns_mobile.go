//go:build android || openharmony

package main

import "github.com/metacubex/mihomo/dns"

// Mobile DNS is supplied by the VPN service. These APIs are defined only in
// Mihomo's Android/OpenHarmony patches; preserve their production behavior.
func updateNativeNetworkDNS(addresses []string) {
	dns.UpdateSystemDNS(addresses)
	dns.FlushCacheWithDefaultResolver()
}
