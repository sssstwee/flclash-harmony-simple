package recovery

import "testing"

func TestStrictHealthStatus(t *testing.T) {
	for _, test := range []struct { url string; status int; want bool }{
		{ManagedTestURL, 204, true},
		{ManagedTestURL, 200, false}, // captive portal with an HTML body
		{ManagedTestURL, 302, false},
		{ManagedTestURL, 503, false},
		{"https://www.baidu.com", 200, true},
		{"https://www.baidu.com", 302, false},
		{"https://www.baidu.com", 401, false},
		{"https://www.baidu.com", 500, false},
		{"http://www.baidu.com", 200, false},
		{"https://user:password@example.com", 200, false},
		{"https://", 200, false},
	} {
		if got := HealthyStatus(test.url, test.status); got != test.want { t.Errorf("status(%s,%d)=%v", test.url, test.status, got) }
	}
}

func TestOnlyManagedGroupCanRefresh(t *testing.T) {
	if !ManagedGroup(ManagedGroupIcon, ManagedTestURL, "204", "REJECT") { t.Fatal("managed group rejected") }
	for _, values := range [][4]string{
		{"", ManagedTestURL, "204", "REJECT"},
		{ManagedGroupIcon, "http://www.gstatic.com/generate_204", "204", "REJECT"},
		{ManagedGroupIcon, ManagedTestURL, "", "REJECT"},
		{ManagedGroupIcon, ManagedTestURL, "204", "DIRECT"},
	} {
		if ManagedGroup(values[0], values[1], values[2], values[3]) { t.Fatal("non-managed or unsafe group accepted") }
	}
}

func TestCandidateRotationIsBoundedAndDoesNotStarve(t *testing.T) {
	seen := map[int]bool{}
	cursor := 0
	for batch := 0; batch < 5; batch++ {
		indices, next := CandidateIndices(100, 32, cursor, 99)
		cursor = next
		if len(indices) > 32 { t.Fatal("unbounded batch") }
		unique := map[int]bool{}
		for _, index := range indices {
			if unique[index] { t.Fatal("duplicate candidate in batch") }
			unique[index] = true; seen[index] = true
		}
		if !unique[99] { t.Fatal("current leaf was not checked") }
	}
	if len(seen) != 100 { t.Fatalf("starved %d candidates", 100-len(seen)) }
}

func TestCurrentLeafFirstAndTimedOutTailNotStarved(t *testing.T) {
	indices, _ := CandidateIndices(64, 32, 0, 63)
	if indices[0] != 63 { t.Fatal("current leaf delayed behind slow candidates") }
	// Only the first four probes got dispatched before cancellation. The next
	// window must continue from the last actual rotating leaf, not jump to 32.
	next := NextCursor(64, 0, 63, indices[:4])
	if next != 3 { t.Fatalf("deadline skipped unprobed candidates: cursor=%d", next) }
	seen := map[int]bool{}
	for batch := 0; batch < 24; batch++ {
		indices, _ = CandidateIndices(64, 32, next, 63)
		for _, index := range indices[:4] { seen[index] = true }
		next = NextCursor(64, next, 63, indices[:4])
	}
	if len(seen) != 64 { t.Fatalf("deadline starved %d candidates", 64-len(seen)) }
}
