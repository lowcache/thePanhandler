#!/usr/bin/env python3
"""Notification action: rebuild the phone share and hand it to the listener for one laptop fetch."""
import json, os, subprocess, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keystore import pad, xor

BASE = "http://127.0.0.1:8463"


def toast(msg):
    subprocess.run(["termux-toast", msg], check=False)


try:
    if json.load(urllib.request.urlopen(f"{BASE}/lockdown", timeout=5))["lockdown"]:
        toast("Panhandler is in LOCKDOWN: unlock over the cable")
        sys.exit(3)
    wrapped = bytes.fromhex(open(os.path.expanduser("~/.panhandler/share.enc")).read().strip())
    s_p = xor(wrapped, pad())
    req = urllib.request.Request(f"{BASE}/share", data=json.dumps({"share": s_p.hex()}).encode(),
                                 headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=5)
    toast("Panhandler share released for 2 min")
except Exception as e:  # surfaced on screen, nothing else to do on the phone
    toast(f"Panhandler tap failed: {e}")
    sys.exit(1)
