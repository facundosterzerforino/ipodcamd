#!/usr/bin/env python3
"""Save a snapshot whenever ipodcamd reports motion. Standard library only.

    IPODCAM_URL=http://192.168.1.50:8080 IPODCAM_USER=ipodcam IPODCAM_PASS=secret \
        python3 ipodcam_watch.py ./captures [--interval 1] [--cooldown 5]
"""
import argparse
import base64
import json
import os
import sys
import time
import urllib.request


def fetch(url, user, password, timeout=15):
    req = urllib.request.Request(url)
    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    req.add_header("Authorization", "Basic " + token)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("outdir", nargs="?", default="captures")
    ap.add_argument("--interval", type=float, default=1.0, help="seconds between /status polls")
    ap.add_argument("--cooldown", type=float, default=5.0, help="minimum seconds between saved snapshots")
    args = ap.parse_args()

    base = os.environ.get("IPODCAM_URL", "").rstrip("/")
    user = os.environ.get("IPODCAM_USER", "ipodcam")
    password = os.environ.get("IPODCAM_PASS", "")
    if not base or not password:
        sys.exit("set IPODCAM_URL and IPODCAM_PASS (and optionally IPODCAM_USER)")
    os.makedirs(args.outdir, exist_ok=True)

    last_saved = 0.0
    print(f"watching {base} every {args.interval}s, saving to {args.outdir}/", flush=True)
    while True:
        try:
            st = json.loads(fetch(base + "/status", user, password))
            age = st.get("seconds_since_motion", -1)
            fresh = 0 <= age <= args.interval * 1.5 + 0.5
            if fresh and time.time() - last_saved >= args.cooldown:
                jpg = fetch(base + "/snapshot.jpg", user, password)
                name = time.strftime("%Y%m%d-%H%M%S") + "_motion.jpg"
                with open(os.path.join(args.outdir, name), "wb") as f:
                    f.write(jpg)
                last_saved = time.time()
                print(f"motion {st.get('motion_pct', 0):.1f}% -> {name}", flush=True)
        except Exception as exc:  # camera rebooting, Wi-Fi hiccup, ...
            print("error:", exc, file=sys.stderr, flush=True)
            time.sleep(5)
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
