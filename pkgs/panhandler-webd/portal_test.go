package main

import (
	"net/http"
	"net/http/httptest"
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
