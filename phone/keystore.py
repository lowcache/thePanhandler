"""Shared by tap.py and enroll.py: the phone share is wrapped with a Keystore signature."""
import hashlib, subprocess, time

ALIAS = "panhandler"
MESSAGE = b"panhandler-unlock-v1"


def pad(wait_s=0):
    """SHA-512 of a deterministic RSA PKCS#1 v1.5 signature; needs a strong unlock (fingerprint/PIN)
    within the key's validity. Outside it the Keystore refuses silently (empty output, exit 0)."""
    deadline = time.time() + wait_s
    while True:
        sig = subprocess.run(["termux-keystore", "sign", ALIAS, "SHA256withRSA"], input=MESSAGE,
                             capture_output=True, check=True).stdout
        if sig:
            return hashlib.sha512(sig).digest()
        if time.time() >= deadline:
            raise RuntimeError("keystore refused to sign: unlock with fingerprint or PIN (not face), then retry")
        time.sleep(1)


def xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b, strict=True))
