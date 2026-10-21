"""Laptop side of the Panhandler unlock: quorum (tap), passphrase, Bitwarden, status, lockdown."""
import argparse, base64, json, os, subprocess, sys, time, urllib.error, urllib.request

CFG_PATH = os.path.expanduser("~/.config/panhandler/agent.json")
SHARE_PATH = os.path.expanduser("~/.local/share/panhandler/unlock-share")
BW_ITEM = "panhandler luks slot2"
BW_SHARE_ITEM = "panhandler laptop share"


def cfg():
    return json.load(open(CFG_PATH))


def phone(path, data=None):
    req = urllib.request.Request(cfg()["phone"] + path, method="POST" if data is not None else "GET",
                                 data=None if data is None else json.dumps(data).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, None


def phone_lockdown():
    try:
        return phone("/lockdown")[1]["lockdown"]
    except OSError as e:
        sys.exit(f"phone listener unreachable ({e}); refusing a remote unlock. Use --via cable.")


def ssh(via, command, stdin=None, tty=False):
    c = cfg()
    argv = ["ssh", "-i", os.path.expanduser(c["ssh_key"]), "-o", "IdentitiesOnly=yes"]
    argv += ["-tt"] if tty else ["-T"]
    argv += [c["pi"][via], command]
    return subprocess.run(argv, input=stdin, check=False).returncode


def guard_remote(via):
    if via != "cable" and (reason := phone_lockdown()):
        sys.exit(f"LOCKDOWN ({reason}): unlock only over the cable.")


def cmd_auto(a):
    guard_remote(a.via)
    s_l = open(SHARE_PATH, "rb").read()
    print("Waiting for your tap on the phone notification (3 min)...", file=sys.stderr)
    deadline = time.time() + 180
    while time.time() < deadline:
        code, body = phone("/share")
        if code == 200:
            k = bytes(x ^ y for x, y in zip(s_l, bytes.fromhex(body["share"]), strict=True))
            return ssh(a.via, "key", stdin=base64.b64encode(k) + b"\n")
        time.sleep(3)
    sys.exit("no tap within 3 min")


def cmd_bitwarden(a):
    guard_remote(a.via)
    try:
        key = subprocess.run(["rbw", "get", BW_ITEM], capture_output=True, check=True).stdout.strip()
    finally:
        subprocess.run(["rbw", "lock"], check=False)
    return ssh(a.via, "key", stdin=key + b"\n")


def cmd_passphrase(a):
    guard_remote(a.via)
    return ssh(a.via, "passphrase", tty=True)


def cmd_status(a):
    return ssh(a.via, "status")


def cmd_clear(a):
    rc = ssh("cable", "clear-lockdown")
    if rc == 0:
        phone("/clear-lockdown", {})
        print("phone lockdown cleared")
    return rc


def write_private(path, data):
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb") as f:
        f.write(data)


def cmd_rekey(a):
    """New quorum key K after phone loss/reset or share exposure; slot 2 (Bitwarden) authorizes."""
    k, s_l = os.urandom(64), os.urandom(64)
    s_p = bytes(x ^ y for x, y in zip(k, s_l, strict=True))
    # Staged first: if this run dies after the Pi rekeys, slots 1/2 still unlock and rekey reruns.
    write_private(SHARE_PATH + ".new", s_l)
    try:
        auth = subprocess.run(["rbw", "get", BW_ITEM], capture_output=True, check=True).stdout.strip()
        if ssh("cable", "rekey", stdin=auth + b"\n" + base64.b64encode(k) + b"\n") != 0:
            os.remove(SHARE_PATH + ".new")
            sys.exit("rekey failed on the Pi; nothing changed")
        os.replace(SHARE_PATH + ".new", SHARE_PATH)
        tmp = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/dev/shm"), "ph-rekey-share")
        write_private(tmp, base64.b64encode(s_l) + b"\n")
        try:
            # rbw edit reads the new secret from $EDITOR; feed it the file instead of opening one.
            if subprocess.run(["rbw", "edit", BW_SHARE_ITEM], env=os.environ | {"EDITOR": f"cp {tmp}"}).returncode:
                print(f"WARNING: Bitwarden '{BW_SHARE_ITEM}' not updated; it still holds the old share", file=sys.stderr)
        finally:
            os.remove(tmp)
    finally:
        subprocess.run(["rbw", "lock"], check=False)
    phone_share = os.path.join(os.path.dirname(SHARE_PATH), "phone-share.hex")
    write_private(phone_share, s_p.hex().encode())
    print(f"""Rekeyed. The phone's old share is dead; enroll the new one:
  1. Move {phone_share} to the phone over a channel you trust (Taildrop or USB).
  2. In Termux:  python3 ~/panhandler/enroll.py < phone-share.hex && rm phone-share.hex
  3. Here:       shred -u {phone_share}""")


def cmd_log(a):
    for r in phone("/log")[1][-a.n:]:
        t = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(r["received_at"]))
        print(t, r["boot_id"][:8], r.get("persist"), r.get("ssid"), r.get("client_ip"),
              f"prev_up={r.get('prev_uptime_s')}", f"short={r.get('short_boots')}", r.get("lockdown") or "")


def main():
    p = argparse.ArgumentParser(prog="ph-unlock")
    sub = p.add_subparsers(required=True)
    for name, fn in [("auto", cmd_auto), ("bitwarden", cmd_bitwarden), ("passphrase", cmd_passphrase),
                     ("status", cmd_status)]:
        s = sub.add_parser(name)
        s.add_argument("--via", choices=["cable", "tailnet"], default="tailnet")
        s.set_defaults(fn=fn)
    sub.add_parser("clear-lockdown").set_defaults(fn=cmd_clear)
    sub.add_parser("rekey", help="rotate the quorum key (cable only)").set_defaults(fn=cmd_rekey)
    s = sub.add_parser("log")
    s.add_argument("-n", type=int, default=20)
    s.set_defaults(fn=cmd_log)
    a = p.parse_args()
    sys.exit(a.fn(a) or 0)


if __name__ == "__main__":
    main()
