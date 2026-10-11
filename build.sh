#!/bin/sh
# Build the signed apkg (.bin) for each OS5 model with mksapkg-OS5.
# Usage: ./build.sh [model ...]   (default: all models)
# Needs ./mksapkg-OS5 (x86_64 Linux) next to this script.
set -eu
cd "$(dirname "$0")"
PKG=tailscale
VERSION="$(awk '/^Version:/{print $NF}' $PKG/apkg.rc)"
MODELS="${*:-MyCloudEX2Ultra MyCloudPR4100 MyCloudPR2100 WDMyCloudEX4100 WDMyCloudDL4100 WDMyCloudEX2100 WDMyCloudDL2100 WDMyCloudMirror}"
[ -x ./mksapkg-OS5 ] || { echo "mksapkg-OS5 missing (see .github/workflows/build.yml)"; exit 1; }
mkdir -p packages
chmod +x $PKG/*.sh $PKG/bin/*
for model in $MODELS; do
  short="$(echo "$model" | sed 's/^WDMyCloud//; s/^MyCloud//')"
  echo "== $PKG $VERSION for $model"
  ( cd $PKG && ../mksapkg-OS5 -E -s -m "$model" > /dev/null )
  # A valid signature is 'Salted__' + 8 byte salt + ciphertext (40 bytes).
  # 16 bytes means openssl failed on the Blowfish cipher (OpenSSL 3 needs the legacy provider).
  sig="$(wc -c < $PKG/apkg.sign)"
  [ "$sig" -ge 24 ] || { echo "apkg.sign is only $sig bytes: signing failed (openssl bf-cbc unavailable?)"; exit 1; }
  out="$(ls -t ${model}_${PKG}_${VERSION}.bin* 2>/dev/null | head -1)"
  [ -n "$out" ] || { echo "mksapkg produced no output for $model"; ls -la; exit 1; }
  mv "$out" "packages/${PKG}_${VERSION}_${short}.bin"
done
rm -f apkg_tar_tmp.tgz $PKG/apkg.sign $PKG/apkg.xml
ls -la packages
