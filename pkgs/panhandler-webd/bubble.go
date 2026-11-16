package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// Bubble devices join volnix's Wi-Fi AP and reach the Pi masqueraded as volnix, so the Pi
// cannot see them. volnix reports its DHCP leases instead; the list lives in RAM only.
const (
	maxBubbleBody    = 16 << 10
	maxBubbleDevices = 64
)

type Device struct {
	MAC          string `json:"mac"`
	IP           string `json:"ip"`
	Hostname     string `json:"hostname"`
	Vendor       string `json:"vendor"`
	LeaseExpires string `json:"leaseExpires"`
	Online       bool   `json:"online"`
}

type DeviceReport struct {
	ReportedAt string   `json:"reportedAt"` // Pi clock at receipt; "" = never reported
	Devices    []Device `json:"devices"`
}

type Bubble struct {
	OUI       string   // nmap-mac-prefixes; empty = no vendor names
	Reporters []string // tailnet IPs allowed to report (volnix)

	mu     sync.Mutex
	report DeviceReport
}

func (b *Bubble) Report() DeviceReport {
	b.mu.Lock()
	defer b.mu.Unlock()
	r := b.report
	if r.Devices == nil {
		r.Devices = []Device{}
	}
	return r
}

// canReport: WireGuard proves the source over tailscale0; the cable can't (bubble devices
// arrive there masqueraded as volnix).
func (b *Bubble) canReport(r *http.Request) bool {
	if b == nil || r.Context().Value(ingressKey{}) != tailnetDev {
		return false
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	ip := net.ParseIP(host)
	if err != nil || ip == nil {
		return false
	}
	for _, peer := range b.Reporters {
		if ip.Equal(net.ParseIP(peer)) {
			return true
		}
	}
	return false
}

// Accept validates a report from volnix; client-supplied hostnames are hostile input.
func (b *Bubble) Accept(r io.Reader, now time.Time) error {
	var in struct {
		Devices []struct {
			MAC          string `json:"mac"`
			IP           string `json:"ip"`
			Hostname     string `json:"hostname"`
			LeaseExpires int64  `json:"leaseExpires"` // unix seconds; 0 = none
			Online       bool   `json:"online"`
		} `json:"devices"`
	}
	dec := json.NewDecoder(io.LimitReader(r, maxBubbleBody+1))
	if err := dec.Decode(&in); err != nil {
		return errBadInput("malformed device report")
	}
	if len(in.Devices) > maxBubbleDevices {
		return errBadInput("too many devices")
	}
	seen := map[string]bool{}
	devs := make([]Device, 0, len(in.Devices))
	for _, d := range in.Devices {
		mac, err := net.ParseMAC(d.MAC)
		ip := net.ParseIP(d.IP).To4()
		if err != nil || len(mac) != 6 || ip == nil {
			return errBadInput("invalid MAC or IPv4 address")
		}
		if seen[mac.String()] {
			continue
		}
		seen[mac.String()] = true
		dev := Device{MAC: mac.String(), IP: ip.String(), Hostname: printable(d.Hostname, 63), Online: d.Online}
		if d.LeaseExpires > 0 && d.LeaseExpires < 1<<40 {
			dev.LeaseExpires = time.Unix(d.LeaseExpires, 0).UTC().Format(time.RFC3339)
		}
		devs = append(devs, dev)
	}
	b.name(devs)
	sort.Slice(devs, func(i, j int) bool {
		return string(net.ParseIP(devs[i].IP).To4()) < string(net.ParseIP(devs[j].IP).To4())
	})
	b.mu.Lock()
	b.report = DeviceReport{ReportedAt: now.UTC().Format(time.RFC3339), Devices: devs}
	b.mu.Unlock()
	return nil
}

func (b *Bubble) name(devs []Device) {
	want := map[string]bool{}
	for _, d := range devs {
		if p, ok := ouiPrefix(d.MAC); ok {
			want[p] = true
		}
	}
	names := map[string]string{}
	if len(want) > 0 && b.OUI != "" {
		if f, err := os.Open(b.OUI); err == nil {
			names = vendors(f, want)
			f.Close()
		}
	}
	for i := range devs {
		if p, ok := ouiPrefix(devs[i].MAC); ok {
			devs[i].Vendor = names[p]
		} else {
			devs[i].Vendor = "randomized"
		}
	}
}

// vendors scans nmap-mac-prefixes ("AABBCC Vendor Name") for the wanted 24-bit prefixes only.
// Per report, not cached: the file is 1.3 MB and the Pi has 1 GB.
func vendors(r io.Reader, want map[string]bool) map[string]string {
	out := map[string]string{}
	sc := bufio.NewScanner(r)
	for sc.Scan() && len(out) < len(want) {
		line := sc.Text()
		if len(line) < 8 || line[6] != ' ' {
			continue
		}
		if p := strings.ToUpper(line[:6]); want[p] {
			out[p] = line[7:]
		}
	}
	return out
}

func ouiPrefix(mac string) (string, bool) {
	hw, err := net.ParseMAC(mac)
	if err != nil || len(hw) < 3 || hw[0]&0x02 != 0 { // locally administered = randomized
		return "", false
	}
	return strings.ToUpper(strings.ReplaceAll(mac, ":", "")[:6]), true
}

// printable keeps client-supplied names to visible ASCII.
func printable(s string, max int) string {
	var b strings.Builder
	for _, r := range s {
		if r > 0x20 && r < 0x7f && b.Len() < max {
			b.WriteRune(r)
		}
	}
	return b.String()
}
