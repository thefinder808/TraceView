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
#   build           — debug binary only (swift build)
#   app             — debug .app bundle in build/TraceView.app
#   run             — build .app, exec the binary directly (stdout visible)
#   open            — build .app, launch via `open` (proper LaunchServices launch)
#   release         — release .app bundle (ad-hoc signed, for local use)
#   install         — release .app copied to /Applications
#   notarize        — Developer ID signed .app + DMG, notarized + stapled, ready
#                     for a public GitHub Release. Requires the keychain profile
#                     set up via `xcrun notarytool store-credentials`. Also runs
#                     generate_appcast against the new DMG + prior gh-pages
#                     releases, leaving the appcast in build/appcast/.
#   publish-appcast — Push the generated appcast.xml + DMGs to the gh-pages
#                     branch so installed apps see the new version via Sparkle.
#   clean           — remove build artifacts
set -euo pipefail

APP_NAME="TraceView"
BUNDLE_ID="com.traceview.app"
BUNDLE_VERSION="1.1.1"
BUNDLE_SHORT_VERSION="1.1.1"
OUT_DIR="build"
APP_BUNDLE="${OUT_DIR}/${APP_NAME}.app"
ICON_SRC="Resources/AppIcon.icns"
ICONSET_SRC="Resources/AppIcon.iconset"
ENTITLEMENTS_FILE="Resources/TraceView.entitlements"

# Developer ID cert used for distribution (public releases). Run
# `security find-identity -v -p codesigning` to see what's installed.
DEVELOPER_ID="Developer ID Application: Nathaniel Graham (Q6LRJQSA42)"
# Keychain profile storing Apple ID + app-specific password + team ID for
# notarytool. Set up once with:
#   xcrun notarytool store-credentials traceview-notary \
#     --apple-id <email> --team-id Q6LRJQSA42 --password <app-specific>
NOTARY_PROFILE="traceview-notary"

# Sparkle auto-update configuration. The appcast feed lives on GitHub Pages.
SU_FEED_URL="https://thefinder808.github.io/TraceView/appcast.xml"
# EdDSA public key, generated once via:
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys
# Private key is auto-stored in the login Keychain as "https://sparkle-project.org".
# Override via env: SU_PUBLIC_ED_KEY="..." ./build.sh notarize
# Left empty means signature verification is skipped at runtime (fine for dev;
# notarize subcommand refuses to proceed without it).
SU_PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-OkisT+RinXia2GCpnFmXZ2ArHab4lYWXa9LPg4IsGoM=}"

make_info_plist() {
  # Sparkle's EdDSA key is optional in the plist — emit it only when set,
  # so dev builds without a key don't fail signature verification on every
  # check. Notarized builds set this via the SU_PUBLIC_ED_KEY env var or
  # by editing the default at the top of this script.
  local sparkle_ed_key_block=""
  if [[ -n "$SU_PUBLIC_ED_KEY" ]]; then
    sparkle_ed_key_block="  <key>SUPublicEDKey</key>
  <string>${SU_PUBLIC_ED_KEY}</string>
"
  fi

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
  <key>SUFeedURL</key>
  <string>${SU_FEED_URL}</string>
${sparkle_ed_key_block}  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
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

embed_sparkle() {
  # Copy Sparkle.framework from the SwiftPM artifact cache into the .app.
  # SPM extracts the XCFramework under .build/artifacts/sparkle/Sparkle/
  # Sparkle.xcframework/<slice>/Sparkle.framework. We deliberately skip the
  # `.build/index-build/...` mirror that SourceKit maintains in parallel —
  # that copy is for the indexer, not for shipping.
  local sparkle_src
  sparkle_src=$(find .build/artifacts -type d -name 'Sparkle.framework' 2>/dev/null \
                | grep -v '/index-build/' | head -1)
  if [[ -z "$sparkle_src" || ! -d "$sparkle_src" ]]; then
    echo "✗ Sparkle.framework not found under .build/artifacts/."
    echo "  Run 'swift package resolve' to fetch it, then retry."
    exit 1
  fi

  mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
  cp -R "$sparkle_src" "${APP_BUNDLE}/Contents/Frameworks/"
}

sign_bundle_inside_out() {
  # Sign the .app inside-out: nested XPC services and helpers first, then
  # Sparkle.framework, then the .app itself. NEVER use `codesign --deep` —
  # it signs nested components with the outer identity/entitlements (or in
  # arbitrary order) and breaks Sparkle's XPC services.
  #
  # The Downloader.xpc ships with com.apple.security.network.client baked
  # in by Sparkle; --preserve-metadata=entitlements keeps that intact when
  # we re-sign with our Developer ID. Strip it and downloads fail silently.
  local sign_id="$1"        # "-" for ad-hoc, or Developer ID string
  local sparkle_versions="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework/Versions/B"

  if [[ "$sign_id" == "-" ]]; then
    codesign --force --sign - "${sparkle_versions}/XPCServices/Installer.xpc" >/dev/null 2>&1 || true
    codesign --force --sign - "${sparkle_versions}/XPCServices/Downloader.xpc" >/dev/null 2>&1 || true
    codesign --force --sign - "${sparkle_versions}/Autoupdate" >/dev/null 2>&1 || true
    codesign --force --sign - "${sparkle_versions}/Updater.app" >/dev/null 2>&1 || true
    codesign --force --sign - "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework" >/dev/null 2>&1 || true
    codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
  else
    local cs=(--force --sign "$sign_id" --options runtime --timestamp)
    codesign "${cs[@]}" "${sparkle_versions}/XPCServices/Installer.xpc"
    codesign "${cs[@]}" --preserve-metadata=entitlements "${sparkle_versions}/XPCServices/Downloader.xpc"
    codesign "${cs[@]}" "${sparkle_versions}/Autoupdate"
    codesign "${cs[@]}" "${sparkle_versions}/Updater.app"
    codesign "${cs[@]}" "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
    codesign "${cs[@]}" --entitlements "$ENTITLEMENTS_FILE" "$APP_BUNDLE"
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
  embed_sparkle
  make_info_plist

  # Sign inside-out — ad-hoc for dev iteration, Developer ID + hardened
  # runtime + timestamp + entitlements for notarization.
  sign_bundle_inside_out "$sign_id"

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

  # 1a. Refuse to ship a notarized build without the Sparkle public key.
  # Without it, Sparkle skips signature verification and updates can be
  # MITM'd. Set SU_PUBLIC_ED_KEY in the env or at the top of this script.
  if [[ -z "$SU_PUBLIC_ED_KEY" ]]; then
    echo "✗ SU_PUBLIC_ED_KEY is empty — refusing to notarize an unverified build."
    echo "  Generate the keypair once with:"
    echo "    .build/artifacts/sparkle/Sparkle/bin/generate_keys"
    echo "  Then either export SU_PUBLIC_ED_KEY=… in your shell, or paste the"
    echo "  public key into the SU_PUBLIC_ED_KEY default at the top of build.sh."
    exit 1
  fi

  # 1b. Entitlements file is required for Developer ID signing path.
  if [[ ! -f "$ENTITLEMENTS_FILE" ]]; then
    echo "✗ Entitlements file not found: ${ENTITLEMENTS_FILE}"
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

  # 9. Generate the Sparkle appcast against this DMG + any previously
  # published releases. generate_appcast diffs the folder against the
  # existing appcast.xml and emits delta updates for prior versions.
  echo "→ Generating Sparkle appcast…"
  generate_appcast_for_release "$dmg_path"

  echo ""
  echo "✓ Release artifact: ${dmg_path}"
  echo "  Next steps:"
  echo "    1. Upload to GitHub Releases:"
  echo "         gh release create v${version} ${dmg_path} --notes-file <notes.md>"
  echo "    2. Publish the appcast to gh-pages so installed apps see the update:"
  echo "         ./build.sh publish-appcast"
}

generate_appcast_for_release() {
  # Stage the new DMG alongside prior releases pulled from the gh-pages
  # branch, then run generate_appcast against that combined folder.
  # Output lives at build/appcast/{appcast.xml, *.dmg, *.delta}; the
  # publish-appcast subcommand syncs it to the gh-pages worktree.
  local new_dmg="$1"
  local appcast_dir="${OUT_DIR}/appcast"
  local gh_pages_wt="${OUT_DIR}/gh-pages"
  local generate_appcast=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"

  if [[ ! -x "$generate_appcast" ]]; then
    echo "✗ generate_appcast not found at ${generate_appcast}"
    echo "  Run 'swift package resolve' first."
    exit 1
  fi

  rm -rf "$appcast_dir"
  mkdir -p "$appcast_dir"
  cp "$new_dmg" "$appcast_dir/"

  # Pull prior releases from the gh-pages branch so generate_appcast can
  # produce delta updates against them. No-op on first release.
  rm -rf "$gh_pages_wt"
  if git show-ref --verify --quiet refs/remotes/origin/gh-pages \
     || git show-ref --verify --quiet refs/heads/gh-pages; then
    git worktree add "$gh_pages_wt" gh-pages 2>/dev/null \
      || { git fetch origin gh-pages && git worktree add "$gh_pages_wt" gh-pages; }
    if [[ -d "${gh_pages_wt}/releases" ]]; then
      cp -R "${gh_pages_wt}/releases/." "$appcast_dir/" 2>/dev/null || true
    fi
  else
    echo "  (no gh-pages branch yet — generating initial appcast only)"
  fi

  "$generate_appcast" "$appcast_dir"
  echo "✓ Appcast at ${appcast_dir}/appcast.xml"
}

publish_appcast() {
  # Copy the generated appcast.xml + release archives onto the gh-pages
  # worktree, commit, and push. Kept separate from `notarize` so users
  # can re-run notarization without touching the public feed.
  local appcast_dir="${OUT_DIR}/appcast"
  local gh_pages_wt="${OUT_DIR}/gh-pages"

  if [[ ! -f "${appcast_dir}/appcast.xml" ]]; then
    echo "✗ No appcast at ${appcast_dir}/appcast.xml — run './build.sh notarize' first."
    exit 1
  fi
  if [[ ! -d "$gh_pages_wt" ]]; then
    git worktree add "$gh_pages_wt" gh-pages 2>/dev/null \
      || { git fetch origin gh-pages && git worktree add "$gh_pages_wt" gh-pages; }
  fi

  mkdir -p "${gh_pages_wt}/releases"
  # Copy the appcast at the root (matches SU_FEED_URL) and DMGs/deltas
  # under releases/. Sparkle URLs in the generated appcast are relative.
  cp "${appcast_dir}/appcast.xml" "${gh_pages_wt}/appcast.xml"
  find "$appcast_dir" -maxdepth 1 -type f \( -name '*.dmg' -o -name '*.delta' \) \
    -exec cp {} "${gh_pages_wt}/releases/" \;

  (
    cd "$gh_pages_wt"
    git add appcast.xml releases/
    if git diff --cached --quiet; then
      echo "✓ Nothing to publish — appcast already current."
    else
      git commit -m "Publish appcast for v${BUNDLE_SHORT_VERSION}"
      echo "→ Pushing gh-pages…"
      git push origin gh-pages
      echo "✓ Published. Feed: ${SU_FEED_URL}"
    fi
  )

  # Leave the worktree in place so re-runs are fast; clean on demand
  # with: git worktree remove build/gh-pages
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
  publish-appcast)
    publish_appcast
    ;;
  clean)
    swift package clean
    rm -rf "$OUT_DIR" dist
    ;;
  *)
    echo "usage: $0 {build|app|run|open|release|install|notarize|publish-appcast|clean}"
    exit 1
    ;;
esac
