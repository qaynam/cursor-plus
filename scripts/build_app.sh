#!/bin/bash
#
# Build Cursor+ and install a signed, double-clickable Cursor+.app.
#
#     ./scripts/build_app.sh          # build + install (relaunches it if it was running)
#     ./scripts/build_app.sh --open   # build + install + launch
#
# The bundle is assembled under .build/ and installed straight to /Applications
# (or ~/Applications), so a signed app never sits in the working tree. The signing
# identity is never written to a tracked file either: it comes from the
# environment, or from scripts/local.env, which is gitignored.
#
# For a stable Accessibility / Location grant that SURVIVES rebuilds, create a
# persistent self-signed code-signing certificate once (Keychain Access ->
# Certificate Assistant -> Create a Certificate -> Self Signed Root -> Code
# Signing, named "CursorPlus Self"). It is picked up automatically and carries no
# personal name or team ID. To use a different identity instead:
#
#     echo 'CURSORPLUS_SIGN_IDENTITY="Your Identity"' > scripts/local.env
#
# Without one the app is ad-hoc signed and macOS forgets the permission grants on
# every rebuild (re-grant in System Settings, or run:
#     tccutil reset Accessibility com.aus.cursorplus ).

set -euo pipefail
cd "$(dirname "$0")/.."

OPEN_AFTER=0
[[ "${1:-}" == "--open" ]] && OPEN_AFTER=1

if [[ -f scripts/local.env ]]; then
    # shellcheck disable=SC1091
    source scripts/local.env
fi

APP="Cursor+.app"
EXE="CursorPlus"
BUNDLE_ID="com.aus.cursorplus"
IDENTITY="${CURSORPLUS_SIGN_IDENTITY:-}"
STAGE_DIR=".build/app"

# Auto-use the stable self-signed identity if it's installed, so the macOS
# permission grant survives every rebuild (no more re-granting).
# NOTE: no -v — a self-signed cert is "untrusted" (and hidden by -v), but codesign
# can still sign with it, which is all we need for a stable local TCC identity.
if [[ -z "${IDENTITY}" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "CursorPlus Self"; then
    IDENTITY="CursorPlus Self"
fi

echo "==> Building (release)"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/${EXE}"
if [[ ! -f "${BIN}" ]]; then
    echo "build product not found at ${BIN}"
    exit 1
fi

echo "==> Assembling ${STAGE_DIR}/${APP}"
STAGED="${STAGE_DIR}/${APP}"
rm -rf "${STAGED}"
mkdir -p "${STAGED}/Contents/MacOS" "${STAGED}/Contents/Resources"
cp "${BIN}" "${STAGED}/Contents/MacOS/${EXE}"
cp "SupportFiles/Info.plist" "${STAGED}/Contents/Info.plist"
if [[ -f "SupportFiles/AppIcon.icns" ]]; then
    cp "SupportFiles/AppIcon.icns" "${STAGED}/Contents/Resources/AppIcon.icns"   # Finder/Launchpad/Dock icon
fi

if [[ -n "${IDENTITY}" ]]; then
    echo "==> Codesigning with stable identity"
    codesign --force --identifier "${BUNDLE_ID}" --sign "${IDENTITY}" "${STAGED}"
else
    echo "==> Codesigning ad-hoc (grant resets each rebuild; install 'CursorPlus Self' to avoid)"
    codesign --force --identifier "${BUNDLE_ID}" --sign - "${STAGED}"
fi

codesign --verify --strict --verbose=2 "${STAGED}" || true

# Replacing the bundle under a running copy leaves that copy running a deleted
# binary whose permission grant no longer matches, so its input tap can go deaf
# while it keeps moving the cursor. Quit it first (SIGTERM goes through the app's
# normal shutdown), and only force it if it doesn't go.
WAS_RUNNING=0
if pgrep -x "${EXE}" >/dev/null; then
    WAS_RUNNING=1
    echo "==> Quitting the running Cursor+"
    pkill -TERM -x "${EXE}" || true
    for _ in $(seq 1 50); do
        pgrep -x "${EXE}" >/dev/null || break
        sleep 0.1
    done
    if pgrep -x "${EXE}" >/dev/null; then
        pkill -KILL -x "${EXE}" || true
    fi
fi

# Install ONE canonical copy so stale duplicates can't linger and get launched.
INSTALL_DIR="${CURSORPLUS_INSTALL_DIR:-/Applications}"
if [[ ! -w "${INSTALL_DIR}" ]]; then
    INSTALL_DIR="${HOME}/Applications"
    mkdir -p "${INSTALL_DIR}"
fi
DEST="${INSTALL_DIR}/${APP}"
rm -rf "${DEST}"
cp -R "${STAGED}" "${DEST}"
rm -rf "${STAGED}"                       # keep only the installed copy
echo ""
echo "==> Installed: ${DEST}"

if [[ ${OPEN_AFTER} -eq 1 || ${WAS_RUNNING} -eq 1 ]]; then
    open "${DEST}"
    echo "    Launched."
else
    echo "    Launch with:  open \"${DEST}\"   (or Spotlight: Cursor+)"
fi
echo "    (Always launch the .app bundle, never the bare binary.)"
