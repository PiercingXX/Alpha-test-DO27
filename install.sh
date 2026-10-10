#!/usr/bin/env bash
# Direct Order 27 alpha installer.
# Install or update:  curl -fsSL https://raw.githubusercontent.com/PiercingXX/Alpha-test-DO27/main/install.sh | bash
set -euo pipefail

REPO="PiercingXX/Alpha-test-DO27"
DEST="$HOME/.local/share/do27-alpha"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B= G= Y= R= N=; fi
say()  { printf '%s==>%s %s\n' "$B$G" "$N" "$*"; }
warn() { printf '%s!!%s  %s\n' "$B$Y" "$N" "$*"; }
die()  { printf '%sXX%s  %s\n' "$B$R" "$N" "$*"; printf '    Need help? Post this message in the alpha channel on Discord.\n'; exit 1; }

printf '\n%sDirect Order 27: alpha installer%s\n\n' "$B" "$N"

# 1. The system.
[ "$(id -u)" -ne 0 ] || die "Don't run this as root. Run it as your normal user (it asks for your password once if it needs to)."
. /etc/os-release 2>/dev/null || true
case " ${ID:-} ${ID_LIKE:-} " in
  *" arch "*|*" cachyos "*) say "System: ${PRETTY_NAME:-Arch Linux}" ;;
  *) die "This alpha runs on Arch Linux or CachyOS only. Your system is: ${PRETTY_NAME:-unknown}." ;;
esac
[ "$(uname -m)" = x86_64 ] || die "This alpha needs a 64-bit PC (x86_64)."

# 2. Packages the game needs (one password prompt, only if something is missing).
need=(curl tar zstd vulkan-icd-loader)
gpu=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' || true)
case "$gpu" in
  *NVIDIA*|*nvidia*) need+=(nvidia-utils) ;;
  *AMD*|*ATI*|*Radeon*) need+=(vulkan-radeon) ;;
  *Intel*) need+=(vulkan-intel) ;;
esac
missing=()
for p in "${need[@]}"; do
  # Any installed driver that provides the package counts (nvidia-open, 580xx and so on).
  pacman -T "$p" >/dev/null 2>&1 || missing+=("$p")
done
if [ ${#missing[@]} -gt 0 ] && [ -n "${DO27_AUTOUPDATE:-}" ]; then
  warn "Missing packages (${missing[*]}): run the install command in a terminal to add them."
elif [ ${#missing[@]} -gt 0 ]; then
  say "Installing what the game needs: ${missing[*]}"
  say "Your password may be asked for now."
  sudo pacman -S --needed --noconfirm "${missing[@]}" || die "Couldn't install: ${missing[*]}. Try: sudo pacman -Syu, then run this installer again."
else
  say "Everything the game needs is already installed."
fi

# 3. Space.
mkdir -p "$DEST" "$BIN" "$APPS"
free_gb=$(df -Pk "$DEST" | awk 'NR==2 {print int($4/1048576)}')
[ "${free_gb:-0}" -ge 20 ] || die "Not enough free space in your home folder: ${free_gb} GB free, the game needs 20 GB."

# 4. The latest alpha build.
say "Looking for the latest alpha build..."
api=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null) || api=""
url=$(printf '%s' "$api" | grep -oE '"browser_download_url": *"[^"]+\.tar\.zst"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/' || true)
sum_url=$(printf '%s' "$api" | grep -oE '"browser_download_url": *"[^"]+\.sha256"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/' || true)
tag=$(printf '%s' "$api" | grep -oE '"tag_name": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
if [ -z "$url" ]; then
  warn "No alpha build has been released yet. Your system is ready; run this same command again on test day."
  exit 0
fi
if [ -f "$DEST/VERSION" ] && [ "$(cat "$DEST/VERSION")" = "$tag" ] && [ -x "$DEST/game/run.sh" ]; then
  say "You already have the latest build ($tag)."
else
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  say "Downloading $tag..."
  curl -fL --progress-bar -o "$tmp/game.tar.zst" "$url" || die "The download failed. Check your internet connection and run the command again."
  if [ -n "$sum_url" ]; then
    curl -fsSL -o "$tmp/game.sha256" "$sum_url" || die "Couldn't download the checksum file."
    want=$(awk '{print $1}' "$tmp/game.sha256"); have=$(sha256sum "$tmp/game.tar.zst" | awk '{print $1}')
    [ "$want" = "$have" ] || die "The download is damaged (checksum mismatch). Run the command again."
    say "Download verified."
  fi
  say "Unpacking..."
  mkdir -p "$tmp/x"
  zstd -dc --long=27 "$tmp/game.tar.zst" | tar -C "$tmp/x" -xf - || die "Couldn't unpack the game."
  top=$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -x "$top/run.sh" ] || die "The build looks incomplete (no run.sh). Please report this."
  rm -rf "$DEST/game.old"; [ -d "$DEST/game" ] && mv "$DEST/game" "$DEST/game.old"
  mv "$top" "$DEST/game"; rm -rf "$DEST/game.old"
  printf '%s\n' "$tag" > "$DEST/VERSION"
fi

# 5. A command and an app-menu entry.
cat > "$BIN/do27" <<EOF
#!/usr/bin/env bash
# Auto-update: if a newer alpha build is out, install it before starting (a few seconds; skipped when offline).
latest=\$(curl -fsS --max-time 4 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | grep -oE '"tag_name": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"\$/\1/' || true)
if [ -n "\$latest" ] && [ "\$latest" != "\$(cat "$DEST/VERSION" 2>/dev/null)" ]; then
  command -v notify-send >/dev/null && notify-send "Direct Order 27" "Updating to \$latest..." 2>/dev/null || true
  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install.sh" | DO27_AUTOUPDATE=1 bash >> "$DEST/update.log" 2>&1 || true
fi
cd "$DEST/game" && exec ./run.sh "\$@"
EOF
chmod +x "$BIN/do27"
icon="$DEST/game/icon.png"; [ -f "$icon" ] || icon=applications-games
cat > "$APPS/do27-alpha.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Direct Order 27 (alpha)
Comment=Hover-tank RTS/FPS alpha test
Exec=$BIN/do27
Icon=$icon
Terminal=false
Categories=Game;
EOF
command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" >/dev/null 2>&1 || true
case ":$PATH:" in *":$BIN:"*) ;; *) warn "Add ~/.local/bin to your PATH to use the 'do27' command (the app menu entry works either way)." ;; esac

# 6. Uninstaller.
cat > "$BIN/do27-uninstall" <<EOF
#!/usr/bin/env bash
rm -rf "$DEST" "$APPS/do27-alpha.desktop" "$BIN/do27" "$BIN/do27-uninstall"
echo "Direct Order 27 alpha removed. Your settings in ~/.config/DO27 are kept; delete that folder too for a full clean-up."
EOF
chmod +x "$BIN/do27-uninstall"

printf '\n%sDone!%s Open %sDirect Order 27 (alpha)%s from your app menu, or type %sdo27%s in a terminal.\n' "$B$G" "$N" "$B" "$N" "$B" "$N"
printf 'The game updates itself each time you start it. To remove the game: do27-uninstall\n\n'
