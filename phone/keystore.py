"""Shared by tap.py and enroll.py: the phone share is wrapped with a Keystore signature."""
import hashlib, subprocess

ALIAS = "panhandler"
MESSAGE = b"panhandler-unlock-v1"


def pad():
    """SHA-512 of a deterministic RSA PKCS#1 v1.5 signature; needs a recent device unlock."""
    sig = subprocess.run(["termux-keystore", "sign", ALIAS, "SHA256withRSA"], input=MESSAGE,
                         capture_output=True, check=True).stdout
    if not sig:
        raise RuntimeError("keystore refused to sign (lock and unlock the phone, then tap again)")
    return hashlib.sha512(sig).digest()


def xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b, strict=True))
