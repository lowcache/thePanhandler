package main

import (
	"bufio"
	"io"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Device is one downstream client on the cable, from dnsmasq leases and the neighbor table.
type Device struct {
	MAC          string `json:"mac"`
	IP           string `json:"ip"`
	Hostname     string `json:"hostname"`
	Vendor       string `json:"vendor"`
	LeaseExpires string `json:"leaseExpires"`
	Online       bool   `json:"online"`
}

type Inventory struct {
	Leases string // dnsmasq lease file
	ARP    string // /proc/net/arp
	OUI    string // nmap-mac-prefixes; empty = no vendor lookup
	Dev    string // downstream interface
}

// parseLeases reads "<expiry> <mac> <ip> <hostname|*> <client-id|*>" lines.
func parseLeases(r io.Reader) []Device {
	var out []Device
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 4 {
			continue
		}
		mac, err := net.ParseMAC(f[1])
		if err != nil || net.ParseIP(f[2]) == nil {
			continue
		}
		d := Device{MAC: mac.String(), IP: f[2]}
		if f[3] != "*" {
			d.Hostname = printable(f[3], 63)
		}
		if exp, err := strconv.ParseInt(f[0], 10, 64); err == nil && exp > 0 {
			d.LeaseExpires = time.Unix(exp, 0).UTC().Format(time.RFC3339)
		}
		out = append(out, d)
	}
	return out
}

// parseARP returns complete IPv4 neighbors on dev as mac -> ip.
func parseARP(r io.Reader, dev string) map[string]string {
	out := map[string]string{}
	sc := bufio.NewScanner(r)
	sc.Scan() // header
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 6 || f[5] != dev || f[2] != "0x2" {
			continue
		}
		if mac, err := net.ParseMAC(f[3]); err == nil && net.ParseIP(f[0]) != nil {
			out[mac.String()] = f[0]
		}
	}
	return out
}

// vendors scans nmap-mac-prefixes ("AABBCC Vendor Name") for the wanted 24-bit prefixes only.
// Per request, not cached: the file is 1.3 MB and the Pi has 1 GB.
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

// Devices merges leases with live neighbors; a neighbor without a lease (static IP) is listed too.
func (inv *Inventory) Devices() ([]Device, error) {
	var devs []Device
	if f, err := os.Open(inv.Leases); err == nil {
		devs = parseLeases(f)
		f.Close()
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	f, err := os.Open(inv.ARP)
	if err != nil {
		return nil, err
	}
	neigh := parseARP(f, inv.Dev)
	f.Close()
	for i := range devs {
		if ip, ok := neigh[devs[i].MAC]; ok {
			devs[i].Online = ip == devs[i].IP
			delete(neigh, devs[i].MAC)
		}
	}
	for mac, ip := range neigh {
		devs = append(devs, Device{MAC: mac, IP: ip, Online: true})
	}
	want := map[string]bool{}
	for _, d := range devs {
		if p, ok := ouiPrefix(d.MAC); ok {
			want[p] = true
		}
	}
	names := map[string]string{}
	if len(want) > 0 && inv.OUI != "" {
		if f, err := os.Open(inv.OUI); err == nil {
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
	sort.Slice(devs, func(i, j int) bool {
		a, b := net.ParseIP(devs[i].IP).To4(), net.ParseIP(devs[j].IP).To4()
		return string(a) < string(b)
	})
	if devs == nil {
		devs = []Device{}
	}
	return devs, nil
}

// printable keeps client-supplied names to visible ASCII; the hostname comes from the client.
func printable(s string, max int) string {
	var b strings.Builder
	for _, r := range s {
		if r > 0x20 && r < 0x7f && b.Len() < max {
			b.WriteRune(r)
		}
	}
	return b.String()
}
