#!/usr/bin/env python3
"""One-time: read the phone share (hex) on stdin, create the Keystore key, store only the wrapped share."""
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keystore import ALIAS, pad, xor

VALIDITY_S = "15"
s_p = bytes.fromhex(sys.stdin.read().strip())
assert len(s_p) == 64, "expected a 64-byte share"
subprocess.run(["termux-keystore", "delete", ALIAS], capture_output=True)
subprocess.run(["termux-keystore", "generate", ALIAS, "-a", "RSA", "-s", "2048", "-u", VALIDITY_S], check=True)
print("Lock the phone, then unlock with fingerprint or PIN (face unlock does not count). Waiting up to 2 min...",
      flush=True)
p1, p2 = pad(wait_s=120), pad()
assert p1 == p2, "signatures are not deterministic; the Keystore wrap cannot work"
home = os.path.expanduser("~/.panhandler")
os.makedirs(home, mode=0o700, exist_ok=True)
path = os.path.join(home, "share.enc")
with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
    f.write(xor(s_p, p1).hex())
print(f"enrolled; wrapped share at {path}")
