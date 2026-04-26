#!/usr/bin/env bash
# build.sh — build TraceView as a real .app bundle and run/install it.
#
# Without a proper .app bundle, SwiftUI/AppKit misbehave in subtle ways
# (menu bar, UserDefaults domain, file-access TCC prompts, window
# restoration, services menu, etc). This wrapper compiles with SPM and
# assembles a minimal .app around the binary, code-signed ad-hoc (for
# dev) or with a Developer ID cert (for public distribution).
#
# Subcommands:
#   build     — debug binary only (swift build)
#   app       — debug .app bundle in build/TraceView.app
#   run       — build .app, exec the binary directly (stdout visible)
#   open      — build .app, launch via `open` (proper LaunchServices launch)
#   release   — release .app bundle (ad-hoc signed, for local use)
#   install   — release .app copied to /Applications
#   notarize  — Developer ID signed .app + DMG, notarized + stapled, ready
#               for a public GitHub Release. Requires the keychain profile
#               set up via `xcrun notarytool store-credentials`.
#   clean     — remove build artifacts
set -euo pipefail

APP_NAME="TraceView"
BUNDLE_ID="com.traceview.app"
BUNDLE_VERSION="1.0.3"
BUNDLE_SHORT_VERSION="1.0.3"
OUT_DIR="build"
APP_BUNDLE="${OUT_DIR}/${APP_NAME}.app"
ICON_SRC="Resources/AppIcon.icns"
ICONSET_SRC="Resources/AppIcon.iconset"

# Developer ID cert used for distribution (public releases). Run
# `security find-identity -v -p codesigning` to see what's installed.
DEVELOPER_ID="Developer ID Application: Nathaniel Graham (Q6LRJQSA42)"
# Keychain profile storing Apple ID + app-specific password + team ID for
# notarytool. Set up once with:
#   xcrun notarytool store-credentials traceview-notary \
#     --apple-id <email> --team-id Q6LRJQSA42 --password <app-specific>
NOTARY_PROFILE="traceview-notary"

make_info_plist() {
  cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${BUNDLE_SHORT_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUNDLE_VERSION}</string>
  <key>CFBundleSignature</key>
  <string>????</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key>
  <true/>
  <key>NSSupportsSuddenTermination</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>© 2026 Nathaniel Graham. MIT License.</string>
</dict>
</plist>
EOF
}

build_icon() {
  # Regenerate AppIcon.icns from the iconset if the iconset is newer.
  # No-op if the .icns is already up to date. Requires iconutil (Xcode CLI).
  if [[ -d "$ICONSET_SRC" ]]; then
    if [[ ! -f "$ICON_SRC" ]] || [[ "$ICONSET_SRC" -nt "$ICON_SRC" ]]; then
      iconutil -c icns "$ICONSET_SRC" -o "$ICON_SRC"
      echo "✓ regenerated $ICON_SRC"
    fi
  fi
}

build_bundle() {
  local config="$1"       # "debug" or "release"
  local sign_id="${2:--}" # signing identity; "-" = ad-hoc
  local flag=""
  [[ "$config" == "release" ]] && flag="-c release"

  # shellcheck disable=SC2086
  swift build $flag
  build_icon

  local binary_path=".build/${config}/${APP_NAME}"
  [[ -f "$binary_path" ]] || { echo "✗ binary not found at ${binary_path}"; exit 1; }

  rm -rf "$APP_BUNDLE"
  mkdir -p "${APP_BUNDLE}/Contents/MacOS"
  mkdir -p "${APP_BUNDLE}/Contents/Resources"
  cp "$binary_path" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
  [[ -f "$ICON_SRC" ]] && cp "$ICON_SRC" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
  make_info_plist

  # Ad-hoc keeps dev loop fast; Developer ID + hardened runtime + timestamp
  # is required for notarization and Gatekeeper approval on download.
  if [[ "$sign_id" == "-" ]]; then
    codesign --force --deep --sign "$sign_id" "$APP_BUNDLE" >/dev/null 2>&1 || true
  else
    codesign --force --deep --sign "$sign_id" --options runtime --timestamp "$APP_BUNDLE"
  fi

  echo "✓ ${APP_BUNDLE}"
}

build_and_notarize() {
  # Full public-release pipeline: Developer ID sign the .app, verify,
  # wrap it in a DMG with a drag-to-Applications target, sign the DMG,
  # submit to Apple notary, staple the ticket to both, and emit the
  # final DMG at dist/<APP>-<version>.dmg.
  local version="$BUNDLE_SHORT_VERSION"
  local dist_dir="dist"
  local dmg_staging="${OUT_DIR}/dmg-stage"
  local dmg_path="${dist_dir}/${APP_NAME}-${version}.dmg"

  # 1. Check Developer ID cert is installed
  if ! security find-identity -v -p codesigning | grep -q "${DEVELOPER_ID}"; then
    echo "✗ Developer ID cert not found in keychain:"
    echo "    ${DEVELOPER_ID}"
    echo "  Install it from Apple Developer → Certificates, or via Xcode."
    exit 1
  fi

  # 2. Build + sign with Developer ID (hardened runtime)
  echo "→ Building release .app and signing with Developer ID…"
  build_bundle release "$DEVELOPER_ID"

  # 3. Verify the signature is notarization-ready
  echo "→ Verifying signature…"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  codesign --display --verbose=2 "$APP_BUNDLE" 2>&1 | grep -E "Authority|TeamIdentifier|flags" || true

  # 4. Build the DMG via create-dmg — positioned icons, sized window,
  #    hidden .app extension, drag-to-/Applications UX. Much nicer than
  #    raw hdiutil (which gives you a plain file list). Requires:
  #      brew install create-dmg
  #    create-dmg uses AppleScript under the hood to set the Finder view,
  #    which may prompt for "System Events" / "Finder" automation the
  #    first time — allow it in System Settings → Privacy & Security →
  #    Automation if you hit that dialog.
  echo "→ Building DMG with create-dmg…"
  rm -rf "$dmg_staging"
  mkdir -p "$dmg_staging" "$dist_dir"
  cp -R "$APP_BUNDLE" "$dmg_staging/"
  rm -f "$dmg_path"
  create-dmg \
    --volname "$APP_NAME" \
    --window-size 540 380 \
    --icon-size 128 \
    --icon "${APP_NAME}.app" 140 190 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 400 190 \
    --no-internet-enable \
    "$dmg_path" \
    "$dmg_staging"

  # 5. Sign the DMG itself so Gatekeeper treats the container as first-
  #    class (no "downloaded from the internet" scan on end-user machines).
  #    Timestamped so notarization accepts it.
  echo "→ Signing DMG…"
  codesign --force --sign "$DEVELOPER_ID" --timestamp "$dmg_path"

  # 6. Submit to Apple's notary service and wait for the verdict. This
  #    usually takes 2-15 minutes; `--wait` blocks until done and fails
  #    the script with a non-zero exit on rejection.
  echo "→ Submitting to Apple notary service (this can take several minutes)…"
  xcrun notarytool submit "$dmg_path" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  # 7. Staple the notarization ticket to both the app and the DMG so
  #    Gatekeeper can verify offline.
  echo "→ Stapling notarization ticket…"
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler staple "$dmg_path"

  # 8. Final sanity check: Gatekeeper should now accept the app/DMG as
  #    a notarized, signed, from-the-internet-safe artifact.
  echo "→ Verifying Gatekeeper acceptance…"
  spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"

  # Clean up staging
  rm -rf "$dmg_staging"

  echo ""
  echo "✓ Release artifact: ${dmg_path}"
  echo "  Upload to GitHub Releases with:"
  echo "    gh release create v${version} ${dmg_path} --notes-file <notes.md>"
}

case "${1:-run}" in
  build)
    swift build
    ;;
  app)
    build_bundle debug
    ;;
  run)
    build_bundle debug
    # Exec the binary directly: stdout stays visible for dev iteration,
    # but the binary still finds its bundle via NSBundle.main lookup.
    exec "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
    ;;
  open)
    build_bundle debug
    open "$APP_BUNDLE"
    ;;
  release)
    build_bundle release
    ;;
  install)
    build_bundle release
    # Kill any running instance so `cp -R` isn't blocked on a busy binary.
    pkill -x "$APP_NAME" 2>/dev/null || true

    DEST="/Applications/${APP_NAME}.app"
    if [[ -w "/Applications" ]]; then
      rm -rf "$DEST"
      cp -R "$APP_BUNDLE" "$DEST"
    else
      echo "→ /Applications requires admin; you'll be prompted for your password"
      sudo rm -rf "$DEST"
      sudo cp -R "$APP_BUNDLE" "$DEST"
    fi
    # Refresh LaunchServices so the Finder picks up the new icon/version.
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
      -f "$DEST" 2>/dev/null || true
    echo "✓ installed $DEST"
    echo "  launch with: open -a $APP_NAME"
    ;;
  notarize)
    build_and_notarize
    ;;
  clean)
    swift package clean
    rm -rf "$OUT_DIR" dist
    ;;
  *)
    echo "usage: $0 {build|app|run|open|release|install|notarize|clean}"
    exit 1
    ;;
esac
