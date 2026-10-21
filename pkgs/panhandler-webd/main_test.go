package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAllowedHost(t *testing.T) {
	for _, tc := range []struct {
		host string
		want bool
	}{
		{"panhandler:8080", true},
		{"panhandler-locked:8080", true},
		{"10.73.0.1:8080", true},
		{"[fd7a:115c:a1e0::1]:8080", true},
		{"panhandler.attacker.example:8080", false},
		{"panhandler.example.ts.net.attacker.example:8080", false},
		{"attacker.example:8080", false},
		{"", false},
	} {
		t.Run(tc.host, func(t *testing.T) {
			if got := allowedHost(tc.host); got != tc.want {
				t.Fatalf("allowedHost(%q) = %v, want %v", tc.host, got, tc.want)
			}
		})
	}
}

func TestBrowserMutationOrigin(t *testing.T) {
	for _, tc := range []struct {
		name, origin, site string
		want               int
	}{
		{"same origin", "http://panhandler:8080", "same-origin", http.StatusNotFound},
		{"CLI without browser headers", "", "", http.StatusNotFound},
		{"cross origin", "http://attacker.example", "cross-site", http.StatusForbidden},
		{"same site different origin", "http://other.panhandler", "same-site", http.StatusForbidden},
		{"null origin", "null", "", http.StatusForbidden},
		{"wrong scheme", "https://panhandler:8080", "", http.StatusForbidden},
		{"wrong port", "http://panhandler:8081", "", http.StatusForbidden},
		{"origin with path", "http://panhandler:8080/forged", "", http.StatusForbidden},
		{"cross-site without origin", "", "cross-site", http.StatusForbidden},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "http://panhandler:8080/api/no-such-endpoint", strings.NewReader(`{}`))
			if tc.origin != "" {
				r.Header.Set("Origin", tc.origin)
			}
			if tc.site != "" {
				r.Header.Set("Sec-Fetch-Site", tc.site)
			}
			r.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			routes(nil).ServeHTTP(w, r)
			if w.Code != tc.want {
				t.Fatalf("status = %d, want %d", w.Code, tc.want)
			}
		})
	}
}

func TestConfiguredHostnamesAreExact(t *testing.T) {
	for _, host := range []string{"panhandler.example.ts.net:8080", "panhandler.example.ts.net.attacker.example:8080"} {
		r := httptest.NewRequest(http.MethodGet, "http://"+host+"/api/no-such-endpoint", nil)
		w := httptest.NewRecorder()
		routes(nil, "panhandler.example.ts.net").ServeHTTP(w, r)
		want := http.StatusNotFound
		if strings.Contains(host, "attacker") {
			want = http.StatusForbidden
		}
		if w.Code != want {
			t.Fatalf("%s: status = %d, want %d", host, w.Code, want)
		}
	}
}
