// panhandler-webd: Wi-Fi control plane for thePanhandler (NetworkManager over D-Bus + embedded SPA).
package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"flag"
	"io/fs"
	"log"
	"net"
	"net/http"
	"net/url"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

//go:embed all:dist
var dist embed.FS

type errBadInput string

func (e errBadInput) Error() string { return string(e) }

var errTimeout = errors.New("timed out waiting for the connection to come up")

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, err error) {
	code := http.StatusBadGateway
	var bad errBadInput
	switch {
	case errors.As(err, &bad):
		code = http.StatusBadRequest
	case errors.Is(err, errProtected):
		code = http.StatusConflict
	case errors.Is(err, errTimeout):
		code = http.StatusGatewayTimeout
	}
	log.Printf("api error (%d): %v", code, err)
	writeJSON(w, code, map[string]string{"error": err.Error()})
}

func validSSID(s string) error {
	if len(s) < 1 || len(s) > 32 || !utf8.ValidString(s) {
		return errBadInput("SSID must be 1-32 bytes of UTF-8")
	}
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			return errBadInput("SSID contains control characters")
		}
	}
	return nil
}

func validPassphrase(p string) error {
	if p == "" {
		return nil
	}
	if len(p) == 64 && strings.Trim(strings.ToLower(p), "0123456789abcdef") == "" {
		return nil
	}
	if len(p) < 8 || len(p) > 63 {
		return errBadInput("passphrase must be 8-63 characters (or 64 hex digits)")
	}
	for _, r := range p {
		if r < 0x20 || r > 0x7e {
			return errBadInput("passphrase must be printable ASCII")
		}
	}
	return nil
}

// decode reads a small JSON body; requiring application/json forces a CORS preflight cross-origin.
func decode(r *http.Request, v any) error {
	if !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		return errBadInput("Content-Type must be application/json")
	}
	if err := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 4096)).Decode(v); err != nil {
		return errBadInput("malformed JSON body")
	}
	return nil
}

// Names must be exact: a panhandler.* prefix also matches attacker-owned domains.
func allowedHost(host string, names ...string) bool {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	host = strings.TrimSuffix(strings.ToLower(strings.Trim(host, "[]")), ".")
	if net.ParseIP(host) != nil || host == "panhandler" || host == "panhandler-locked" {
		return true
	}
	for _, name := range names {
		if name != "" && host == strings.TrimSuffix(strings.ToLower(name), ".") {
			return true
		}
	}
	return false
}

func allowedMutation(r *http.Request) bool {
	if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" && site != "none" {
		return false
	}
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true // CLI clients remain subject to the trusted-interface boundary.
	}
	u, err := url.Parse(origin)
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	return err == nil && u.Scheme == scheme && strings.EqualFold(u.Host, r.Host) &&
		u.User == nil && u.Path == "" && u.RawQuery == "" && u.Fragment == ""
}

func routes(nm *NM, allowedNames ...string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/egress", func(w http.ResponseWriter, r *http.Request) {
		mode, err := egressMode()
		if err != nil {
			writeErr(w, err)
			return
		}
		mode.CanUseDirect = nm.canUseDirect(r)
		writeJSON(w, 200, mode)
	})
	mux.HandleFunc("POST /api/egress", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Mode string `json:"mode"`
		}
		if err := decode(r, &req); err != nil {
			writeErr(w, err)
			return
		}
		if req.Mode == "direct" && !nm.canUseDirect(r) {
			logEgress(r, req.Mode, "denied")
			http.Error(w, "Use Direct requires an approved management device over Tailscale", http.StatusForbidden)
			return
		}
		logEgress(r, req.Mode, "requested")
		mode, err := nm.SetEgressMode(req.Mode)
		if err != nil {
			logEgress(r, req.Mode, "failed")
			writeErr(w, err)
			return
		}
		logEgress(r, req.Mode, "applied")
		mode.CanUseDirect = nm.canUseDirect(r)
		writeJSON(w, 200, mode)
	})
	mux.HandleFunc("GET /api/wifi/status", func(w http.ResponseWriter, r *http.Request) {
		st, err := nm.Status()
		if err != nil {
			writeErr(w, err)
			return
		}
		writeJSON(w, 200, st)
	})
	mux.HandleFunc("GET /api/wifi/scan", func(w http.ResponseWriter, r *http.Request) {
		aps, err := nm.Scan(r.URL.Query().Get("refresh") == "1")
		if err != nil {
			writeErr(w, err)
			return
		}
		writeJSON(w, 200, aps)
	})
	mux.HandleFunc("GET /api/wifi/saved", func(w http.ResponseWriter, r *http.Request) {
		saved, err := nm.Saved()
		if err != nil {
			writeErr(w, err)
			return
		}
		if saved == nil {
			saved = []Saved{}
		}
		writeJSON(w, 200, saved)
	})
	mux.HandleFunc("POST /api/wifi/connect", func(w http.ResponseWriter, r *http.Request) {
		var req ConnectRequest
		if err := decode(r, &req); err != nil {
			writeErr(w, err)
			return
		}
		if err := validSSID(req.SSID); err != nil {
			writeErr(w, err)
			return
		}
		if err := validPassphrase(req.Passphrase); err != nil {
			writeErr(w, err)
			return
		}
		st, storage, err := nm.Connect(req)
		if err != nil {
			writeErr(w, err)
			return
		}
		log.Printf("connected to %q (%s)", req.SSID, storage)
		writeJSON(w, 200, map[string]string{"status": "connected", "ssid": st.SSID, "ip": st.IP, "storage": storage})
	})
	mux.HandleFunc("POST /api/wifi/forget", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ SSID string }
		if err := decode(r, &req); err != nil {
			writeErr(w, err)
			return
		}
		if err := validSSID(req.SSID); err != nil {
			writeErr(w, err)
			return
		}
		if err := nm.Forget(req.SSID); err != nil {
			writeErr(w, err)
			return
		}
		log.Printf("forgot %q", req.SSID)
		writeJSON(w, 200, map[string]string{"status": "forgotten", "ssid": req.SSID})
	})
	mux.HandleFunc("POST /api/portal/bypass", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Enable bool }
		if err := decode(r, &req); err != nil {
			writeErr(w, err)
			return
		}
		if err := nm.SetBypass(req.Enable, r.RemoteAddr); err != nil {
			writeErr(w, err)
			return
		}
		log.Printf("portal bypass enable=%v", req.Enable)
		writeJSON(w, 200, nm.Bypass())
	})
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 404, map[string]string{"error": "no such endpoint"})
	})

	static, _ := fs.Sub(dist, "dist")
	files := http.FileServerFS(static)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// SPA fallback: unknown client routes get index.html.
		if _, err := fs.Stat(static, strings.TrimPrefix(r.URL.Path, "/")); err != nil || r.URL.Path == "/" {
			r.URL.Path = "/"
		}
		files.ServeHTTP(w, r)
	})

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !allowedHost(r.Host, allowedNames...) {
			http.Error(w, "forbidden host", http.StatusForbidden)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead && r.Method != http.MethodOptions && !allowedMutation(r) {
			http.Error(w, "forbidden origin", http.StatusForbidden)
			return
		}
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		mux.ServeHTTP(w, r)
	})
}

// serveOn keeps a listener SO_BINDTODEVICE'd to dev, rebinding when the device is recreated
// (tailscale0 comes and goes with the locked/main identity swap). Never wildcard-binds wlan0.
func serveOn(srv *http.Server, dev, port string) {
	var ln net.Listener
	var idx int
	for {
		ifc, err := net.InterfaceByName(dev)
		switch {
		case err != nil && ln != nil:
			ln.Close()
			ln, idx = nil, 0
		case err == nil && ifc.Index != idx:
			if ln != nil {
				ln.Close()
			}
			lc := net.ListenConfig{Control: func(_, _ string, c syscall.RawConn) error {
				var serr error
				if err := c.Control(func(fd uintptr) {
					serr = syscall.SetsockoptString(int(fd), syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, dev)
				}); err != nil {
					return err
				}
				return serr
			}}
			if l, err := lc.Listen(context.Background(), "tcp", ":"+port); err != nil {
				log.Printf("listen on %s: %v", dev, err)
			} else {
				ln, idx = l, ifc.Index
				log.Printf("listening on %s:%s", dev, port)
				go srv.Serve(ingressListener{Listener: l, device: dev})
			}
		}
		time.Sleep(5 * time.Second)
	}
}

func main() {
	devs := flag.String("listen-devs", "eth0,tailscale0", "comma-separated trusted interfaces to serve on")
	port := flag.String("port", "8080", "TCP port")
	allowedNames := flag.String("allowed-hosts", "", "comma-separated exact additional management hostnames")
	directPeers := flag.String("direct-peers", "", "comma-separated exact Tailscale IPs allowed to choose Direct mode")
	iface := flag.String("wifi", "wlan0", "NetworkManager Wi-Fi interface")
	persistDir := flag.String("persist-dir", "/persist/nm/system-connections", "NM keyfile dir")
	persistMount := flag.String("persist-mount", "/persist", "LUKS mount; mounted = unlocked")
	flag.Parse()

	nm, err := NewNM(*iface, *persistDir, *persistMount)
	if err != nil {
		log.Fatalf("system bus: %v", err)
	}
	go nm.watchBypass()
	for _, peer := range strings.Split(*directPeers, ",") {
		if peer == "" {
			continue
		}
		if net.ParseIP(peer) == nil {
			log.Fatalf("invalid direct-mode management IP %q", peer)
		}
		nm.directPeers = append(nm.directPeers, peer)
	}
	srv := &http.Server{
		ConnContext:       ingressContext,
		Handler:           routes(nm, strings.Split(*allowedNames, ",")...),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	for _, d := range strings.Split(*devs, ",") {
		if d = strings.TrimSpace(d); d == *iface {
			log.Fatalf("refusing to serve on the uplink %s", d)
		} else if d != "" {
			go serveOn(srv, d, *port)
		}
	}
	select {}
}
