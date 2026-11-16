package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func bubbleReq(method, body, peer, device string) *http.Request {
	r := httptest.NewRequest(method, "http://100.81.123.86:8080/api/"+map[string]string{"POST": "bubble", "GET": "devices"}[method], strings.NewReader(body))
	r.RemoteAddr = peer
	if body != "" {
		r.Header.Set("Content-Type", "application/json")
	}
	return r.WithContext(context.WithValue(r.Context(), ingressKey{}, device))
}

func TestBubbleReportOnlyFromVolnixOverTailscale(t *testing.T) {
	oui := filepath.Join(t.TempDir(), "oui")
	os.WriteFile(oui, []byte("BCFCE7 ASUSTek Computer\n"), 0o644)
	n := &NM{
		directPeers: []string{"100.66.249.117", "100.65.161.34"},
		bubble:      &Bubble{OUI: oui, Reporters: []string{"100.66.249.117"}},
	}
	body := `{"devices":[
		{"mac":"96:94:0B:00:00:01","ip":"10.74.0.154","hostname":"Volatile\u001b[2JDevice","leaseExpires":1794796079,"online":true},
		{"mac":"bc:fc:e7:00:00:02","ip":"10.74.0.36","hostname":"","leaseExpires":0,"online":false},
		{"mac":"96:94:0b:00:00:01","ip":"10.74.0.99","hostname":"dup"}]}`
	for _, tc := range []struct {
		peer, device string
		want         int
	}{
		{"100.65.161.34:1", "tailscale0", http.StatusForbidden}, // a management peer, but not a reporter
		{"10.73.0.133:1", "eth0", http.StatusForbidden},         // the cable: bubble devices look like volnix here
		{"100.66.249.117:1", "tailscale0", http.StatusNoContent},
	} {
		w := httptest.NewRecorder()
		routes(n).ServeHTTP(w, bubbleReq("POST", body, tc.peer, tc.device))
		if w.Code != tc.want {
			t.Fatalf("%s on %s: status %d, want %d", tc.peer, tc.device, w.Code, tc.want)
		}
	}

	w := httptest.NewRecorder()
	routes(n).ServeHTTP(w, bubbleReq("GET", "", "100.65.161.34:1", "tailscale0"))
	var got DeviceReport
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil || w.Code != 200 {
		t.Fatalf("GET: %d %v", w.Code, err)
	}
	want := []Device{
		{MAC: "bc:fc:e7:00:00:02", IP: "10.74.0.36", Vendor: "ASUSTek Computer"},
		{MAC: "96:94:0b:00:00:01", IP: "10.74.0.154", Hostname: "Volatile[2JDevice", Vendor: "randomized", LeaseExpires: "2026-11-16T02:27:59Z", Online: true},
	}
	if got.ReportedAt == "" || len(got.Devices) != 2 || got.Devices[0] != want[0] || got.Devices[1] != want[1] {
		t.Fatalf("got %+v\nwant %+v", got, want)
	}

	w = httptest.NewRecorder()
	routes(n).ServeHTTP(w, bubbleReq("GET", "", "100.64.0.99:1", "tailscale0"))
	if w.Code != http.StatusForbidden {
		t.Fatalf("unapproved reader: status %d", w.Code)
	}
}

func TestBubbleRejectsBadReports(t *testing.T) {
	b := &Bubble{}
	many := `{"devices":[` + strings.Repeat(`{"mac":"02:00:00:00:00:01","ip":"10.74.0.2"},`, 64) + `{"mac":"02:00:00:00:00:02","ip":"10.74.0.3"}]}`
	for name, body := range map[string]string{
		"not json":  "devices",
		"bad mac":   `{"devices":[{"mac":"zz","ip":"10.74.0.2"}]}`,
		"ipv6":      `{"devices":[{"mac":"02:00:00:00:00:01","ip":"fe80::1"}]}`,
		"too many":  many,
		"too large": `{"devices":[{"mac":"02:00:00:00:00:01","ip":"10.74.0.2","hostname":"` + strings.Repeat("a", maxBubbleBody) + `"}]}`,
	} {
		if err := b.Accept(strings.NewReader(body), time.Now()); err == nil {
			t.Fatalf("%s: accepted", name)
		}
	}
	if b.Report().ReportedAt != "" {
		t.Fatal("a rejected report replaced the list")
	}
}
