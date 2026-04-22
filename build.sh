#!/usr/bin/env bash
# build.sh — build TraceView as a real .app bundle and run/install it.
#
# Without a proper .app bundle, SwiftUI/AppKit misbehave in subtle ways
# (menu bar, UserDefaults domain, file-access TCC prompts, window
# restoration, services menu, etc). This wrapper compiles with SPM and
# assembles a minimal .app around the binary, ad-hoc code-signed.
#
# Subcommands:
#   build     — debug binary only (swift build)
#   app       — debug .app bundle in build/TraceView.app
#   run       — build .app, exec the binary directly (stdout visible)
#   open      — build .app, launch via `open` (proper LaunchServices launch)
#   release   — release .app bundle
#   install   — release .app copied to /Applications
#   clean     — remove build artifacts
set -euo pipefail

APP_NAME="TraceView"
BUNDLE_ID="com.traceview.app"
BUNDLE_VERSION="0.1"
BUNDLE_SHORT_VERSION="0.1.0"
OUT_DIR="build"
APP_BUNDLE="${OUT_DIR}/${APP_NAME}.app"

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
  <string>TraceView</string>
</dict>
</plist>
EOF
}

build_bundle() {
  local config="$1"   # "debug" or "release"
  local flag=""
  [[ "$config" == "release" ]] && flag="-c release"

  # shellcheck disable=SC2086
  swift build $flag

  local binary_path=".build/${config}/${APP_NAME}"
  [[ -f "$binary_path" ]] || { echo "✗ binary not found at ${binary_path}"; exit 1; }

  rm -rf "$APP_BUNDLE"
  mkdir -p "${APP_BUNDLE}/Contents/MacOS"
  mkdir -p "${APP_BUNDLE}/Contents/Resources"
  cp "$binary_path" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
  make_info_plist

  # Ad-hoc sign. Required for Sandbox/TCC APIs to behave; otherwise they
  # sometimes silently fail or prompt with the wrong app name.
  codesign --force --sign - --deep "$APP_BUNDLE" >/dev/null 2>&1 || true

  echo "✓ ${APP_BUNDLE}"
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
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP_BUNDLE" "/Applications/"
    echo "✓ installed to /Applications/${APP_NAME}.app"
    ;;
  clean)
    swift package clean
    rm -rf "$OUT_DIR"
    ;;
  *)
    echo "usage: $0 {build|app|run|open|release|install|clean}"
    exit 1
    ;;
esac
