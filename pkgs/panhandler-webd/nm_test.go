package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"

	"github.com/godbus/dbus/v5"
)

const testDev = dbus.ObjectPath("/test/device")
const testOld = dbus.ObjectPath("/test/old")
const testNew = dbus.ObjectPath("/test/new")
const testActive = dbus.ObjectPath("/test/active")

type testSettings = map[string]map[string]dbus.Variant

// The private bus exercises the real NM client without touching the system bus or radio.
type fakeNM struct {
	mu                                sync.Mutex
	aps                               []dbus.ObjectPath
	old, oldDeleted, newDeleted, fail bool
	settings                          testSettings
	selected                          dbus.ObjectPath
	events                            []string
}

func (f *fakeNM) GetDeviceByIpIface(string) (dbus.ObjectPath, *dbus.Error) { return testDev, nil }
func (f *fakeNM) GetAllAccessPoints() ([]dbus.ObjectPath, *dbus.Error)     { return f.aps, nil }
func (f *fakeNM) ListConnections() ([]dbus.ObjectPath, *dbus.Error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.old && !f.oldDeleted {
		return []dbus.ObjectPath{testOld}, nil
	}
	return []dbus.ObjectPath{}, nil
}
func (f *fakeNM) AddAndActivateConnection2(s testSettings, dev, ap dbus.ObjectPath, opts map[string]dbus.Variant) (dbus.ObjectPath, dbus.ObjectPath, map[string]dbus.Variant, *dbus.Error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.settings, f.selected = s, ap
	f.events = append(f.events, "add")
	return testNew, testActive, map[string]dbus.Variant{}, nil
}
func (f *fakeNM) ActivateConnection(profile, dev, ap dbus.ObjectPath) (dbus.ObjectPath, *dbus.Error) {
	return testActive, nil
}

type fakeProfile struct {
	f   *fakeNM
	old bool
}

func (p *fakeProfile) GetSettings() (testSettings, *dbus.Error) {
	return testSettings{"connection": {"id": dbus.MakeVariant("Hotel"), "type": dbus.MakeVariant("802-11-wireless")}, "802-11-wireless": {"ssid": dbus.MakeVariant([]byte("Hotel"))}}, nil
}
func (p *fakeProfile) Delete() *dbus.Error {
	p.f.mu.Lock()
	defer p.f.mu.Unlock()
	if p.old {
		p.f.oldDeleted = true
		p.f.events = append(p.f.events, "delete-old")
	} else {
		p.f.newDeleted = true
	}
	return nil
}

type fakeProps struct {
	f      *fakeNM
	values map[string]map[string]dbus.Variant
	active bool
}

func (p *fakeProps) Get(iface, name string) (dbus.Variant, *dbus.Error) {
	if p.active {
		p.f.mu.Lock()
		defer p.f.mu.Unlock()
		p.f.events = append(p.f.events, "state")
		state := uint32(2)
		if p.f.fail {
			state = 4
		}
		return dbus.MakeVariant(state), nil
	}
	v, ok := p.values[iface][name]
	if !ok {
		return dbus.Variant{}, dbus.NewError("org.freedesktop.DBus.Error.UnknownProperty", nil)
	}
	return v, nil
}
func (p *fakeProps) GetAll(iface string) (map[string]dbus.Variant, *dbus.Error) {
	return p.values[iface], nil
}

func privateNM(t *testing.T, aps []AP, old, fail bool) (*NM, *fakeNM) {
	t.Helper()
	config := filepath.Join(t.TempDir(), "bus.conf")
	if err := os.WriteFile(config, []byte(`<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen><auth>EXTERNAL</auth><policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>`), 0600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("dbus-daemon", "--config-file="+config, "--nofork", "--print-address=1")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	address, err := bufio.NewReader(out).ReadString('\n')
	if err != nil {
		cmd.Wait()
		t.Fatalf("private bus startup: %v: %s", err, stderr.String())
	}
	server, err := dbus.Connect(strings.TrimSpace(address))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { server.Close() })
	if _, err := server.RequestName(nmDest, dbus.NameFlagDoNotQueue); err != nil {
		t.Fatal(err)
	}
	f := &fakeNM{old: old, fail: fail}
	export := func(v any, path dbus.ObjectPath, iface string) {
		t.Helper()
		if err := server.Export(v, path, iface); err != nil {
			t.Fatal(err)
		}
	}
	for i, ap := range aps {
		path := dbus.ObjectPath("/test/ap" + string(rune('A'+i)))
		f.aps = append(f.aps, path)
		rsn := uint32(0)
		if ap.Security == "wpa2-psk" {
			rsn = secPSK
		}
		export(&fakeProps{values: map[string]map[string]dbus.Variant{ifAP: {
			"Ssid": dbus.MakeVariant([]byte(ap.SSID)), "HwAddress": dbus.MakeVariant(ap.BSSID),
			"Strength": dbus.MakeVariant(ap.Signal), "Frequency": dbus.MakeVariant(uint32(2412)),
			"Flags": dbus.MakeVariant(uint32(0)), "WpaFlags": dbus.MakeVariant(uint32(0)), "RsnFlags": dbus.MakeVariant(rsn),
		}}}, path, "org.freedesktop.DBus.Properties")
	}
	export(f, nmPath, nmDest)
	export(f, nmSettings, nmDest+".Settings")
	export(f, testDev, ifWireless)
	export(&fakeProfile{f, true}, testOld, ifSettingsC)
	export(&fakeProfile{f, false}, testNew, ifSettingsC)
	export(&fakeProps{f: f, active: true}, testActive, "org.freedesktop.DBus.Properties")
	export(&fakeProps{values: map[string]map[string]dbus.Variant{nmDest: {"Connectivity": dbus.MakeVariant(uint32(4))}}}, nmPath, "org.freedesktop.DBus.Properties")
	export(&fakeProps{values: map[string]map[string]dbus.Variant{
		ifDevice:   {"State": dbus.MakeVariant(uint32(100)), "Ip4Config": dbus.MakeVariant(dbus.ObjectPath("/"))},
		ifWireless: {"ActiveAccessPoint": dbus.MakeVariant(dbus.ObjectPath("/"))},
	}}, testDev, "org.freedesktop.DBus.Properties")
	client, err := dbus.Connect(strings.TrimSpace(address))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { client.Close() })
	return &NM{conn: client, iface: "test0", persistDir: t.TempDir(), persistMount: t.TempDir()}, f
}

func joinRequest(n *NM, bssid, security, pass string) int {
	body, _ := json.Marshal(map[string]string{"ssid": "Hotel", "bssid": bssid, "security": security, "passphrase": pass})
	r := httptest.NewRequest(http.MethodPost, "http://panhandler:8080/api/wifi/connect", strings.NewReader(string(body)))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	routes(n).ServeHTTP(w, r)
	return w.Code
}

func TestJoinRejectsChangedSelection(t *testing.T) {
	for _, tc := range []struct{ name, bssid, expected, actual, pass string }{
		{"missing selected AP", "00:11:22:33:44:55", "wpa2-psk", "open", "password1"},
		{"security downgraded", "00:11:22:33:44:66", "wpa2-psk", "open", "password1"},
		{"missing security", "00:11:22:33:44:66", "", "open", ""},
		{"password on open AP", "00:11:22:33:44:66", "open", "open", "password1"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			n, f := privateNM(t, []AP{{SSID: "Hotel", BSSID: "00:11:22:33:44:66", Security: tc.actual, Signal: 100}}, true, false)
			if code := joinRequest(n, tc.bssid, tc.expected, tc.pass); code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400", code)
			}
			f.mu.Lock()
			defer f.mu.Unlock()
			if f.settings != nil || f.oldDeleted {
				t.Fatal("rejected request changed profiles")
			}
		})
	}
}

func TestJoinUsesSelectedAP(t *testing.T) {
	n, f := privateNM(t, []AP{
		{SSID: "Hotel", BSSID: "00:11:22:33:44:55", Security: "wpa2-psk", Signal: 50},
		{SSID: "Hotel", BSSID: "00:11:22:33:44:66", Security: "open", Signal: 100},
	}, false, false)
	if code := joinRequest(n, "00:11:22:33:44:55", "wpa2-psk", "password1"); code != 200 {
		t.Fatalf("status = %d", code)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.selected != "/test/apA" {
		t.Fatalf("selected %s, want /test/apA", f.selected)
	}
	if f.settings["802-11-wireless-security"]["key-mgmt"].Value() != "wpa-psk" {
		t.Fatal("selected security not enforced")
	}
	if _, pinned := f.settings["802-11-wireless"]["bssid"]; pinned {
		t.Fatal("saved profile must allow roaming between APs with the selected security")
	}
	if !reflect.DeepEqual(f.settings["802-11-wireless-security"]["proto"].Value(), []string{"rsn"}) {
		t.Fatal("WPA2 selection must not permit WPA1 negotiation")
	}
}

func TestSavedProfileConnectNeedsNoNewScan(t *testing.T) {
	n, f := privateNM(t, nil, true, false)
	if code := joinRequest(n, "", "", ""); code != 200 {
		t.Fatalf("status = %d", code)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.settings != nil || f.oldDeleted {
		t.Fatal("saved connection must not replace the profile")
	}
}

func TestFailedReplacementKeepsOldProfile(t *testing.T) {
	n, f := privateNM(t, []AP{{SSID: "Hotel", BSSID: "00:11:22:33:44:55", Security: "wpa2-psk", Signal: 50}}, true, true)
	if code := joinRequest(n, "00:11:22:33:44:55", "wpa2-psk", "password1"); code != 502 {
		t.Fatalf("status = %d", code)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.oldDeleted || !f.newDeleted {
		t.Fatal("failed replacement must delete only the new profile")
	}
}

func TestSuccessfulReplacementDeletesOldAfterActivation(t *testing.T) {
	n, f := privateNM(t, []AP{{SSID: "Hotel", BSSID: "00:11:22:33:44:55", Security: "wpa2-psk", Signal: 50}}, true, false)
	if code := joinRequest(n, "00:11:22:33:44:55", "wpa2-psk", "password1"); code != 200 {
		t.Fatalf("status = %d", code)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if strings.Join(f.events, ",") != "add,state,delete-old" {
		t.Fatalf("unsafe replacement order: %v", f.events)
	}
}
