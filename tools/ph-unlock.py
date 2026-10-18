"""Laptop side of the Panhandler unlock: quorum (tap), passphrase, Bitwarden, status, lockdown."""
import argparse, base64, json, os, subprocess, sys, time, urllib.error, urllib.request

CFG_PATH = os.path.expanduser("~/.config/panhandler/agent.json")
SHARE_PATH = os.path.expanduser("~/.local/share/panhandler/unlock-share")
BW_ITEM = "panhandler luks slot2"


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
    s = sub.add_parser("log")
    s.add_argument("-n", type=int, default=20)
    s.set_defaults(fn=cmd_log)
    a = p.parse_args()
    sys.exit(a.fn(a) or 0)


if __name__ == "__main__":
    main()
