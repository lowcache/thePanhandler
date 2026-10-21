package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/godbus/dbus/v5"
)

type Egress struct {
	Mode         string `json:"mode"`
	CanUseDirect bool   `json:"canUseDirect"`
}

type ingressKey struct{}
type ingressConn struct {
	net.Conn
	device string
}
type ingressListener struct {
	net.Listener
	device string
}

func (l ingressListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return &ingressConn{Conn: c, device: l.device}, nil
}

func ingressContext(ctx context.Context, c net.Conn) context.Context {
	if c, ok := c.(*ingressConn); ok {
		return context.WithValue(ctx, ingressKey{}, c.device)
	}
	return ctx
}

func (n *NM) canUseDirect(r *http.Request) bool {
	if n == nil || r.Context().Value(ingressKey{}) != "tailscale0" {
		return false
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	for _, peer := range n.directPeers {
		if ip != nil && ip.Equal(net.ParseIP(peer)) {
			return true
		}
	}
	return false
}

func logEgress(r *http.Request, mode, result string) {
	log.Printf("egress: mode=%s result=%s peer=%s ingress=%v", mode, result, r.RemoteAddr, r.Context().Value(ingressKey{}))
}

func egressMode() (Egress, error) {
	b, err := os.ReadFile("/run/ph-egress/mode")
	if err != nil {
		return Egress{}, err
	}
	mode := strings.TrimSpace(string(b))
	if mode != "direct" && mode != "tor" {
		return Egress{}, fmt.Errorf("egress mode is unavailable")
	}
	return Egress{Mode: mode}, nil
}

func (n *NM) SetEgressMode(mode string) (Egress, error) {
	if mode != "direct" && mode != "tor" {
		return Egress{}, errBadInput("mode must be direct or tor")
	}
	n.mutation.Lock()
	defer n.mutation.Unlock()
	if current, err := egressMode(); err == nil && current.Mode == mode {
		return current, nil
	}
	var job dbus.ObjectPath
	if err := n.conn.Object(sdDest, sdPath).Call(sdDest+".Manager.StartUnit", 0, "ph-egress-"+mode+".service", "replace").Store(&job); err != nil {
		return Egress{}, err
	}
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); {
		if state, err := egressMode(); err == nil && state.Mode == mode {
			return state, nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return Egress{}, fmt.Errorf("egress switch did not complete; refresh the current mode before browsing")
}
