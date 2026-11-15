package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDevicesMergeLeasesNeighborsAndVendors(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	inv := &Inventory{
		Leases: write("leases", "1794853810 BC:FC:E7:D4:92:51 10.73.0.133 volnix 01:bc:fc:e7:d4:92:51\n"+
			"1794853000 7a:33:c6:76:66:50 10.73.0.60 \x1b[31mevil\x1b[0m *\n"+
			"garbage line\n"),
		ARP: write("arp", "IP address       HW type     Flags       HW address            Mask     Device\n"+
			"10.73.0.133      0x1         0x2         bc:fc:e7:d4:92:51     *        eth0\n"+
			"10.73.0.9        0x1         0x2         00:11:22:33:44:55     *        eth0\n"+
			"10.73.0.10       0x1         0x0         00:11:22:33:44:66     *        eth0\n"+
			"10.0.0.4         0x1         0x2         00:90:0b:97:81:ef     *        wlan0\n"),
		OUI: write("oui", "BCFCE7 ASUSTek Computer\n001122 Cimsys\n# comment\n"),
		Dev: "eth0",
	}
	devs, err := inv.Devices()
	if err != nil {
		t.Fatal(err)
	}
	if len(devs) != 3 {
		t.Fatalf("got %d devices, want 3 (wlan0 and incomplete neighbors excluded): %+v", len(devs), devs)
	}
	byIP := map[string]Device{}
	for _, d := range devs {
		byIP[d.IP] = d
	}
	if d := byIP["10.73.0.133"]; d.Hostname != "volnix" || d.Vendor != "ASUSTek Computer" || !d.Online || d.LeaseExpires != "2026-11-16T18:30:10Z" {
		t.Fatalf("leased online device: %+v", d)
	}
	if d := byIP["10.73.0.60"]; d.Vendor != "randomized" || d.Online || d.Hostname != "[31mevil[0m" {
		t.Fatalf("randomized offline device: %+v", d)
	}
	if d := byIP["10.73.0.9"]; d.Vendor != "Cimsys" || !d.Online || d.LeaseExpires != "" {
		t.Fatalf("static neighbor: %+v", d)
	}
	if devs[0].IP != "10.73.0.9" {
		t.Fatalf("not sorted by IP: %+v", devs)
	}
}

func TestDevicesWithoutLeaseFile(t *testing.T) {
	arp := filepath.Join(t.TempDir(), "arp")
	os.WriteFile(arp, []byte("header\n"), 0o644)
	devs, err := (&Inventory{Leases: "/nonexistent", ARP: arp, Dev: "eth0"}).Devices()
	if err != nil || devs == nil || len(devs) != 0 {
		t.Fatalf("got %v, %v; want empty non-nil list", devs, err)
	}
}
