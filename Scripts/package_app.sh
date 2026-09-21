#!/bin/bash
#
# Scripts/package_app.sh — the sole packaging authority for WhisperBar
# (CON-PACKAGING-RELEASE): release build, app assembly, resources, signing,
# strict verification, and DMG creation.
#
# Output artifacts (locked):
#   dist/WhisperBar.app
#   dist/WhisperBar.dmg
#
# Assembly input: the Swift Package Manager release executable plus
# Resources/Info.plist, Resources/App.entitlements, and Resources/AppIcon.icns.
# Signing: ad-hoc identity '-' by default for local proof, or an explicitly
# selected distribution identity via --identity / WHISPERBAR_SIGN_IDENTITY.
# Every gate fails closed; any failure blocks the later gates and the DMG.
#
# Install rule: this script never touches /Applications unless --install is
# given AND WHISPERBAR_ALLOW_APPLICATIONS_INSTALL=1 (separate explicit
# approval). It then keeps a scoped rollback copy under dist/rollback, installs
# to /Applications/WhisperBar.app, registers that exact bundle with
# LaunchServices, launches it, and verifies the running bundle identity.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ── Locked identity (TRD "Packaging Contract") ───────────────────────────────
BUNDLE_ID="com.whisperbar.app"
APP_NAME="WhisperBar"
EXECUTABLE_NAME="Whisperbar"
PACKAGE_TYPE="APPL"
SHORT_VERSION="1.0.0"
BUILD_VERSION="1"
MIC_USAGE_DESCRIPTION="WhisperBar uses the microphone only while you explicitly record dictation."

DIST_DIR="$ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
INSTALL_TARGET="/Applications/$APP_NAME.app"
ROLLBACK_DIR="$DIST_DIR/rollback"

# Canonical Swift Package Manager release product, plus the current
# build-system layout used by Swift 6.4 toolchains.
RELEASE_EXECUTABLE="$ROOT/.build/arm64-apple-macosx/release/Whisperbar"
RELEASE_EXECUTABLE_FALLBACK="$ROOT/.build/release/Whisperbar"

INFO_PLIST_SOURCE="$ROOT/Resources/Info.plist"
ENTITLEMENTS_SOURCE="$ROOT/Resources/App.entitlements"
ICON_SOURCE="$ROOT/Resources/AppIcon.icns"

# Selected signing identity: ad-hoc for local builds unless a distribution
# identity is supplied explicitly.
SIGN_IDENTITY="${WHISPERBAR_SIGN_IDENTITY:--}"
INSTALL=0

log() { printf '[package_app] %s\n' "$*"; }
die() { printf '[package_app] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: Scripts/package_app.sh [--identity <codesigning identity>] [--install]

  --identity <identity>  Codesigning identity (default: ad-hoc '-')
  --install              Install to /Applications/WhisperBar.app after all
                         gates pass; requires explicit approval via
                         WHISPERBAR_ALLOW_APPLICATIONS_INSTALL=1
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --identity)
      [ $# -ge 2 ] || die "--identity requires a value"
      SIGN_IDENTITY="$2"
      shift
      ;;
    --identity=*) SIGN_IDENTITY="${1#--identity=}" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

# ── Fail-closed input guards ─────────────────────────────────────────────────
[ -f "$ROOT/Package.swift" ] || die "not a WhisperBar checkout: $ROOT/Package.swift is missing"
[ -f "$INFO_PLIST_SOURCE" ] || die "missing packaging input: Resources/Info.plist"
[ -f "$ENTITLEMENTS_SOURCE" ] || die "missing packaging input: Resources/App.entitlements"
[ -f "$ICON_SOURCE" ] || die "missing packaging input: Resources/AppIcon.icns"

[ "$(head -c 4 "$ICON_SOURCE")" = "icns" ] || die "Resources/AppIcon.icns is not an ICNS container"

# Reviewed entitlements: the local unsandboxed build ships an empty
# dictionary; sandbox and broad entitlements must stay absent.
if grep -q "com.apple.security" "$ENTITLEMENTS_SOURCE"; then
  die "Resources/App.entitlements must stay empty (found com.apple.security*)"
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
  log "signing identity: ad-hoc '-' (local proof)"
else
  security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY" \
    || die "codesigning identity not found: $SIGN_IDENTITY"
  log "signing identity: distribution identity '$SIGN_IDENTITY'"
fi

# ── 1. Release build (single native arm64) ───────────────────────────────────
log "[1/7] swift build -c release --arch arm64"
swift build -c release --arch arm64 || die "release build failed"

# ── 2. Resolve and validate the release executable ───────────────────────────
if [ -f "$RELEASE_EXECUTABLE" ]; then
  built_executable="$RELEASE_EXECUTABLE"
elif [ -f "$RELEASE_EXECUTABLE_FALLBACK" ]; then
  built_executable="$RELEASE_EXECUTABLE_FALLBACK"
else
  die "release executable not found at $RELEASE_EXECUTABLE or $RELEASE_EXECUTABLE_FALLBACK"
fi

architectures="$(lipo -archs "$built_executable")"
[ "$architectures" = "arm64" ] || die "release executable is not a single arm64 Mach-O (lipo -archs: '$architectures')"

binary_minimum_os="$(otool -l "$built_executable" | awk '/LC_BUILD_VERSION/ { seen = 1 } seen && /minos/ { print $2; exit }')"
if [ -z "$binary_minimum_os" ]; then
  binary_minimum_os="$(otool -l "$built_executable" | awk '/LC_VERSION_MIN_MACOSX/ { seen = 1 } seen && /version/ { print $2; exit }')"
fi
[ -n "$binary_minimum_os" ] || die "could not read the Mach-O deployment target (otool)"

# The packaged Info.plist must stay internally consistent with the binary:
# LSMinimumSystemVersion must equal the actual Mach-O minos.
plist_minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST_SOURCE" 2>/dev/null)" \
  || die "Resources/Info.plist is missing LSMinimumSystemVersion"
[ "$plist_minimum_os" = "$binary_minimum_os" ] \
  || die "Info.plist LSMinimumSystemVersion ('$plist_minimum_os') does not match the binary deployment target ('$binary_minimum_os')"
log "[2/7] release executable: $built_executable (arm64, minos $binary_minimum_os)"

# ── 3. Assemble the app bundle (idempotent) ──────────────────────────────────
log "[3/7] assemble dist/WhisperBar.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
ditto "$built_executable" "$APP_BUNDLE/Contents/MacOS/Whisperbar" || die "failed to copy the release executable"
chmod 755 "$APP_BUNDLE/Contents/MacOS/Whisperbar"
ditto "$INFO_PLIST_SOURCE" "$APP_BUNDLE/Contents/Info.plist" || die "failed to copy Info.plist"
ditto "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns" || die "failed to copy AppIcon.icns"

[ -x "$APP_BUNDLE/Contents/MacOS/Whisperbar" ] || die "assembled executable is missing or not executable"
[ -f "$APP_BUNDLE/Contents/Info.plist" ] || die "assembled Info.plist is missing"
[ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ] || die "assembled AppIcon.icns is missing"

bundled_architectures="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/Whisperbar")"
[ "$bundled_architectures" = "arm64" ] || die "assembled executable is not arm64 (lipo -archs: '$bundled_architectures')"

# ── 4. Locked bundle identity checks on the assembled bundle ─────────────────
assembled_plist="$APP_BUNDLE/Contents/Info.plist"
check_plist() { # <key> <expected value>
  local actual
  if ! actual="$(/usr/libexec/PlistBuddy -c "Print :$1" "$assembled_plist" 2>/dev/null)"; then
    die "assembled Info.plist is missing $1"
  fi
  [ "$actual" = "$2" ] || die "assembled Info.plist $1 is '$actual', expected '$2'"
}
check_plist CFBundleIdentifier "$BUNDLE_ID"
check_plist CFBundleName "$APP_NAME"
check_plist CFBundleExecutable "$EXECUTABLE_NAME"
check_plist CFBundleIconFile "AppIcon"
check_plist CFBundlePackageType "$PACKAGE_TYPE"
check_plist CFBundleShortVersionString "$SHORT_VERSION"
check_plist CFBundleVersion "$BUILD_VERSION"
check_plist LSMinimumSystemVersion "$binary_minimum_os"
check_plist NSHighResolutionCapable "true"
check_plist LSUIElement "false"
check_plist NSMicrophoneUsageDescription "$MIC_USAGE_DESCRIPTION"
log "[4/7] locked bundle identity verified"

# ── 5. Sign once with the reviewed entitlements ──────────────────────────────
log "[5/7] codesign --force --sign '$SIGN_IDENTITY' (entitlements: Resources/App.entitlements)"
codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS_SOURCE" --timestamp=none "$APP_BUNDLE" \
  || die "codesign failed for identity '$SIGN_IDENTITY'"

# ── 6. Strict verification (must pass before DMG or install) ─────────────────
log "[6/7] codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" || die "strict codesign verification failed"

signed_entitlements="$(codesign -d --entitlements :- "$APP_BUNDLE" 2>/dev/null || true)"
if printf '%s' "$signed_entitlements" | grep -q "com.apple.security"; then
  die "signed bundle carries com.apple.security* entitlements"
fi

signature_info="$(codesign -dv "$APP_BUNDLE" 2>&1 || true)"
if ! printf '%s' "$signature_info" | grep -q "Identifier=$BUNDLE_ID"; then
  die "signed bundle identifier does not match $BUNDLE_ID"
fi
log "[6/7] signature verified (identifier $BUNDLE_ID)"

# ── 7. DMG creation (idempotent, after verification) ─────────────────────────
log "[7/7] hdiutil create -> dist/WhisperBar.dmg"
rm -f "$DMG_PATH"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG_PATH" \
  || die "DMG creation failed"
[ -s "$DMG_PATH" ] || die "DMG artifact is missing or empty"
hdiutil verify -quiet "$DMG_PATH" || die "DMG verification failed"

log "packaged artifacts:"
log "  app: $APP_BUNDLE"
log "  dmg: $DMG_PATH"
log "  identity: $SIGN_IDENTITY"

# ── Optional install (explicit approval only) ────────────────────────────────
if [ "$INSTALL" -eq 1 ]; then
  [ "${WHISPERBAR_ALLOW_APPLICATIONS_INSTALL:-0}" = "1" ] \
    || die "--install requires separate explicit approval: set WHISPERBAR_ALLOW_APPLICATIONS_INSTALL=1"

  log "install: scoped rollback copy of any existing bundle -> $ROLLBACK_DIR/$APP_NAME.app"
  mkdir -p "$ROLLBACK_DIR"
  if [ -d "$INSTALL_TARGET" ]; then
    rm -rf "$ROLLBACK_DIR/$APP_NAME.app"
    ditto "$INSTALL_TARGET" "$ROLLBACK_DIR/$APP_NAME.app" || die "rollback copy failed"
  fi

  rm -rf "$INSTALL_TARGET"
  ditto "$APP_BUNDLE" "$INSTALL_TARGET" || die "install copy failed"
  codesign --verify --deep --strict "$INSTALL_TARGET" || die "installed bundle fails strict verification"

  lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [ -x "$lsregister" ] || die "lsregister not found"
  "$lsregister" -f "$INSTALL_TARGET" || die "LaunchServices registration failed"

  # A still-running dist/ copy shares this bundle id. Quit it before launch so
  # LaunchServices starts the installed bundle instead of reattaching.
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8; do
    if [ -z "$(lsappinfo find bundleid="$BUNDLE_ID" 2>/dev/null | head -1 || true)" ]; then
      break
    fi
    sleep 0.4
  done
  pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
  sleep 0.5

  open "$INSTALL_TARGET" || die "LaunchServices launch failed"
  sleep 3
  app_serial_number="$(lsappinfo find bundleid="$BUNDLE_ID" 2>/dev/null | head -1 || true)"
  [ -n "$app_serial_number" ] || die "running bundle identity verification failed: no registered '$BUNDLE_ID' application"
  running_info="$(lsappinfo info "$app_serial_number" 2>/dev/null || true)"
  case "$running_info" in
    *"bundleID=\"$BUNDLE_ID\""*) ;;
    *) die "running bundle identity verification failed: '$running_info' does not match '$BUNDLE_ID'" ;;
  esac
  case "$running_info" in
    *"bundle path=\"/Applications/$APP_NAME.app\""*) log "install: launched $INSTALL_TARGET (bundle path verified)" ;;
    *) die "running bundle path verification failed: expected bundle path=$INSTALL_TARGET in '$running_info'" ;;
  esac
else
  log "no --install: /Applications was not touched (install requires separate explicit approval)"
fi
