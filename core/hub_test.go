package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

func TestDelayHonorsConfiguredHTTPStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		// Keep a successful local probe above the millisecond timer resolution.
		time.Sleep(5 * time.Millisecond)
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer server.Close()

	tunnel.UpdateProxies(map[string]C.Proxy{"DIRECT": adapter.NewProxy(outbound.NewDirect())}, nil)
	for _, test := range []struct {
		status string
		alive  bool
	}{{"401", true}, {"200-299", false}, {"", true}} {
		t.Run(test.status, func(t *testing.T) {
			params, err := json.Marshal(TestDelayParams{
				ProxyName: "DIRECT", TestUrl: server.URL, Timeout: 2000, ExpectedStatus: test.status,
			})
			if err != nil {
				t.Fatal(err)
			}
			response := make(chan string, 1)
			handleAsyncTestDelay(string(params), func(value string) { response <- value })
			select {
			case value := <-response:
				var delay Delay
				if err := json.Unmarshal([]byte(value), &delay); err != nil {
					t.Fatal(err)
				}
				if (delay.Value > 0) != test.alive {
					t.Fatalf("status %q: delay=%d, want alive=%v", test.status, delay.Value, test.alive)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("probe did not finish")
			}
		})
	}
}
