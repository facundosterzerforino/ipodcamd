#!/usr/bin/env bash
# Builds build/ipodcamd (armv7, iOS 6.0+) and build/ipodcamd_<version>_iphoneos-arm.deb
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TC="$ROOT/.toolchain/linux/iphone/bin"
SDK="$ROOT/.toolchain/sdks/iPhoneOS9.3.sdk"
[ -x "$TC/clang" ] && [ -d "$SDK" ] || { echo "run scripts/setup-toolchain.sh first" >&2; exit 1; }
export PATH="$TC:$PATH"

VERSION="$(sed -n 's/^#define IPODCAMD_VERSION "\(.*\)"/\1/p' "$ROOT/src/ipodcamd.m")"
OUT="$ROOT/build"
rm -rf "$OUT"; mkdir -p "$OUT"

clang -target armv7-apple-ios6.0 -isysroot "$SDK" -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
  -c "$ROOT/src/ipodcamd.m" -o "$OUT/ipodcamd.o"

# The 9.3 SDK stubs do not export these libc names for armv7 (on the device they live in
# libsystem_platform / libsystem_c), so they are linked as dynamic_lookup and resolved by dyld at load time.
LIBC_LOOKUP=(-Wl,-U,_memcpy -Wl,-U,_memset -Wl,-U,_memcmp -Wl,-U,_strchr -Wl,-U,_strcmp)
clang -target armv7-apple-ios6.0 -isysroot "$SDK" "$OUT/ipodcamd.o" \
  -framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework CoreGraphics -framework ImageIO -framework MobileCoreServices \
  -Wl,-w "${LIBC_LOOKUP[@]}" -o "$OUT/ipodcamd" 2>&1 | grep -v 'warning: building for' || true
strip -x "$OUT/ipodcamd" 2>/dev/null || true
ldid -S "$OUT/ipodcamd"
otool -hv "$OUT/ipodcamd" | sed -n '3,4p'
otool -l "$OUT/ipodcamd" | grep -A3 LC_VERSION_MIN_IPHONEOS | tr -s ' ' | tr '\n' ' '; echo

# --- .deb (gzip: the dpkg on iOS 6 cannot read xz/zstd) ---
STAGE="$OUT/deb"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin" "$STAGE/Library/LaunchDaemons"
install -m 755 "$OUT/ipodcamd" "$STAGE/usr/bin/ipodcamd"
install -m 644 "$ROOT/pkg/dev.ipodcamd.plist" "$STAGE/Library/LaunchDaemons/dev.ipodcamd.plist"
sed "s/@VERSION@/$VERSION/" "$ROOT/pkg/DEBIAN/control" > "$STAGE/DEBIAN/control"
for s in postinst prerm postrm; do install -m 755 "$ROOT/pkg/DEBIAN/$s" "$STAGE/DEBIAN/$s"; done
dpkg-deb --root-owner-group -Zgzip -b "$STAGE" "$OUT/ipodcamd_${VERSION}_iphoneos-arm.deb" >/dev/null
ls -l "$OUT"/ipodcamd "$OUT"/*.deb
