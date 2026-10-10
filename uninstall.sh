#!/usr/bin/env bash
# Direct Order 27 alpha: remove the game.
#   curl -fsSL https://raw.githubusercontent.com/PiercingXX/Alpha-test-DO27/main/uninstall.sh | bash
# Same as the do27-uninstall command the installer adds. Your alpha username stays reserved.
set -uo pipefail
APPS="$HOME/.local/share/applications"
rm -rf "$HOME/.local/share/do27-alpha" "$APPS/do27-alpha.desktop" "$HOME/.local/bin/do27" "$HOME/.local/bin/do27-uninstall"
rm -rf "$HOME/.config/DO27" "${XDG_CACHE_HOME:-$HOME/.cache}/do27" "$HOME/.local/share/DO27"
data="${XDG_DATA_HOME:-$HOME/.local/share}/do27"
if [ -d "$data" ]; then
  find "$data" -mindepth 1 -maxdepth 1 ! -name profile -exec rm -rf {} +
fi
command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" >/dev/null 2>&1 || true
echo "Direct Order 27 alpha removed. Your alpha username stays reserved for the rest of the alpha."
