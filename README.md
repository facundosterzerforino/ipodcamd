# ipodcamd

A tiny, dependency-free **camera server for old jailbroken iOS devices**. It turns an iPod touch 4 / iPhone 4 / iPad 2-era device on **iOS 6** (and newer, armv7) into a Wi-Fi security camera: MJPEG stream, JPEG snapshots, and a built-in motion score, served over plain HTTP.

No app, no Apple ID, no App Store (the App Store has been closed to iOS 6 for years). It is one headless daemon (`/usr/bin/ipodcamd`) started by launchd at boot, running as the unprivileged `mobile` user.

Tested on: **iPod touch 4th gen, iOS 6.1.6**, jailbroken with p0sixspwn (untethered). Front camera 640x480, back camera up to 1280x720.

## What you get

| URL | |
|---|---|
| `/` | tiny live-view page |
| `/stream` | `multipart/x-mixed-replace` MJPEG (browsers, VLC, ffplay, ffmpeg, Home Assistant "MJPEG IP Camera") |
| `/snapshot.jpg` | one JPEG |
| `/status` | JSON: camera, resolution, viewers, frames, **motion_pct**, `seconds_since_motion`, uptime |
| `/switch?cam=front\|back` | change camera without restarting |

Everything needs HTTP Basic auth. On first start the daemon generates a random password and writes it to `/var/mobile/Library/Preferences/ipodcamd.conf` (mode 0600). It never runs without a password.

Frames are only JPEG-encoded while somebody is watching (or a snapshot is requested), so an idle camera costs little CPU. Motion detection samples a 64x48 luma grid four times a second.

## Install (on the device)

1. Jailbroken iOS 6.1.x device with **OpenSSH** installed (Cydia). Change the default `alpine` passwords.
2. Get `ipodcamd_<version>_iphoneos-arm.deb` (build it below, or take it from a release) and copy it over:
   ```sh
   scp ipodcamd_*.deb root@<device-ip>:/var/root/
   ssh root@<device-ip> 'dpkg -i /var/root/ipodcamd_*.deb'
   ```
   The installer prints the URL and the generated password. (`scripts/install.sh <ip>` does the same and copes with iOS 6's old SSH algorithms.)
3. Open `http://<device-ip>:8080/`, user `ipodcam`.

Keep the device plugged in, on Wi-Fi, and **do not open the Camera app**: only one process can own the camera. If the camera stops delivering frames for 20 s the daemon exits and launchd restarts it.

The camera takes about 25 s to come up after a reboot (mediaserverd starts late); the daemon waits for it.

## Use it

```sh
ffplay "http://ipodcam:<password>@<device-ip>:8080/stream"
curl -u ipodcam:<password> -o now.jpg http://<device-ip>:8080/snapshot.jpg
curl -u ipodcam:<password> http://<device-ip>:8080/status
```

`tools/ipodcam_watch.py` is a stdlib-only example that polls `/status` and saves a snapshot every time motion is reported:

```sh
IPODCAM_URL=http://<device-ip>:8080 IPODCAM_PASS=<password> python3 tools/ipodcam_watch.py ./captures
```

## Configuration

`/var/mobile/Library/Preferences/ipodcamd.conf` (restart with `launchctl unload /Library/LaunchDaemons/dev.ipodcamd.plist; launchctl load /Library/LaunchDaemons/dev.ipodcamd.plist`):

```
port=8080
camera=back            # back | front
resolution=640x480     # 352x288 | 640x480 | 1280x720 (front camera: 640x480 max)
fps=10                 # max frames/s per viewer, 1-30
quality=70             # JPEG 1-100
rotate=0               # 0 | 90 | 180 | 270, clockwise
user=ipodcam
password=...
motion_threshold=2.0   # % of the picture that must change
```

Log: `/var/mobile/Library/Logs/ipodcamd.log`.

## Security

- It is **plain HTTP with Basic auth**: fine on a home LAN, not for the internet. Do not port-forward it. For remote access put the device's network behind a VPN (for example Tailscale on a PC on the same LAN, and reach the camera through it).
- iOS 6 has been unsupported for a decade; a jailbroken one has no sandbox worth trusting. Put it on a guest/IoT network if you can.
- Wrong passwords are slowed by 0.7 s per attempt; at most 8 connections are served at once.
- Only the front or back camera video is served, never audio.

## Build

Everything is built on Linux (or WSL); nothing runs on the host OS.

```sh
scripts/setup-toolchain.sh   # once: downloads the iOS clang/ld64/ldid toolchain + iPhoneOS 9.3 SDK (~150 MB)
scripts/build.sh             # -> build/ipodcamd and build/ipodcamd_<ver>_iphoneos-arm.deb
```

Needs `curl git tar xz python3 dpkg-deb`. The binary targets `armv7-apple-ios6.0`; the 9.3 SDK is only used for headers and link stubs, and the code uses no API newer than iOS 6.

The toolchain is the community build [L1ghtmann/llvm-project](https://github.com/L1ghtmann/llvm-project) (pinned by SHA-256 in `setup-toolchain.sh`); the SDK comes from [theos/sdks](https://github.com/theos/sdks). Neither is redistributed here. A few libc symbols are missing from the SDK's armv7 stubs and are linked as `dynamic_lookup`; `setup-toolchain.sh` also adds an empty stub for `liblaunch`. Both are workarounds for the SDK repo, not for the code.

## Known limits

- MJPEG only (no H.264, no audio); a 640x480 frame is 40-100 KB, so roughly 3-9 Mbit/s at 10 fps. Lower `quality` or `fps` on weak Wi-Fi.
- Measured on an iPod touch 4 over 2.4 GHz Wi-Fi: about 10 fps at 640x480 / quality 70 and 12 fps at quality 50 (the limit is encoding plus Wi-Fi, not the camera, which delivers 30 fps). 720p is slower.
- The sensor is a small phone-class camera: expect noise in dim rooms and no night vision.

## License

MIT, see `LICENSE`.
