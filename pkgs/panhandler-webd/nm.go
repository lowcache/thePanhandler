package main

import (
	"errors"
	"fmt"
	"net"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/godbus/dbus/v5"
)

const (
	nmDest      = "org.freedesktop.NetworkManager"
	nmPath      = dbus.ObjectPath("/org/freedesktop/NetworkManager")
	nmSettings  = dbus.ObjectPath("/org/freedesktop/NetworkManager/Settings")
	ifDevice    = nmDest + ".Device"
	ifWireless  = nmDest + ".Device.Wireless"
	ifAP        = nmDest + ".AccessPoint"
	ifActive    = nmDest + ".Connection.Active"
	ifSettingsC = nmDest + ".Settings.Connection"

	// Profiles the UI may not delete (rendered from /base at boot; the locked-mode lifeline).
	protectedID = "ph-enroll"
)

// NM 802.11 AP security flags (NM80211ApSecurityFlags / NM80211ApFlags).
const (
	apFlagPrivacy = 0x1
	secPSK        = 0x100
	secEAP        = 0x200
	secSAE        = 0x400
	secOWE        = 0x800
)

var errProtected = errors.New("profile is protected")

type NM struct {
	directPeers  []string
	mutation     sync.Mutex
	conn         *dbus.Conn
	iface        string
	persistDir   string
	persistMount string
}

type ConnectRequest struct {
	SSID       string `json:"ssid"`
	Passphrase string `json:"passphrase"`
	BSSID      string `json:"bssid"`
	Security   string `json:"security"`
}

type AP struct {
	SSID      string `json:"ssid"`
	BSSID     string `json:"bssid"`
	Signal    uint8  `json:"signal"`
	Frequency uint32 `json:"frequency"`
	Security  string `json:"security"`
	InUse     bool   `json:"inUse"`
	Saved     bool   `json:"saved"`
}

type Saved struct {
	SSID        string `json:"ssid"`
	ID          string `json:"id"`
	Storage     string `json:"storage"`
	Protected   bool   `json:"protected"`
	Autoconnect bool   `json:"autoconnect"`
	path        dbus.ObjectPath
}

type Status struct {
	Connected    bool   `json:"connected"`
	SSID         string `json:"uplinkSsid"`
	BSSID        string `json:"bssid"`
	IP           string `json:"ip"`
	Signal       uint8  `json:"signal"`
	Frequency    uint32 `json:"frequency"`
	State        string `json:"state"`
	Connectivity string `json:"connectivity"`
	Persist      string `json:"persist"`
	PortalBypass Bypass `json:"portalBypass"`
}

func NewNM(iface, persistDir, persistMount string) (*NM, error) {
	c, err := dbus.ConnectSystemBus()
	if err != nil {
		return nil, err
	}
	return &NM{conn: c, iface: iface, persistDir: persistDir, persistMount: persistMount}, nil
}

func (n *NM) obj(p dbus.ObjectPath) dbus.BusObject { return n.conn.Object(nmDest, p) }

func (n *NM) prop(p dbus.ObjectPath, name string) (dbus.Variant, error) {
	return n.obj(p).GetProperty(name)
}

func (n *NM) device() (dbus.ObjectPath, error) {
	var dev dbus.ObjectPath
	err := n.obj(nmPath).Call(nmDest+".GetDeviceByIpIface", 0, n.iface).Store(&dev)
	return dev, err
}

// persistent reports whether /persist is mounted (unlocked). The keyfile dir alone proves
// nothing: NM's tmpfiles rule creates it on the tmpfs underneath at boot.
func (n *NM) persistent() bool {
	var m, parent syscall.Stat_t
	if syscall.Stat(n.persistMount, &m) != nil || syscall.Stat(filepath.Dir(n.persistMount), &parent) != nil {
		return false
	}
	return m.Dev != parent.Dev
}

func security(flags, wpa, rsn uint32) string {
	all := wpa | rsn
	switch {
	case all&secEAP != 0:
		return "enterprise"
	case rsn&secPSK != 0:
		return "wpa2-psk"
	case rsn&secSAE != 0:
		return "wpa3-sae"
	case wpa&secPSK != 0:
		return "wpa-psk"
	case rsn&secOWE != 0:
		return "owe"
	case flags&apFlagPrivacy != 0:
		return "wep"
	}
	return "open"
}

func (n *NM) apInfo(p dbus.ObjectPath) (AP, error) {
	var props map[string]dbus.Variant
	if err := n.obj(p).Call("org.freedesktop.DBus.Properties.GetAll", 0, ifAP).Store(&props); err != nil {
		return AP{}, err
	}
	u32 := func(k string) uint32 { v, _ := props[k].Value().(uint32); return v }
	ssid, _ := props["Ssid"].Value().([]byte)
	bssid, _ := props["HwAddress"].Value().(string)
	strength, _ := props["Strength"].Value().(uint8)
	return AP{
		SSID:      string(ssid),
		BSSID:     strings.ToLower(bssid),
		Signal:    strength,
		Frequency: u32("Frequency"),
		Security:  security(u32("Flags"), u32("WpaFlags"), u32("RsnFlags")),
	}, nil
}

// Scan returns visible APs deduped by SSID (strongest wins). refresh forces a radio rescan.
func (n *NM) Scan(refresh bool) ([]AP, error) {
	dev, err := n.device()
	if err != nil {
		return nil, err
	}
	if refresh {
		before, _ := n.prop(dev, ifWireless+".LastScan")
		// "Scanning not allowed" while activating: fall through to the cached list.
		if n.obj(dev).Call(ifWireless+".RequestScan", 0, map[string]dbus.Variant{}).Err == nil {
			for deadline := time.Now().Add(8 * time.Second); time.Now().Before(deadline); {
				time.Sleep(400 * time.Millisecond)
				if now, err := n.prop(dev, ifWireless+".LastScan"); err == nil && now.Value() != before.Value() {
					break
				}
			}
		}
	}
	var paths []dbus.ObjectPath
	if err := n.obj(dev).Call(ifWireless+".GetAllAccessPoints", 0).Store(&paths); err != nil {
		return nil, err
	}
	activeAP, _ := n.prop(dev, ifWireless+".ActiveAccessPoint")
	saved, _ := n.Saved()
	savedSSID := map[string]bool{}
	for _, s := range saved {
		savedSSID[s.SSID] = true
	}
	best := map[string]AP{}
	for _, p := range paths {
		ap, err := n.apInfo(p)
		if err != nil || ap.SSID == "" {
			continue
		}
		ap.InUse = activeAP.Value() == p
		ap.Saved = savedSSID[ap.SSID]
		if cur, ok := best[ap.SSID]; !ok || ap.InUse || (!cur.InUse && ap.Signal > cur.Signal) {
			best[ap.SSID] = ap
		}
	}
	out := make([]AP, 0, len(best))
	for _, ap := range best {
		out = append(out, ap)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Signal > out[j].Signal })
	return out, nil
}

// Saved lists wifi profiles NM knows about.
func (n *NM) Saved() ([]Saved, error) {
	var paths []dbus.ObjectPath
	if err := n.obj(nmSettings).Call(nmDest+".Settings.ListConnections", 0).Store(&paths); err != nil {
		return nil, err
	}
	var out []Saved
	for _, p := range paths {
		var s map[string]map[string]dbus.Variant
		if err := n.obj(p).Call(ifSettingsC+".GetSettings", 0).Store(&s); err != nil {
			continue
		}
		if t, _ := s["connection"]["type"].Value().(string); t != "802-11-wireless" {
			continue
		}
		id, _ := s["connection"]["id"].Value().(string)
		ssid, _ := s["802-11-wireless"]["ssid"].Value().([]byte)
		auto := true
		if v, ok := s["connection"]["autoconnect"].Value().(bool); ok {
			auto = v
		}
		fn, _ := n.prop(p, ifSettingsC+".Filename")
		file, _ := fn.Value().(string)
		storage := "memory"
		switch {
		case id == protectedID:
			storage = "base"
		case strings.HasPrefix(file, n.persistDir+"/"):
			storage = "disk"
		}
		out = append(out, Saved{SSID: string(ssid), ID: id, Storage: storage, Protected: id == protectedID, Autoconnect: auto, path: p})
	}
	return out, nil
}

var stateNames = map[uint32]string{
	10: "unmanaged", 20: "unavailable", 30: "disconnected", 40: "activating", 50: "activating",
	60: "activating", 70: "activating", 80: "activating", 90: "activating", 100: "activated",
	110: "deactivating", 120: "disconnected",
}

var connectivityNames = map[uint32]string{0: "unknown", 1: "none", 2: "portal", 3: "limited", 4: "full"}

func (n *NM) Status() (Status, error) {
	st := Status{State: "unknown", Connectivity: "unknown", Persist: "locked", PortalBypass: n.Bypass()}
	if n.persistent() {
		st.Persist = "unlocked"
	}
	if v, err := n.prop(nmPath, nmDest+".Connectivity"); err == nil {
		st.Connectivity = connectivityNames[v.Value().(uint32)]
	}
	dev, err := n.device()
	if err != nil {
		return st, err
	}
	if v, err := n.prop(dev, ifDevice+".State"); err == nil {
		if name, ok := stateNames[v.Value().(uint32)]; ok {
			st.State = name
		}
	}
	st.Connected = st.State == "activated"
	if v, err := n.prop(dev, ifWireless+".ActiveAccessPoint"); err == nil {
		if p := v.Value().(dbus.ObjectPath); p != "/" {
			if ap, err := n.apInfo(p); err == nil {
				st.SSID, st.BSSID, st.Signal, st.Frequency = ap.SSID, ap.BSSID, ap.Signal, ap.Frequency
			}
		}
	}
	if v, err := n.prop(dev, ifDevice+".Ip4Config"); err == nil {
		if p := v.Value().(dbus.ObjectPath); p != "/" {
			if ad, err := n.prop(p, nmDest+".IP4Config.AddressData"); err == nil {
				if list, ok := ad.Value().([]map[string]dbus.Variant); ok && len(list) > 0 {
					st.IP, _ = list[0]["address"].Value().(string)
				}
			}
		}
	}
	if !st.Connected && st.State != "activating" {
		st.Connectivity = "none"
	}
	return st, nil
}

// Connect activates a saved profile (empty passphrase) or replaces it with a new one.
func (n *NM) Connect(req ConnectRequest) (Status, string, error) {
	n.mutation.Lock()
	defer n.mutation.Unlock()
	ssid, passphrase := req.SSID, req.Passphrase
	dev, err := n.device()
	if err != nil {
		return Status{}, "", err
	}
	saved, err := n.Saved()
	if err != nil {
		return Status{}, "", err
	}
	var existing *Saved
	for i := range saved {
		if saved[i].SSID == ssid {
			existing = &saved[i]
			break
		}
	}

	var active dbus.ObjectPath
	var created dbus.ObjectPath
	storage := "memory"
	ap := dbus.ObjectPath("/")
	if existing == nil || passphrase != "" || req.BSSID != "" || req.Security != "" {
		ap, err = n.findAP(ssid, req.BSSID, req.Security)
		if err != nil {
			return Status{}, "", err
		}
	}
	if existing != nil && passphrase == "" {
		storage = existing.Storage
		err = n.obj(nmPath).Call(nmDest+".ActivateConnection", 0, existing.path, dev, ap).Store(&active)
	} else {
		if existing != nil && existing.Protected {
			return Status{}, "", errProtected
		}
		sec := req.Security
		if (sec == "open" || sec == "owe") && passphrase != "" {
			return Status{}, "", errBadInput("selected network does not use a passphrase; rescan before connecting")
		}
		settings := map[string]map[string]dbus.Variant{
			"connection":      {"id": dbus.MakeVariant(ssid), "type": dbus.MakeVariant("802-11-wireless"), "autoconnect": dbus.MakeVariant(true)},
			"802-11-wireless": {"ssid": dbus.MakeVariant([]byte(ssid)), "mode": dbus.MakeVariant("infrastructure")},
			"ipv4":            {"method": dbus.MakeVariant("auto")},
		}
		switch sec {
		case "open":
		case "owe":
			settings["802-11-wireless-security"] = map[string]dbus.Variant{"key-mgmt": dbus.MakeVariant("owe")}
		case "wpa3-sae":
			settings["802-11-wireless-security"] = map[string]dbus.Variant{"key-mgmt": dbus.MakeVariant("sae"), "psk": dbus.MakeVariant(passphrase)}
		case "wpa-psk", "wpa2-psk":
			settings["802-11-wireless-security"] = map[string]dbus.Variant{"key-mgmt": dbus.MakeVariant("wpa-psk"), "psk": dbus.MakeVariant(passphrase)}
		default:
			return Status{}, "", fmt.Errorf("unsupported security %q", sec)
		}
		if sec != "open" {
			proto := "rsn"
			if sec == "wpa-psk" {
				proto = "wpa"
			}
			settings["802-11-wireless-security"]["proto"] = dbus.MakeVariant([]string{proto})
		}
		if sec != "open" && sec != "owe" && passphrase == "" {
			return Status{}, "", errBadInput("passphrase required")
		}
		persist := "memory"
		if n.persistent() {
			persist = "disk"
		}
		storage = persist
		var result map[string]dbus.Variant
		err = n.obj(nmPath).Call(nmDest+".AddAndActivateConnection2", 0, settings, dev, ap,
			map[string]dbus.Variant{"persist": dbus.MakeVariant(persist)}).Store(&created, &active, &result)
	}
	if err != nil {
		return Status{}, "", err
	}
	if err := n.waitActive(active, 45*time.Second); err != nil {
		// A fresh profile that never came up (wrong passphrase) must not linger and autoconnect-loop.
		if created != "" {
			n.obj(created).Call(ifSettingsC+".Delete", 0)
		}
		return Status{}, "", err
	}
	if created != "" && existing != nil {
		if err := n.obj(existing.path).Call(ifSettingsC+".Delete", 0).Err; err != nil {
			return Status{}, "", fmt.Errorf("connected, but could not remove previous profile: %w", err)
		}
	}
	st, err := n.Status()
	return st, storage, err
}

func (n *NM) findAP(ssid, bssid, expectedSecurity string) (dbus.ObjectPath, error) {
	mac, err := net.ParseMAC(bssid)
	if err != nil || len(mac) != 6 || expectedSecurity == "" {
		return "", errBadInput("select an AP and its security mode from a fresh scan")
	}
	switch expectedSecurity {
	case "open", "owe", "wpa-psk", "wpa2-psk", "wpa3-sae":
	default:
		return "", errBadInput("unsupported security mode")
	}
	dev, err := n.device()
	if err != nil {
		return "", err
	}
	var paths []dbus.ObjectPath
	if err := n.obj(dev).Call(ifWireless+".GetAllAccessPoints", 0).Store(&paths); err != nil {
		return "", err
	}
	for _, p := range paths {
		if ap, err := n.apInfo(p); err == nil && ap.SSID == ssid && strings.EqualFold(ap.BSSID, bssid) {
			if ap.Security != expectedSecurity {
				return "", errBadInput("AP security changed; rescan before connecting")
			}
			return p, nil
		}
	}
	return "", errBadInput("selected AP is no longer visible; rescan before connecting")
}

func (n *NM) waitActive(active dbus.ObjectPath, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		v, err := n.prop(active, ifActive+".State")
		if err != nil {
			// The active-connection object vanishes when activation fails.
			return errors.New("activation failed (wrong passphrase or AP out of range)")
		}
		switch v.Value().(uint32) {
		case 2: // activated
			return nil
		case 3, 4: // deactivating, deactivated
			return errors.New("activation failed (wrong passphrase or AP out of range)")
		}
		time.Sleep(500 * time.Millisecond)
	}
	return errTimeout
}

func (n *NM) deleteSSID(ssid string) error {
	saved, err := n.Saved()
	if err != nil {
		return err
	}
	found := false
	for _, s := range saved {
		if s.SSID != ssid {
			continue
		}
		if s.Protected {
			return errProtected
		}
		found = true
		if err := n.obj(s.path).Call(ifSettingsC+".Delete", 0).Err; err != nil {
			return err
		}
	}
	if !found {
		return errBadInput("no saved profile for that SSID")
	}
	return nil
}

func (n *NM) Forget(ssid string) error {
	n.mutation.Lock()
	defer n.mutation.Unlock()
	return n.deleteSSID(ssid)
}
