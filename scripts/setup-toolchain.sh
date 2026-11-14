#!/usr/bin/env bash
# One-time setup: downloads the iOS cross toolchain and an iPhoneOS SDK into ./.toolchain
# Needs: curl git tar xz python3 (all inside Linux / WSL; nothing runs on Windows).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TC="$ROOT/.toolchain"
mkdir -p "$TC"
cd "$TC"

# --- compiler + ld64 + ldid: community-built iOS toolchain for Linux (the one Theos recommends) ---
TC_URL="https://github.com/L1ghtmann/llvm-project/releases/download/test-210562a/iOSToolchain-x86_64.tar.xz"
TC_SHA256="a72a7a577e2fbe2838b6b5e9c72034fa7d114af96f0e1d4b016f18730ce4056e"
if [ ! -d linux/iphone/bin ]; then
  [ -f toolchain.tar.xz ] || curl -fL -o toolchain.tar.xz "$TC_URL"
  echo "$TC_SHA256  toolchain.tar.xz" | sha256sum -c -
  tar xJf toolchain.tar.xz
fi

# --- SDK: only iPhoneOS9.3.sdk (oldest in theos/sdks; we still target iOS 6.0 with it) ---
SDK_REPO="https://github.com/theos/sdks.git"
if [ ! -d sdks/iPhoneOS9.3.sdk ]; then
  [ -d sdks ] || git clone --depth=1 --filter=blob:none --sparse "$SDK_REPO" sdks
  (cd sdks && git sparse-checkout set iPhoneOS9.3.sdk)
fi
SDK="$TC/sdks/iPhoneOS9.3.sdk"

# --- the SDK checkout lacks a few libSystem re-export stubs; ld64 refuses to link without them ---
python3 - "$SDK" <<'PY'
import os, re, sys
sdk = sys.argv[1]
text = open(sdk + '/usr/lib/libSystem.tbd').read()
for name in re.findall(r'/usr/lib/system/([A-Za-z0-9_]+)\.dylib', text):
    path = f'{sdk}/usr/lib/system/{name}.tbd'
    if not os.path.exists(path):
        open(path, 'w').write(f"""---
archs:                 [ armv7, armv7s, arm64, i386, x86_64 ]
platform:              ios
install-name:          /usr/lib/system/{name}.dylib
current-version:       0
compatibility-version: 0
exports:
  - archs:              [ armv7, armv7s, arm64, i386, x86_64 ]
    symbols:            [ ]
...
""")
        print('created stub for', name)
PY
echo "toolchain ready in $TC"
