#!/usr/bin/env bash
# Direct Order 27 alpha installer.
# Arch Linux, CachyOS, Ubuntu 22.04+. Install or update:  curl -fsSL https://raw.githubusercontent.com/PiercingXX/Alpha-test-DO27/main/install.sh | bash
# Running it again updates the game. Nothing here needs editing.
set -euo pipefail

REPO="PiercingXX/Alpha-test-DO27"
API="https://api.github.com/repos/$REPO/releases/latest"
RAW="https://raw.githubusercontent.com/$REPO/main"
# Release-test hook: a local copy of the release (latest.json in the GitHub API
# shape, install.sh and the assets) served over HTTP on the LAN.
MIRROR="${DO27_ALPHA_MIRROR:-}"
if [ -n "$MIRROR" ]; then API="$MIRROR/latest.json"; RAW="$MIRROR"; fi

DEST="$HOME/.local/share/do27-alpha"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B= G= Y= R= N=; fi
say()  { printf '%s==>%s %s\n' "$B$G" "$N" "$*"; }
warn() { printf '%s!!%s  %s\n' "$B$Y" "$N" "$*"; }
die()  { printf '%sXX%s  %s\n' "$B$R" "$N" "$*"; printf '    Need help? Post this message in the alpha channel on Discord.\n'; exit 1; }
# Replace a file with a new inode, so a script that is running from it (the
# do27 launcher during an auto-update) keeps reading its old copy.
put() { local tmp; tmp=$(mktemp "$1.XXXXXX"); cat > "$tmp"; chmod "${2:-644}" "$tmp"; mv -f "$tmp" "$1"; }

printf '\n%sDirect Order 27: alpha installer%s\n\n' "$B" "$N"

# 1. The system: Arch/CachyOS (pacman) or Ubuntu 22.04+ and its family (apt).
[ "$(id -u)" -ne 0 ] || die "Don't run this as root. Run it as your normal user (it asks for your password once if it needs to)."
. /etc/os-release 2>/dev/null || true
case " ${ID:-} ${ID_LIKE:-} " in
  *" arch "*|*" cachyos "*) family=arch; UPDATE_CMD="sudo pacman -Syu" ;;
  *" ubuntu "*|*" debian "*) family=apt; UPDATE_CMD="sudo apt update && sudo apt full-upgrade" ;;
  *) die "This alpha runs on Arch Linux, CachyOS or Ubuntu (22.04 or newer) only. Your system is: ${PRETTY_NAME:-unknown}." ;;
esac
say "System: ${PRETTY_NAME:-$ID}"
[ "$(uname -m)" = x86_64 ] || die "This alpha needs a 64-bit PC (x86_64)."
if [ "$family" = arch ]; then
  command -v pacman >/dev/null || die "pacman not found. This alpha needs Arch Linux, CachyOS or Ubuntu."
else
  command -v apt-get >/dev/null && command -v dpkg >/dev/null || die "apt-get not found. This alpha needs Arch Linux, CachyOS or Ubuntu."
fi
# Alpha builds are made on an older system library (glibc 2.35, Ubuntu 22.04's), so an Arch
# box a few weeks or months behind still runs them; this stops a very old one before the
# big download. Each build's own floor (build-info.toml) is checked again after unpacking.
MIN_GLIBC=2.35
have_glibc=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || true)
if [ -n "$have_glibc" ] && [ "$(printf '%s\n%s\n' "$MIN_GLIBC" "$have_glibc" | sort -V | head -1)" != "$MIN_GLIBC" ]; then
  if [ "$family" = arch ]; then
    die "Your system is out of date (glibc $have_glibc, the game needs $MIN_GLIBC or newer). Update it with: $UPDATE_CMD  then restart your PC and run the install command again."
  fi
  die "Your system is too old (glibc $have_glibc, the game needs $MIN_GLIBC or newer). This alpha needs Ubuntu 22.04 or newer."
fi

# 2. Packages the game needs (one password prompt, only if something is missing).
# The graphics vendor comes from /sys (PCI vendor ids), so lspci isn't needed. The
# game runs on the strongest card: an NVIDIA card wins over an AMD or Intel one (often
# the CPU's built-in graphics), so only that card's Vulkan driver is installed.
vendors=$(cat /sys/class/drm/card*/device/vendor 2>/dev/null | sort -u | tr '\n' ' ')
missing=()
if [ "$family" = arch ]; then
  need=(curl tar zstd vulkan-icd-loader vulkan-tools)
  case "$vendors" in
    *0x10de*) need+=(nvidia-utils) ;;
    *0x1002*) need+=(vulkan-radeon) ;;
    *0x8086*) need+=(vulkan-intel) ;;
  esac
  for p in "${need[@]}"; do
    # Any installed package that provides it counts (nvidia-open, 580xx and so on).
    pacman -T "$p" >/dev/null 2>&1 || missing+=("$p")
  done
else
  # Ubuntu: the Vulkan loader, Mesa's Vulkan drivers (AMD/Intel), the tools, and the few
  # libraries the game links (a desktop install has them all already). The NVIDIA driver
  # is never installed from here: Ubuntu's own "Additional Drivers" picks the right one.
  # 24.04 (and Debian 13) renamed libasound2 to libasound2t64 (64-bit time).
  case "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" in
    jammy|bookworm) asound=libasound2 ;;
    *) asound=libasound2t64 ;;
  esac
  need=(curl tar zstd libvulkan1 mesa-vulkan-drivers vulkan-tools "$asound" libdbus-1-3 libxkbcommon-x11-0 libxcursor1 libxi6 libxrandr2 libx11-xcb1 libwayland-client0 libegl1)
  installed() { dpkg -s "$1" 2>/dev/null | grep -q '^Status: install ok installed'; }
  for p in "${need[@]}"; do
    case "$p" in libasound2*) { installed libasound2 || installed libasound2t64; } && continue ;; esac
    installed "$p" || missing+=("$p")
  done
  if [[ "$vendors" == *0x10de* ]] && ! command -v nvidia-smi >/dev/null; then
    warn "Your NVIDIA card has no NVIDIA driver yet. Open \"Software & Updates\" > \"Additional Drivers\", pick the recommended NVIDIA driver, restart your PC, then run this command again."
  fi
fi
if [ ${#missing[@]} -gt 0 ] && [ -n "${DO27_AUTOUPDATE:-}" ]; then
  warn "Missing packages (${missing[*]}): run the install command in a terminal to add them."
elif [ ${#missing[@]} -gt 0 ]; then
  say "Installing what the game needs: ${missing[*]}"
  say "Your password may be asked for now."
  if [ "$family" = arch ]; then
    sudo pacman -S --needed --noconfirm "${missing[@]}" \
      || die "Couldn't install: ${missing[*]}. Update your system first ($UPDATE_CMD), restart, then run this installer again."
  else
    sudo env DEBIAN_FRONTEND=noninteractive sh -c 'apt-get update -qq && apt-get install -y --no-install-recommends "$@"' sh "${missing[@]}" \
      || die "Couldn't install: ${missing[*]}. Update your system first ($UPDATE_CMD), restart, then run this installer again."
  fi
else
  say "Everything the game needs is already installed."
fi

# 3. Graphics, memory and disk.
# Every Vulkan device as "<type> <name>", discrete cards first.
gpus=$(vulkaninfo --summary 2>/dev/null | awk -F'= ' '/deviceType/ {t=$2} /deviceName/ {print t " " $2}' \
  | sed -E 's/PHYSICAL_DEVICE_TYPE_DISCRETE_GPU/1/; s/PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU/2/; s/PHYSICAL_DEVICE_TYPE_[A-Z_]+/3/' \
  | sort -u | sort -n -k1,1 | cut -d' ' -f2- || true)
real=$(printf '%s\n' "$gpus" | grep -viE 'llvmpipe|lavapipe|swiftshader' | grep . || true)
if [ -z "$real" ]; then
  if [ -n "${DO27_AUTOUPDATE:-}" ]; then
    warn "No Vulkan graphics driver answered."
  else
    if [ "$family" = apt ] && [[ "$vendors" == *0x10de* ]] && ! command -v nvidia-smi >/dev/null; then
      die "No Vulkan graphics driver answered. Install the NVIDIA driver: open \"Software & Updates\" > \"Additional Drivers\", pick the recommended NVIDIA driver, restart your PC, then run this command again."
    fi
    die "No Vulkan graphics driver answered. If you just installed or updated a driver, restart your PC and run this command again."
  fi
else
  say "Graphics: $(printf '%s' "$real" | head -1)"
  if printf '%s\n' "$real" | grep -qiE 'GTX|Quadro [KMP]|RX [45][0-9]{2}([^0-9]|$)|RX 5[0-9]{3}|Vega|Polaris|UHD|Iris'; then
    warn "This graphics card is below the alpha's minimum (RTX 2080 or RX 6000 class). The game may run slowly."
  fi
fi
mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1048576 + 0.5}' /proc/meminfo)
[ "${mem_gb:-0}" -ge 15 ] || warn "This PC has ${mem_gb} GB of memory; the alpha wants 16 GB. Close other programs before playing."
mkdir -p "$DEST" "$BIN" "$APPS"
src=$(findmnt -no SOURCE -T "$DEST" 2>/dev/null | sed 's/\[.*//' || true)
if [ -n "$src" ] && [ "$(lsblk -ndo ROTA "$src" 2>/dev/null | tr -d ' ')" = 1 ]; then
  warn "Your home folder is on a spinning hard disk. The game loads much faster from an SSD."
fi

# Versions compare numerically per field (v0.0.9 < v0.0.10 < v0.1.0), never as strings.
# A tag is v<major>.<minor>.<patch>[-<sha>...].
vnum() { printf '%s' "$1" | sed -E 's/^v//; s/[-+].*$//'; }
# is_newer TAG OLD: TAG has a higher version, or the same version under another tag (a re-publish).
is_newer() {
  local a b; a=$(vnum "$1"); b=$(vnum "$2")
  [ "$1" != "$2" ] || return 1
  [ "$a" = "$b" ] && return 0
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" = "$a" ]
}

# 4. The latest alpha build: a release is a set of chunks (each under GitHub's 2 GiB asset
# limit) listed in manifest-linux.tsv. A fresh install downloads them all; an update downloads
# only the chunks whose checksum changed (usually one small "core" chunk for a patch).
say "Looking for the latest alpha build..."
api=$(curl -fsSL "$API" 2>/dev/null) || api=""
asset_url() { printf '%s' "$api" | grep -oE '"browser_download_url": *"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/' | grep -E "/$1\$" | head -1 || true; }
tag=$(printf '%s' "$api" | grep -oE '"tag_name": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
man_url=$(asset_url 'manifest-linux\.tsv')
sum_url=$(asset_url 'manifest-linux\.json\.sha256')
STATE="$DEST/chunks"   # one <chunk>.tsv per installed chunk: its "chunk" line + its "file" lines
GAME="$DEST/game"
if [ -z "$man_url" ] || [ -z "$tag" ]; then
  if [ -x "$GAME/run.sh" ]; then
    warn "Couldn't check for a new build (offline?). Keeping the one you have."
  else
    warn "No alpha build has been released yet. Your system is ready; run this same command again on test day."
    exit 0
  fi
elif [ -f "$DEST/VERSION" ] && [ "$(cat "$DEST/VERSION")" = "$tag" ] && [ -x "$GAME/run.sh" ] && [ -d "$STATE" ]; then
  say "You already have the latest build ($tag)."
elif [ -n "${DO27_AUTOUPDATE:-}" ] && [ -x "$GAME/run.sh" ] && ! is_newer "$tag" "$(cat "$DEST/VERSION" 2>/dev/null)"; then
  # The automatic update never goes back to an older version (the install line still can).
  say "Keeping $(cat "$DEST/VERSION") (the release is $tag)."
else
  [ -n "$sum_url" ] || die "The release has no checksum file, so the download can't be verified. Please report this."
  dl="$DEST/.download"
  mkdir -p "$dl" "$STATE"
  curl -fsSL -o "$dl/sums" "$sum_url" && curl -fsSL -o "$dl/manifest-linux.tsv" "$man_url" \
    || die "Couldn't download the build's file list. Check your internet connection and run the command again."
  (cd "$dl" && grep ' manifest-linux.tsv$' sums | sha256sum -c --status) \
    || die "The build's file list is damaged (checksum mismatch). Run the command again."
  M="$dl/manifest-linux.tsv"
  # The game needs a current system library (glibc): check before any big download.
  need_glibc=$(awk -F'\t' '$1=="glibc_required" {print $2}' "$M")
  have_glibc=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || true)
  if [ -n "$need_glibc" ] && [ -n "$have_glibc" ] \
     && [ "$(printf '%s\n%s\n' "$need_glibc" "$have_glibc" | sort -V | head -1)" != "$need_glibc" ]; then
    die "Your system is out of date (glibc $have_glibc, this build needs $need_glibc). Update it with: $UPDATE_CMD  then restart your PC and run the install command again."
  fi
  # Which chunks are new or changed (an install without chunk records gets every chunk).
  todo=()
  while IFS=$'\t' read -r kind name asset sum size unpacked; do
    [ "$kind" = chunk ] || continue
    if [ -x "$GAME/run.sh" ] && [ -f "$STATE/$name.tsv" ] \
       && [ "$(head -1 "$STATE/$name.tsv" | cut -f4)" = "$sum" ]; then
      continue
    fi
    todo+=("$name")
  done < "$M"
  dl_bytes=$(awk -F'\t' -v l=" ${todo[*]} " '$1=="chunk" && index(l, " " $2 " ") {s+=$5} END {printf "%.0f\n", s}' "$M")
  un_bytes=$(awk -F'\t' -v l=" ${todo[*]} " '$1=="chunk" && index(l, " " $2 " ") {s+=$6} END {printf "%.0f\n", s}' "$M")
  free_b=$(df -Pk "$DEST" | awk 'NR==2 {printf "%.0f\n", $4 * 1024}')
  # Each part is unpacked and deleted as soon as it is verified: the game + one part + a margin.
  need_b=$(( un_bytes + 3 * 1073741824 ))
  if [ "$free_b" -lt "$need_b" ]; then
    die "Not enough free space in your home folder: $(( free_b / 1073741824 )) GB free, this needs $(( need_b / 1073741824 )) GB. Free some space and run the command again."
  fi
  total=${#todo[@]}
  if [ -d "$STATE" ] && [ "$(ls "$STATE" 2>/dev/null | wc -l)" -gt 0 ] && [ -x "$GAME/run.sh" ]; then
    say "Updating to $tag: $total part(s) changed, $(( (dl_bytes + 524287) / 1048576 )) MB to download."
  else
    say "Downloading $tag: $total parts, $(( (dl_bytes + 536870911) / 1073741824 )) GB (an interrupted download carries on when you run this again)."
  fi
  # Keep only the parts this build still needs in the download folder.
  keep=$(awk -F'\t' '$1=="chunk" {print $4 ".tar.zst"}' "$M")
  for f in "$dl"/*.tar.zst; do
    [ -e "$f" ] || continue
    printf '%s\n' "$keep" | grep -qxF "$(basename "$f")" || rm -f "$f"
  done
  i=0
  for name in "${todo[@]}"; do
    i=$((i + 1))
    IFS=$'\t' read -r _ _ asset sum size _ < <(awk -F'\t' -v n="$name" '$1=="chunk" && $2==n' "$M")
    url=$(asset_url "$(printf '%s' "$asset" | sed 's/[.]/\\./g')")
    [ -n "$url" ] || die "The release is missing the part $asset. Please report this."
    part="$dl/$sum.tar.zst"
    if [ -f "$part" ] && [ "$(stat -c %s "$part")" = "$size" ] && [ "$(sha256sum "$part" | cut -d' ' -f1)" = "$sum" ]; then
      say "Part $i of $total ($asset) is already downloaded."
    else
      say "Part $i of $total: $asset ($(( (size + 1048575) / 1048576 )) MB)"
      rc=0
      curl -fL --progress-bar -C - --retry 3 -o "$part" "$url" || rc=$?
      if [ "$rc" = 33 ] || [ "$rc" = 36 ]; then
        # The server can't resume this file: start it again from the beginning.
        rm -f "$part"; rc=0
        curl -fL --progress-bar --retry 3 -o "$part" "$url" || rc=$?
      fi
      [ "$rc" = 0 ] || die "The download failed. Check your internet connection and run the command again (finished parts are kept)."
      if [ "$(sha256sum "$part" | cut -d' ' -f1)" != "$sum" ]; then
        rm -f "$part"
        die "A downloaded part is damaged (checksum mismatch). Run the command again."
      fi
    fi
    # Install this part now (the installed record is per part, so an interrupted update
    # carries on with the parts still missing).
    mkdir -p "$GAME"
    awk -F'\t' -v n="$name" '($1=="chunk" || $1=="file") && $2==n' "$M" > "$dl/$name.new"
    # Files the old version of this part had and the new one doesn't.
    if [ -f "$STATE/$name.tsv" ]; then
      awk -F'\t' 'NR==FNR {if ($1=="file") keep[$3]=1; next} $1=="file" && !($3 in keep) {print $3}' \
        "$dl/$name.new" "$STATE/$name.tsv" | while IFS= read -r rel; do rm -f -- "$GAME/$rel"; done
    fi
    zstd -dc --long=27 "$part" | tar -C "$GAME" -xf - \
      || die "Couldn't unpack the game. Check the free space in your home folder and run the command again."
    mv -f "$dl/$name.new" "$STATE/$name.tsv"
    rm -f "$part"
  done
  # Parts the new build no longer has, and any file no part owns (older installs).
  for f in "$STATE"/*.tsv; do
    [ -e "$f" ] || continue
    n=$(basename "$f" .tsv)
    awk -F'\t' -v n="$n" '$1=="chunk" && $2==n {found=1} END {exit !found}' "$M" || rm -f "$f"
  done
  # Byte-identical files ship once: recreate the other paths as hard links of the shipped one.
  awk -F'\t' '$1=="link" {print $2 "\t" $3}' "$M" | while IFS=$'\t' read -r rel target; do
    mkdir -p "$(dirname "$GAME/$rel")"
    ln -f "$GAME/$target" "$GAME/$rel" 2>/dev/null || /usr/bin/cp -f "$GAME/$target" "$GAME/$rel"
  done
  awk -F'\t' '$1=="file" {print $3} $1=="link" {print $2}' "$M" | LC_ALL=C sort > "$dl/owned"
  (cd "$GAME" && find . -type f -printf '%P\n' | LC_ALL=C sort) > "$dl/present"
  LC_ALL=C comm -23 "$dl/present" "$dl/owned" | while IFS= read -r rel; do rm -f -- "$GAME/$rel"; done
  find "$GAME" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  [ -x "$GAME/run.sh" ] || die "The build looks incomplete (no run.sh). Please report this."
  /usr/bin/cp -f "$M" "$DEST/manifest-linux.tsv"
  rm -rf "$dl"
  printf '%s\n' "$tag" | put "$DEST/VERSION"
  say "Installed $tag."
fi

# Never report success without a game (on Ubuntu, mawk once printed a byte count as 5.1e+10:
# the arithmetic error skipped the install above without stopping the script; the counts
# now use printf "%.0f").
[ -x "$GAME/run.sh" ] || die "The game isn't installed (the step above failed). Run the install command again; if it fails the same way, post this in the alpha channel."

# 5. A command and an app-menu entry.
put "$BIN/do27" 755 <<EOF
#!/usr/bin/env bash
# Direct Order 27 alpha (written by the installer). Each start checks for a newer
# alpha build and installs it first (a few seconds; skipped when offline).
latest=\$(curl -fsS --max-time 4 "$API" 2>/dev/null | grep -oE '"tag_name": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"\$/\1/' || true)
have=\$(cat "$DEST/VERSION" 2>/dev/null)
# Numeric per field (v0.0.9 < v0.0.10 < v0.1.0); the same version under another tag is a re-publish.
vnum() { printf '%s' "\$1" | sed -E 's/^v//; s/[-+].*\$//'; }
newer=0
if [ -n "\$latest" ] && [ "\$latest" != "\$have" ]; then
  if [ "\$(vnum "\$latest")" = "\$(vnum "\$have")" ] || [ "\$(printf '%s\\n%s\\n' "\$(vnum "\$latest")" "\$(vnum "\$have")" | sort -V | tail -1)" = "\$(vnum "\$latest")" ]; then newer=1; fi
fi
if [ "\$newer" = 1 ]; then
  command -v notify-send >/dev/null && notify-send "Direct Order 27" "Updating to \$latest..." 2>/dev/null || true
  echo "Direct Order 27: updating to \$latest..."
  curl -fsSL "$RAW/install.sh" | DO27_AUTOUPDATE=1 ${MIRROR:+DO27_ALPHA_MIRROR="$MIRROR"} bash 2>&1 | tee -a "$DEST/update.log" || true
fi
cd "$DEST/game" && exec ./run.sh "\$@"
EOF
icon="$DEST/game/icon.png"; [ -f "$icon" ] || icon=applications-games
put "$APPS/do27-alpha.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Direct Order 27 (alpha)
Comment=Hover-tank RTS/FPS alpha test
Exec=$BIN/do27
Icon=$icon
Terminal=false
Categories=Game;
StartupWMClass=com.do27.shell
EOF
command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" >/dev/null 2>&1 || true

# 6. Uninstaller. Your alpha username stays reserved (it can't change during the alpha).
put "$BIN/do27-uninstall" 755 <<EOF
#!/usr/bin/env bash
rm -rf "$DEST" "$APPS/do27-alpha.desktop" "$BIN/do27"
rm -rf "\$HOME/.config/DO27" "\${XDG_CACHE_HOME:-\$HOME/.cache}/do27" "\$HOME/.local/share/DO27"
data="\${XDG_DATA_HOME:-\$HOME/.local/share}/do27"
if [ -d "\$data" ]; then
  find "\$data" -mindepth 1 -maxdepth 1 ! -name profile -exec rm -rf {} +
fi
command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" >/dev/null 2>&1 || true
rm -f "$BIN/do27-uninstall"
echo "Direct Order 27 alpha removed. Your alpha username stays reserved for the rest of the alpha."
EOF

# 7. Preflight: the game's own check of the graphics driver, audio, disk and memory.
if [ -x "$DEST/game/run.sh" ] && [ -z "${DO27_AUTOUPDATE:-}" ]; then
  say "Checking your system for the game..."
  pre=$("$DEST/game/run.sh" preflight 2>&1 || true)
  printf '%s\n' "$pre" | sed 's/^/    /'
  if printf '%s\n' "$pre" | grep -q 'MISSING'; then
    warn "The game will still start; the lines above say what to install for the best result."
  fi
fi

# An auto-update (the do27 command) goes straight on to start the game.
[ -z "${DO27_AUTOUPDATE:-}" ] || exit 0
printf '\n%sDone:%s open %sDirect Order 27 (alpha)%s from your app menu, or type %sdo27%s in a terminal.\n' "$B$G" "$N" "$B" "$N" "$B" "$N"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) printf 'To use the do27 command, open a new terminal first. If it still is not found, run %sfish_add_path ~/.local/bin%s (fish) or add ~/.local/bin to your PATH (bash).\n' "$B" "$N" ;;
esac
printf 'The first time it starts, the game asks you to choose your alpha username.\n'
printf 'It updates itself each time you start it. To remove it: do27-uninstall\n\n'
