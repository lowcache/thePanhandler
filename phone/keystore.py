"""Shared by tap.py and enroll.py: the phone share is wrapped with a Keystore signature."""
import hashlib, json, subprocess

ALIAS = "panhandler"
MESSAGE = b"panhandler-unlock-v1"


def pad(prompt=True):
    """SHA-512 of a deterministic RSA PKCS#1 v1.5 signature. The key signs only within 15 s of a strong
    auth; the fingerprint prompt supplies one. Each refused sign posts a Termux:API error, so sign once."""
    if prompt:
        out = subprocess.run(["termux-fingerprint", "-t", "Panhandler", "-d", "Fingerprint releases the share"],
                             capture_output=True, text=True, timeout=60).stdout
        if json.loads(out or "{}").get("auth_result") != "AUTH_RESULT_SUCCESS":
            raise RuntimeError("fingerprint not accepted")
    sig = subprocess.run(["termux-keystore", "sign", ALIAS, "SHA256withRSA"], input=MESSAGE,
                         capture_output=True, check=True, timeout=30).stdout
    if not sig:
        raise RuntimeError("keystore refused to sign: use fingerprint, not face")
    return hashlib.sha512(sig).digest()


def xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b, strict=True))
