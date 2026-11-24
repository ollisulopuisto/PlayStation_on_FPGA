#!/bin/bash
# Installs Quartus Prime Lite 25.1std + Cyclone V into $HOME/altera/25.1std.
# Altera's installers are not public: they sit in the private repo $ASSETS_REPO (release $ASSETS_TAG),
# fetched with the token in $ASSETS_TOKEN, and are kept in $HOME/quartus-dl (Actions cache).
# Derived from ollisulopuisto/MIRLO64 .github/scripts/install_quartus.sh, with
# no xtrace (token hygiene) and SHA-256 pins for both installers.
# Pins: sha256 digests from the q25.1 release metadata of $ASSETS_REPO,
# cross-checked by hashing qinst-lite-linux-25.1std-1129.run after download.
set -euo pipefail
ASSETS_REPO=${ASSETS_REPO:-ollisulopuisto/mirlo64-quartus-assets}
ASSETS_TAG=${ASSETS_TAG:-q25.1}
QINST=qinst-lite-linux-25.1std-1129.run
QDZ=cyclonev-25.1std.0.1129.qdz
QINST_SHA256=5c422347f33929cd85d7c99a0adf9925ee743834a05bdfe5ffe3e27fdcb01342
QDZ_SHA256=d6e484fd1b0a47785bc8bcd318e427d4c9798f9276e9ef92985235865f6bcb6f
DL=$HOME/quartus-dl
mkdir -p "$DL"
cd "$DL"
# The two installers download in parallel: a single stream is throttled well
# below what two streams pull, so the small .run comes down for free while the
# 1.4 GB .qdz transfers.
pids=""
for f in "$QINST" "$QDZ"; do
  if [ ! -s "$f" ]; then
    : "${ASSETS_TOKEN:?ASSETS_TOKEN secret is not set}"
    GH_TOKEN=$ASSETS_TOKEN gh release download "$ASSETS_TAG" -R "$ASSETS_REPO" -p "$f" &
    pids="$pids $!"
  fi
done
rc=0
for p in $pids; do wait "$p" || rc=1; done
[ "$rc" -eq 0 ]
# refuse an HTML error page posing as an installer, then verify pinned bytes
head -c 2 "$QINST" | grep -q '#!'
echo "$QINST_SHA256  $QINST" | sha256sum -c -
echo "$QDZ_SHA256  $QDZ" | sha256sum -c -
ls -l
[ "${DOWNLOAD_ONLY:-0}" = 1 ] && exit 0
chmod +x "$QINST"
"./$QINST" --nox11 --noprogress -- --cli --download-dir "$DL" --install-dir "$HOME/altera/25.1std" \
  --accept-eula --components quartus,cyclonev
QSH=$HOME/altera/25.1std/quartus/bin/quartus_sh
test -x "$QSH"
echo "QUARTUS_BIN=$(dirname "$QSH")" >> "$GITHUB_ENV"
"$QSH" --version
