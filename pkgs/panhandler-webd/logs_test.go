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
)

func fakeJournalctl(t *testing.T, out string) string {
	t.Helper()
	dir := t.TempDir()
	data := filepath.Join(dir, "out")
	os.WriteFile(data, []byte(out), 0o644)
	p := filepath.Join(dir, "journalctl")
	os.WriteFile(p, []byte("#!/bin/sh\necho \"$@\" > "+dir+"/args\ncat "+data+"\n"), 0o755)
	return p
}

func TestLogsStreamJournalAsSSE(t *testing.T) {
	jc := fakeJournalctl(t, `{"_SYSTEMD_UNIT":"blocky.service","__REALTIME_TIMESTAMP":"1763236212000000","PRIORITY":"3","MESSAGE":"upstream \u001b[2Jdown"}
not json
{"SYSLOG_IDENTIFIER":"NetworkManager","__REALTIME_TIMESTAMP":"1763236213000000","PRIORITY":"6","MESSAGE":[104,105,255]}
`)
	l, err := NewLogs(jc, []string{"blocky.service", "NetworkManager.service"}, 1)
	if err != nil {
		t.Fatal(err)
	}
	n := &NM{logs: l}
	r := httptest.NewRequest(http.MethodGet, "http://panhandler:8080/api/logs", nil)
	r = r.WithContext(context.WithValue(r.Context(), ingressKey{}, "eth0"))
	w := httptest.NewRecorder()
	routes(n).ServeHTTP(w, r)
	if w.Code != 200 || w.Header().Get("Content-Type") != "text/event-stream" {
		t.Fatalf("status %d, type %q", w.Code, w.Header().Get("Content-Type"))
	}
	var got []LogEntry
	for _, ev := range strings.Split(strings.TrimSpace(w.Body.String()), "\n\n") {
		data, ok := strings.CutPrefix(ev, "event: log\ndata: ")
		if !ok {
			t.Fatalf("malformed event %q", ev)
		}
		var e LogEntry
		if err := json.Unmarshal([]byte(data), &e); err != nil {
			t.Fatal(err)
		}
		got = append(got, e)
	}
	want := []LogEntry{
		{Unit: "blocky", Timestamp: "2025-11-15T19:50:12Z", Priority: "err", Message: "upstream [2Jdown"},
		{Unit: "NetworkManager", Timestamp: "2025-11-15T19:50:13Z", Priority: "info", Message: "hi�"},
	}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("got %+v\nwant %+v", got, want)
	}
	args, _ := os.ReadFile(filepath.Join(filepath.Dir(jc), "args"))
	if !strings.Contains(string(args), "--unit=blocky.service --unit=NetworkManager.service") {
		t.Fatalf("journalctl args %q", args)
	}
}

func TestLogsRequireCableOrManagementPeer(t *testing.T) {
	l, _ := NewLogs(fakeJournalctl(t, ""), []string{"blocky.service"}, 1)
	n := &NM{logs: l, directPeers: []string{"100.66.249.117"}}
	for _, tc := range []struct {
		peer, device string
		want         int
	}{
		{"10.73.0.133:1", "eth0", 200},
		{"100.66.249.117:1", "tailscale0", 200},
		{"100.64.0.99:1", "tailscale0", http.StatusForbidden},
		{"100.66.249.117:1", "", http.StatusForbidden},
	} {
		r := httptest.NewRequest(http.MethodGet, "http://panhandler:8080/api/logs", nil)
		r.RemoteAddr = tc.peer
		r = r.WithContext(context.WithValue(r.Context(), ingressKey{}, tc.device))
		w := httptest.NewRecorder()
		routes(n).ServeHTTP(w, r)
		if w.Code != tc.want {
			t.Fatalf("%s on %q: status %d, want %d", tc.peer, tc.device, w.Code, tc.want)
		}
	}
}

func TestLogsCapStreamsAndUnitNames(t *testing.T) {
	if _, err := NewLogs("journalctl", []string{"--since=yesterday"}, 1); err == nil {
		t.Fatal("option-looking unit accepted")
	}
	l, _ := NewLogs("journalctl", []string{"blocky.service"}, 1)
	l.slots <- struct{}{}
	w := httptest.NewRecorder()
	l.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/logs", nil))
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status %d with no free slot", w.Code)
	}
}
