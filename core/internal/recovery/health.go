package recovery

import "net/url"

// HealthyStatus deliberately excludes redirects, portal pages at a 204 endpoint,
// and HTTP failures. Only HTTPS probes are allowed to establish health.
func HealthyStatus(rawURL string, status int) bool {
	u, err := url.Parse(rawURL)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
		return false
	}
	if u.Path == "/generate_204" {
		return status == 204
	}
	return status >= 200 && status <= 299
}

const ManagedGroupIcon = "flclash-internal://harmony-auto/v1"
const ManagedTestURL = "https://www.gstatic.com/generate_204"

func ManagedGroup(icon, testURL, expectedStatus, fallback string) bool {
	return icon == ManagedGroupIcon && testURL == ManagedTestURL && expectedStatus == "204" && fallback == "REJECT"
}

// CandidateIndices visits a bounded rotating window, retaining the currently
// selected leaf in the batch so a stale current choice is checked promptly.
func CandidateIndices(total, limit, cursor, selected int) ([]int, int) {
	if total <= 0 || limit <= 0 {
		return nil, 0
	}
	if limit > total {
		limit = total
	}
	cursor = cursor % total
	if cursor < 0 {
		cursor = 0
	}
	indices := make([]int, 0, limit)
	if selected >= 0 && selected < total {
		indices = append(indices, selected)
	}
	for scanned := 0; len(indices) < limit && scanned < total; scanned++ {
		index := cursor
		cursor = (cursor + 1) % total
		if index != selected {
			indices = append(indices, index)
		}
	}
	return indices, cursor
}

// NextCursor advances only past actually dispatched rotating candidates. A
// deadline cannot starve the unprobed tail of every window on large profiles.
func NextCursor(total, cursor, selected int, dispatched []int) int {
	if total <= 0 {
		return 0
	}
	for _, index := range dispatched {
		if index != selected {
			cursor = (index + 1) % total
		}
	}
	return cursor
}
