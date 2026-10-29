#!/usr/bin/env python3
"""Panhandler boot-log listener (Termux). Authoritative boot log + lockdown; holds a tapped share briefly."""
import json, os, re, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser("~/.panhandler")
CFG = json.load(open(os.path.join(HOME, "listener.json")))
LOG = os.path.join(HOME, "bootlog.jsonl")
LOCK = os.path.join(HOME, "lockdown.json")
WINDOW_S = CFG.get("cluster_window_min", 60) * 60
BOOTS = CFG.get("cluster_boots", 3)
SHARE_TTL_S = 120
MAX_BODY = 4096
# Boot-record fields the Pi may send, with their accepted types (None = JSON null).
FIELDS = {"boot_id": str, "prev_uptime_s": (int, type(None)), "short_boots": (int, type(None)),
          "failed_unlocks": (int, type(None)), "lockdown": (str, type(None)), "persist": str,
          "source": str, "ssid": str, "bssid": str, "queued": bool}
BOOT_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
TAP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tap.py")

lock = threading.Lock()
share = {"value": None, "at": 0.0}


def records():
    try:
        with open(LOG) as f:
            return [json.loads(l) for l in f if l.strip()]
    except FileNotFoundError:
        return []


def lockdown():
    try:
        return json.load(open(LOCK)).get("reason")
    except FileNotFoundError:
        return None


def set_lockdown(reason):
    with open(LOCK, "w") as f:
        json.dump({"reason": reason, "at": time.time()}, f)


def notify(rec, reason):
    title = "Panhandler booted" + (" ⚠ CLUSTER" if reason else "")
    body = (f"{rec.get('ssid') or '?'} / {rec.get('bssid') or '?'} from {rec.get('client_ip')}; "
            f"prev uptime {rec.get('prev_uptime_s')}s; persist {rec.get('persist')}")
    if reason:
        body += f"\nLOCKDOWN: {reason} (cable unlock only)"
    cmd = ["termux-notification", "--id", "panhandler", "--priority", "high", "--title", title, "--content", body]
    if not reason and rec.get("persist") == "locked":
        cmd += ["--action", f"python3 {TAP}"]
    # Termux:API calls can hang; never let one block the Pi's check-in reply.
    try:
        subprocess.run(cmd, check=False, timeout=15)
    except subprocess.TimeoutExpired:
        print("termux-notification timed out", file=sys.stderr, flush=True)


class H(BaseHTTPRequestHandler):
    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def client(self):
        return self.client_address[0]

    def allowed(self, role):
        return self.client() in CFG["allow"].get(role, [])

    def body(self):
        n = int(self.headers.get("Content-Length", 0))
        if not 0 <= n <= MAX_BODY:
            raise ValueError("body too large")
        obj = json.loads(self.rfile.read(n) or b"{}")
        if not isinstance(obj, dict):
            raise ValueError("body is not an object")
        return obj

    def checkin_record(self):
        rec = self.body()
        if not BOOT_ID.match(str(rec.get("boot_id", ""))):
            raise ValueError("bad boot_id")
        if any(k not in FIELDS or isinstance(v, bool) != (FIELDS[k] is bool) or not isinstance(v, FIELDS[k])
               for k, v in rec.items()):
            raise ValueError("unexpected field or type")
        return rec

    def do_POST(self):
        try:
            self.post()
        except (ValueError, KeyError):
            self.reply(400, {})

    def post(self):
        if self.path == "/checkin" and self.allowed("pi"):
            rec = self.checkin_record()
            rec["client_ip"], rec["received_at"] = self.client(), time.time()
            with lock:
                old = {r["boot_id"] for r in records()}
                new_boot = rec.get("boot_id") not in old
                with open(LOG, "a") as f:
                    f.write(json.dumps(rec) + "\n")
                # Queued records are earlier boots delivered late: their receipt time says nothing.
                recent = {r["boot_id"]: r["received_at"] for r in records() if not r.get("queued")}
                fresh = [t for t in recent.values() if t >= time.time() - WINDOW_S]
                if not lockdown():
                    if rec.get("lockdown"):
                        set_lockdown(rec["lockdown"])
                    elif new_boot and not rec.get("queued") and len(fresh) >= BOOTS:
                        set_lockdown(f"remote-cluster: {len(fresh)} boots in {WINDOW_S // 60} min")
                reason = lockdown()
            if new_boot or rec.get("failed_unlocks"):
                notify(rec, reason)
            return self.reply(200, {"lockdown": reason})
        if self.path == "/share" and self.client() == "127.0.0.1":
            with lock:
                share["value"], share["at"] = self.body()["share"], time.time()
            return self.reply(200, {})
        if self.path == "/clear-lockdown" and self.allowed("laptop"):
            with lock:
                if os.path.exists(LOCK):
                    os.remove(LOCK)
            return self.reply(200, {})
        self.reply(403, {})

    def do_GET(self):
        if self.path == "/lockdown" and (self.client() == "127.0.0.1" or self.allowed("laptop")):
            return self.reply(200, {"lockdown": lockdown()})
        if self.path == "/share" and self.allowed("laptop"):
            with lock:
                fresh = share["value"] and time.time() - share["at"] < SHARE_TTL_S
                value = share["value"] if fresh and not lockdown() else None
                share["value"] = None  # one fetch only
            return self.reply(200 if value else 404, {"share": value})
        if self.path == "/log" and self.allowed("laptop"):
            return self.reply(200, records())
        self.reply(403, {})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    os.makedirs(HOME, mode=0o700, exist_ok=True)
    # At phone boot Termux:Boot can run before Tailscale has brought up the bind address.
    while True:
        try:
            srv = ThreadingHTTPServer((CFG["bind"], CFG.get("port", 8463)), H)
            break
        except OSError as e:
            print(f"bind {CFG['bind']} failed ({e}); retrying in 10 s", file=sys.stderr, flush=True)
            time.sleep(10)
    # Loopback for the tap script; the tailnet address for the Pi and laptop.
    threading.Thread(target=ThreadingHTTPServer(("127.0.0.1", CFG.get("port", 8463)), H).serve_forever,
                     daemon=True).start()
    print(f"listening on {CFG['bind']}:{CFG.get('port', 8463)}", file=sys.stderr)
    srv.serve_forever()
