package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDirectModeRequiresApprovedTailnetPeer(t *testing.T) {
	for _, tc := range []struct {
		peer, device string
		want         bool
	}{
		{"100.66.249.117:1234", "tailscale0", true},
		{"[fd7a:115c:a1e0::9b3b:f976]:1234", "tailscale0", true},
		{"100.64.0.99:1234", "tailscale0", false},
		{"100.66.249.117:1234", "eth0", false},
		{"10.73.0.50:1234", "eth0", false},
		{"100.66.249.117:1234", "", false},
	} {
		r := httptest.NewRequest(http.MethodPost, "http://panhandler:8080/api/egress", strings.NewReader(`{"mode":"direct"}`))
		r.RemoteAddr = tc.peer
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("X-Forwarded-For", "100.66.249.117")
		r = r.WithContext(context.WithValue(r.Context(), ingressKey{}, tc.device))
		n := &NM{directPeers: []string{"100.66.249.117", "fd7a:115c:a1e0::9b3b:f976"}}
		if got := n.canUseDirect(r); got != tc.want {
			t.Fatalf("peer %s on %s: %v, want %v", tc.peer, tc.device, got, tc.want)
		}
		if !tc.want {
			w := httptest.NewRecorder()
			routes(n).ServeHTTP(w, r)
			if w.Code != http.StatusForbidden {
				t.Fatalf("unauthorized downgrade status %d", w.Code)
			}
		}
	}
}

func TestEgressRejectsInvalidModesAndOrigins(t *testing.T) {
	for _, tc := range []struct {
		mode, origin string
		want         int
	}{
		{"automatic", "", http.StatusBadRequest},
		{"", "", http.StatusBadRequest},
		{"tor", "http://attacker.example", http.StatusForbidden},
		{"direct", "http://attacker.example", http.StatusForbidden},
	} {
		r := httptest.NewRequest(http.MethodPost, "http://panhandler:8080/api/egress", strings.NewReader(`{"mode":"`+tc.mode+`"}`))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Origin", tc.origin)
		w := httptest.NewRecorder()
		routes(&NM{}).ServeHTTP(w, r)
		if w.Code != tc.want {
			t.Fatalf("mode %q origin %q: status %d, want %d", tc.mode, tc.origin, w.Code, tc.want)
		}
	}
}
