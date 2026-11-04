#!/bin/bash
#
# Installs the newest OpenClicky on this Mac:
#
#   curl -fsSL https://github.com/Nicolas-Cilia/openclicky-fork/releases/latest/download/install-mac.sh | bash
#
# macOS only shows its "could not verify" warning for files a browser marks as downloaded, and curl
# doesn't mark them. So this skips Apple's check, which is why it first checks the app was signed
# with OpenClicky's own certificate. Update CERTIFICATE_HASH if that certificate ever changes.
#
# OPENCLICKY_INSTALL_DIR installs somewhere else and OPENCLICKY_NO_OPEN=1 doesn't open the app, which
# is how this gets tested.

# Everything is inside main, so a download cut off halfway runs nothing.
main() {
  set -euo pipefail
  local dmg_url="https://github.com/Nicolas-Cilia/openclicky-fork/releases/latest/download/OpenClicky.dmg"
  local certificate_hash="93D95886F3F4A4509392EA5116DBED47DA36B5ED"
  local install_dir="${OPENCLICKY_INSTALL_DIR:-/Applications}"
  local app="$install_dir/OpenClicky.app"

  [[ "$(uname -s)" == "Darwin" ]] || { echo "This installer is for macOS." >&2; exit 1; }
  [[ -w "$install_dir" ]] || { echo "Can't write to $install_dir. Use an administrator account." >&2; exit 1; }

  local work mount
  work="$(mktemp -d)"
  mount="$work/mount"
  mkdir "$mount"
  # shellcheck disable=SC2064 # the paths are fixed now, and the trap outlives this function's locals
  trap "hdiutil detach -quiet '$mount' 2>/dev/null || true; rm -rf '$work'" EXIT

  echo "Downloading OpenClicky..."
  curl -fL --progress-bar -o "$work/OpenClicky.dmg" "$dmg_url"
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$work/OpenClicky.dmg"

  echo "Checking its signature..."
  if ! codesign --verify --deep --strict -R="certificate leaf = H\"$certificate_hash\"" "$mount/OpenClicky.app" 2>/dev/null; then
    echo "The download isn't signed with OpenClicky's certificate, so nothing was installed." >&2
    exit 1
  fi

  echo "Installing to ${app}..."
  [[ -n "${OPENCLICKY_NO_OPEN:-}" ]] || pkill -x OpenClicky 2>/dev/null || true
  # Copied beside the old one and swapped in, so a failed copy leaves the old app working.
  ditto "$mount/OpenClicky.app" "$app.installing"
  rm -rf "$app"
  mv "$app.installing" "$app"

  if [[ -z "${OPENCLICKY_NO_OPEN:-}" ]]; then
    open "$app"
    echo "Done. OpenClicky is open: look for it at the top of your screen."
  else
    echo "Done."
  fi
}

main "$@"
