package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPortalBypassRejectsNonCableClients(t *testing.T) {
	for _, remote := range []string{"100.66.249.117:1234", "[fd7a:115c:a1e0::1]:1234", "192.168.1.2:1234", "10.73.0.1:1234"} {
		t.Run(remote, func(t *testing.T) {
			n, _ := privateNM(t, nil, false, false)
			r := httptest.NewRequest(http.MethodPost, "http://panhandler:8080/api/portal/bypass", strings.NewReader(`{"enable":true}`))
			r.RemoteAddr = remote
			r.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			routes(n).ServeHTTP(w, r)
			if w.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400", w.Code)
			}
		})
	}
}

func TestSafePortalURL(t *testing.T) {
	for in, want := range map[string]string{
		"https://secure.11os.com/ElevenOS/Portal/?UI=043976&NI=0050e8": "https://secure.11os.com/ElevenOS/Portal/?UI=043976&NI=0050e8",
		"http://10.0.0.1/login":        "http://10.0.0.1/login",
		"javascript:alert(1)":          "",
		"file:///etc/passwd":           "",
		"https://user:pw@evil.example": "",
		"//no-scheme.example":          "",
		"":                             "",
	} {
		if got := safePortalURL(in); got != want {
			t.Errorf("safePortalURL(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestReadProbe(t *testing.T) {
	dir := t.TempDir()
	probePath = filepath.Join(dir, "state.json")
	if got := readProbe().Verdict; got != "unknown" {
		t.Fatalf("missing file: verdict %q, want unknown", got)
	}
	os.WriteFile(probePath, []byte(`{"verdict":"portal","portalUrl":"javascript:x","checkedAt":"t"}`), 0o644)
	if p := readProbe(); p.Verdict != "portal" || p.PortalURL != "" {
		t.Fatalf("got %+v, want portal with the URL dropped", p)
	}
	os.WriteFile(probePath, []byte(`{"verdict":"pwned"}`), 0o644)
	if got := readProbe().Verdict; got != "unknown" {
		t.Fatalf("bad verdict: %q, want unknown", got)
	}
}
