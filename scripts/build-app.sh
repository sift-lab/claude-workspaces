#!/bin/zsh
# Builds Workspaces.app in build/. With --install, copies it to ~/Applications.
# WORKSPACES_BUILD_JOBS limits the compile jobs (the app's own update build uses 2).
set -euo pipefail
cd "$(dirname "$0")/.."

JOBS=()
[[ -n "${WORKSPACES_BUILD_JOBS:-}" ]] && JOBS=(-j "$WORKSPACES_BUILD_JOBS")
swift build -c release "${JOBS[@]}"
BIN="$(swift build -c release --show-bin-path)"
APP=build/Workspaces.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Workspaces" "$APP/Contents/MacOS/Workspaces"
cp "$BIN/workspaces-hook" "$APP/Contents/MacOS/workspaces-hook"
# Only SwiftTerm's Metal renderer reads this bundle; it looks in Contents/Resources.
cp -R "$BIN/SwiftTerm_SwiftTerm.bundle" "$APP/Contents/Resources/"
# Regenerate with: swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.workspaces.app</string>
  <key>CFBundleName</key><string>Workspaces</string>
  <key>CFBundleDisplayName</key><string>Workspaces</string>
  <key>CFBundleExecutable</key><string>Workspaces</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <!-- Without it, macOS denies Apple Events from the sessions silently (-1743) instead of asking. -->
  <key>NSAppleEventsUsageDescription</key><string>O Workspaces roda sessões do Claude Code e terminais que podem controlar outros apps.</string>
</dict>
</plist>
PLIST

# The commit and the repository the app updates itself from. In a worktree (the app's own update
# build) the repository is the main checkout, which WORKSPACES_REPOSITORY can also name.
if git rev-parse --git-dir >/dev/null 2>&1; then
  REPO="${WORKSPACES_REPOSITORY:-$(cd "$(git rev-parse --git-common-dir)/.." && pwd)}"
  DIRTY=false
  [[ -n "$(git status --porcelain --untracked-files=no)" ]] && DIRTY=true
  PLIST_FILE="$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$PLIST_FILE"
  plutil -insert WorkspacesCommit -string "$(git rev-parse HEAD)" "$PLIST_FILE"
  plutil -insert WorkspacesRepository -string "$REPO" "$PLIST_FILE"
  plutil -insert WorkspacesDirty -bool "$DIRTY" "$PLIST_FILE"
fi

# Privacy grants (Full Disk Access, Automation) are keyed to the signing identity.
# An ad-hoc signature changes on every build and drops them, so prefer a real certificate.
# Override with WORKSPACES_SIGN_IDENTITY="<name or SHA-1>"; "-" forces ad-hoc.
IDENTITY="${WORKSPACES_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"
[[ "$IDENTITY" == "-" ]] && echo "Aviso: assinatura ad-hoc, as permissões do macOS somem a cada build." >&2

codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/workspaces-hook"
codesign --force --sign "$IDENTITY" "$APP"
echo "Pronto: $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Workspaces.app
  cp -R "$APP" ~/Applications/
  echo "Instalado em ~/Applications/Workspaces.app"
fi
