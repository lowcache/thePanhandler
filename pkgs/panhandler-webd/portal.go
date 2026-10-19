package main

import (
	"log"
	"time"

	"github.com/godbus/dbus/v5"
	"golang.org/x/sys/unix"
)

const (
	sdDest      = "org.freedesktop.systemd1"
	sdPath      = dbus.ObjectPath("/org/freedesktop/systemd1")
	bypassUnit  = "ph-portal-bypass.service"
	bypassLimit = 600 // seconds; matches RuntimeMaxSec in modules/portal.nix
)

type Bypass struct {
	Active      bool `json:"active"`
	SecondsLeft int  `json:"secondsLeft"`
}

func (n *NM) Bypass() Bypass {
	var unit dbus.ObjectPath
	if n.conn.Object(sdDest, sdPath).Call(sdDest+".Manager.LoadUnit", 0, bypassUnit).Store(&unit) != nil {
		return Bypass{}
	}
	o := n.conn.Object(sdDest, unit)
	st, err := o.GetProperty(sdDest + ".Unit.ActiveState")
	if err != nil {
		return Bypass{}
	}
	if s, _ := st.Value().(string); s != "active" && s != "activating" {
		return Bypass{}
	}
	b := Bypass{Active: true}
	var ts unix.Timespec
	b.SecondsLeft = bypassLimit // still activating: no ActiveEnter timestamp yet
	if since, err := o.GetProperty(sdDest + ".Unit.ActiveEnterTimestampMonotonic"); err == nil && unix.ClockGettime(unix.CLOCK_MONOTONIC, &ts) == nil {
		if us, _ := since.Value().(uint64); us > 0 {
			b.SecondsLeft = max(0, bypassLimit-int((ts.Nano()/1000-int64(us))/1e6))
		}
	}
	return b
}

// SetBypass starts/stops the DNS bypass unit (polkit allows webd exactly this unit).
func (n *NM) SetBypass(on bool) error {
	method := sdDest + ".Manager.StopUnit"
	if on {
		method = sdDest + ".Manager.StartUnit"
	}
	var job dbus.ObjectPath
	return n.conn.Object(sdDest, sdPath).Call(method, 0, bypassUnit, "replace").Store(&job)
}

// watchBypass ends the bypass as soon as the portal lets us through, so plaintext DNS
// lasts seconds past login instead of NM's 300 s connectivity interval.
func (n *NM) watchBypass() {
	for range time.Tick(5 * time.Second) {
		if !n.Bypass().Active {
			continue
		}
		var c uint32
		if err := n.obj(nmPath).Call(nmDest+".CheckConnectivity", 0).Store(&c); err != nil {
			log.Printf("portal: connectivity check: %v", err)
			continue
		}
		if c == 4 {
			if err := n.SetBypass(false); err != nil {
				log.Printf("portal: stop bypass: %v", err)
			} else {
				log.Printf("portal: connectivity full, bypass ended")
			}
		}
	}
}
