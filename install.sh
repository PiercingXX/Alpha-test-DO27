#!/usr/bin/env bash
# Direct Order 27 alpha installer.
# Arch Linux, CachyOS, Ubuntu 22.04+, Debian 12+. Install or update:  curl -fsSL https://raw.githubusercontent.com/PiercingXX/Alpha-test-DO27/main/install.sh | bash
# Running it again updates the game. Nothing here needs editing.
set -euo pipefail

REPO="PiercingXX/Alpha-test-DO27"
# Release-test hooks (not for testers): another repository, a pinned release tag, and a
# token for a private test repository (never printed, never written to disk).
REPO_OVERRIDE="${DO27_REPO_OVERRIDE:-}"
if [ -n "$REPO_OVERRIDE" ]; then
  [[ "$REPO_OVERRIDE" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "DO27_REPO_OVERRIDE must be owner/name." >&2; exit 1; }
  REPO=$REPO_OVERRIDE
fi
TOKEN="${DO27_GH_TOKEN:-}"
API="https://api.github.com/repos/$REPO/releases/latest"
LIST="https://api.github.com/repos/$REPO/releases?per_page=100"
RAW="https://raw.githubusercontent.com/$REPO/main"
# Release-test hook: a local copy of the release (latest.json in the GitHub API
# shape, install.sh and the assets; optionally releases.json, the release list)
# served over HTTP on the LAN.
MIRROR="${DO27_ALPHA_MIRROR:-}"
if [ -n "$MIRROR" ]; then API="$MIRROR/latest.json"; LIST="$MIRROR/releases.json"; RAW="$MIRROR"; fi
# The release this run installs: the latest one (DO27_PIN_TAG picks another, for tests).
REL_API=$API
if [ -n "${DO27_PIN_TAG:-}" ] && [ -z "$MIRROR" ]; then
  [[ "$DO27_PIN_TAG" =~ ^[A-Za-z0-9_.+-]+$ ]] || { echo "DO27_PIN_TAG is not a tag." >&2; exit 1; }
  REL_API="https://api.github.com/repos/$REPO/releases/tags/$DO27_PIN_TAG"
fi
# With a token: API calls authenticate, and assets download through their API url
# (curl drops the header on the redirect to the download host).
api_hdr=(); dl_hdr=()
if [ -n "$TOKEN" ]; then
  api_hdr=(-H "Authorization: Bearer $TOKEN")
  dl_hdr=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/octet-stream")
fi

DEST="$HOME/.local/share/do27-alpha"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B= G= Y= R= N=; fi
say()  { printf '%s==>%s %s\n' "$B$G" "$N" "$*"; }
warn() { printf '%s!!%s  %s\n' "$B$Y" "$N" "$*"; }
# Replace a file with a new inode, so a script that is running from it (the
# do27 launcher during an auto-update) keeps reading its old copy.
put() { local tmp; tmp=$(mktemp "$1.XXXXXX"); cat > "$tmp"; chmod "${2:-644}" "$tmp"; mv -f "$tmp" "$1"; }

# ---- Update progress, lock and exit codes -------------------------------------------------
# AUTO is set by the do27 command (every start): the update runs without a terminal when the
# game is opened from the app menu, so it shows its progress in a window or notifications and
# the command starts the game when this script ends. Exit codes in that mode: 0 done (or
# nothing to do), 1 failed (the command still starts the installed game), 75 another update
# is running (the command starts nothing).
AUTO="${DO27_AUTOUPDATE:-}"
mkdir -p "$DEST"
PROGRESS_FILE="$DEST/update.progress"   # "part 6 of 14" while an update runs (the lock message reads it)
ui=text; ui_fd=; ui_pid=; ui_ref=; ui_last=0; ui_fail_shown=; have_lock=
if [ -n "$AUTO" ]; then
  case "${DO27_UI:-}" in
    text|zenity|kdialog|notify|none) ui=$DO27_UI ;;
    *)
      # With a terminal (the do27 command typed in one) the text below is the display.
      if ! { : </dev/tty; } 2>/dev/null; then
        ui=none
        if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
          if command -v zenity >/dev/null; then ui=zenity
          elif command -v kdialog >/dev/null && { command -v qdbus >/dev/null || command -v qdbus6 >/dev/null || command -v qdbus-qt5 >/dev/null; }; then ui=kdialog
          elif command -v notify-send >/dev/null; then ui=notify; fi
        elif command -v notify-send >/dev/null; then ui=notify; fi
      fi ;;
  esac
fi
# Every write goes through a subshell: a window the player closed must never end the update.
ui_send() { [ -n "$ui_fd" ] || return 0; ( printf '%s\n' "$@" >&8 ) 2>/dev/null || true; }
ui_notify() { command -v notify-send >/dev/null && notify-send -a "Direct Order 27" -h string:x-canonical-private-synchronous:do27-update "Direct Order 27" "$1" 2>/dev/null || true; }
qd() { local q; for q in qdbus qdbus6 qdbus-qt5; do command -v "$q" >/dev/null && { "$q" "$@" 2>/dev/null || true; return; }; done; }
ui_open() {
  case "$ui" in
    zenity)
      ui_fifo="$DEST/.ui.fifo.$$"; rm -f "$ui_fifo"; mkfifo "$ui_fifo" 2>/dev/null || { ui=notify; return 0; }
      zenity --progress --no-cancel --title="Direct Order 27" --text="$1" --percentage=0 --width=460 <"$ui_fifo" >/dev/null 2>&1 9>&- &
      ui_pid=$!
      exec 8>"$ui_fifo"; ui_fd=8; rm -f "$ui_fifo" ;;
    kdialog) ui_ref=$(kdialog --title "Direct Order 27" --progressbar "$1" 100 2>/dev/null 9>&- || true) ;;
    notify) ui_notify "$1" ;;
  esac
}
# ui_set PERCENT TEXT (PERCENT -1: unchanged)
ui_set() {
  local now=$SECONDS
  case "$ui" in
    zenity) [ "$1" -lt 0 ] || ui_send "$1"; ui_send "# $2" ;;
    kdialog) [ -z "$ui_ref" ] || { [ "$1" -lt 0 ] || qd $ui_ref Set "" value "$1"; qd $ui_ref setLabelText "$2"; } ;;
    notify) [ $((now - ui_last)) -ge 5 ] || [ "${3:-}" = now ] || return 0; ui_last=$now; ui_notify "$2" ;;
  esac
}
ui_close() {
  case "$ui" in
    zenity) [ -z "$ui_fd" ] || { ui_send 100; exec 8>&-; ui_fd=; }
            [ -z "$ui_pid" ] || { kill "$ui_pid" 2>/dev/null || true; ui_pid=; } ;;
    kdialog) [ -z "$ui_ref" ] || { qd $ui_ref close; ui_ref=; } ;;
  esac
}
# A message that stays until the player closes it (a failure), apart from the progress window.
ui_alert() {
  case "$ui" in
    zenity) ui_close; zenity --warning --no-wrap --title="Direct Order 27" --text="$1" >/dev/null 2>&1 9>&- & ;;
    kdialog) ui_close; kdialog --title "Direct Order 27" --sorry "$1" >/dev/null 2>&1 9>&- & ;;
    notify) command -v notify-send >/dev/null && notify-send -u critical -a "Direct Order 27" -h string:x-canonical-private-synchronous:do27-update "Direct Order 27" "$1" 2>/dev/null || true ;;
  esac
}
fmt_bytes() { awk -v b="$1" 'BEGIN {if (b >= 1073741824) printf "%.1f GB", b / 1073741824; else printf "%d MB", b / 1048576 + 0.5}'; }
fmt_eta() { awk -v s="$1" 'BEGIN {if (s < 90) printf "under a minute"; else printf "about %d min", (s + 59) / 60}'; }
mixed_msg() { echo "The update to $(head -1 "$DEST/update.mixed" 2>/dev/null) did not finish. Start Direct Order 27 again to continue it (it picks up where it stopped)."; }
die() {
  printf '%sXX%s  %s\n' "$B$R" "$N" "$*"; printf '    Need help? Post this message in the alpha channel on Discord.\n'
  if [ -n "$AUTO" ]; then
    ui_fail_shown=1
    if [ -f "$DEST/update.mixed" ]; then ui_alert "$(mixed_msg)"
    elif [ -x "$DEST/game/run.sh" ]; then ui_alert "The update failed: $* Starting the version you already have."
    else ui_alert "The install failed: $*"; fi
  fi
  exit 1
}
cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ -n "$AUTO" ] && [ -z "$ui_fail_shown" ] && [ "$rc" -ne 75 ]; then
    ui_fail_shown=1
    printf '!!  The update stopped before it finished (a finished part is kept; the next start carries on).\n'
    if [ -f "$DEST/update.mixed" ]; then ui_alert "$(mixed_msg)"
    else ui_alert "The update stopped before it finished. Starting the version you already have; the next start carries on."; fi

  fi
  # An older do27 command would start the half-updated game when this script ends: stop it.
  if [ "$rc" -ne 0 ] && [ -n "$AUTO" ] && [ -f "$DEST/update.mixed" ] && [ -z "${DO27_WRAPPER:-}" ] \
     && tr '\0' ' ' < "/proc/$PPID/cmdline" 2>/dev/null | grep -qE '(^|[ /])do27 '; then
    kill "$PPID" 2>/dev/null || true
  fi
  ui_close
  [ -z "$have_lock" ] || rm -f "$PROGRESS_FILE"
  rm -f "$DEST"/.ui.fifo.* 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 143' HUP INT TERM

printf '\n%sDirect Order 27: alpha installer%s\n\n' "$B" "$N"

# One update at a time. The do27 command holds the lock itself (DO27_LOCK_HELD) and starts this
# script as its child; any other run (the install line in a terminal, or an older do27 command
# that doesn't know about the lock) takes it here, or says an update is already running.
if [ -z "${DO27_LOCK_HELD:-}" ] && command -v flock >/dev/null; then
  exec 9>"$DEST/update.lock"
  if flock -n 9; then
    have_lock=1
  else
    prog=$(cat "$PROGRESS_FILE" 2>/dev/null || true)
    txt="Already updating${prog:+ ($prog)}. Direct Order 27 starts when the update is done."
    say "$txt"
    if [ -n "$AUTO" ]; then
      ui_open "$txt"; ui_set -1 "$txt" now; sleep 1
      # An older do27 command goes on to start the game when this script ends: stop it, so a
      # second click starts neither a second download nor a second game.
      if [ -z "${DO27_WRAPPER:-}" ] && tr '\0' ' ' < "/proc/$PPID/cmdline" 2>/dev/null | grep -qE '(^|[ /])do27 '; then
        kill "$PPID" 2>/dev/null || true
      fi
    fi
    exit 75
  fi
else
  have_lock=1
fi

# 1. The system: Arch/CachyOS (pacman), or Ubuntu 22.04+ / Debian 12+ and their family (apt).
[ "$(id -u)" -ne 0 ] || die "Don't run this as root. Run it as your normal user (it asks for your password once if it needs to)."
. /etc/os-release 2>/dev/null || true
case " ${ID:-} ${ID_LIKE:-} " in
  *" arch "*|*" cachyos "*) family=arch; UPDATE_CMD="sudo pacman -Syu" ;;
  *" ubuntu "*|*" debian "*) family=apt; UPDATE_CMD="sudo apt update && sudo apt full-upgrade" ;;
  *) die "This alpha runs on Arch Linux, CachyOS, Ubuntu (22.04 or newer) or Debian (12 or newer) only. Your system is: ${PRETTY_NAME:-unknown}." ;;
esac
# Debian itself (not Ubuntu or a derivative that says ID_LIKE=debian): its NVIDIA driver and sudo setup differ.
is_debian=0; [ "${ID:-}" = debian ] && is_debian=1
say "System: ${PRETTY_NAME:-$ID}"
[ "$(uname -m)" = x86_64 ] || die "This alpha needs a 64-bit PC (x86_64)."
if [ "$family" = arch ]; then
  command -v pacman >/dev/null || die "pacman not found. This alpha needs Arch Linux, CachyOS, Ubuntu or Debian."
else
  command -v apt-get >/dev/null && command -v dpkg >/dev/null || die "apt-get not found. This alpha needs Arch Linux, CachyOS, Ubuntu or Debian."
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
  die "Your system is too old (glibc $have_glibc, the game needs $MIN_GLIBC or newer). This alpha needs Ubuntu 22.04 or newer, or Debian 12 or newer."
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
    if [ "$is_debian" = 1 ]; then
      warn "Your NVIDIA card has no NVIDIA driver yet. Enable the contrib and non-free sources, install it with: sudo apt install nvidia-driver firmware-misc-nonfree  (guide: https://wiki.debian.org/NvidiaGraphicsDrivers), restart your PC, then run this command again."
    else
      warn "Your NVIDIA card has no NVIDIA driver yet. Open \"Software & Updates\" > \"Additional Drivers\", pick the recommended NVIDIA driver, restart your PC, then run this command again."
    fi
  fi
fi
if [ ${#missing[@]} -gt 0 ] && [ -n "${DO27_AUTOUPDATE:-}" ]; then
  warn "Missing packages (${missing[*]}): run the install command in a terminal to add them."
elif [ ${#missing[@]} -gt 0 ]; then
  say "Installing what the game needs: ${missing[*]}"
  # Debian installed with a root password leaves the user out of sudo: say what to run instead.
  if [ "$is_debian" = 1 ] && { ! command -v sudo >/dev/null || ! id -nG | tr ' ' '\n' | grep -qxE 'sudo|admin|wheel'; } && ! sudo -n true 2>/dev/null; then
    die "Your account can't use sudo, so the installer can't add: ${missing[*]}. Install them as root with: su -c \"apt-get update && apt-get install -y ${missing[*]}\"  then run the install command again."
  fi
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
      [ "$is_debian" = 1 ] && die "No Vulkan graphics driver answered. Install the NVIDIA driver: enable the contrib and non-free sources, then sudo apt install nvidia-driver firmware-misc-nonfree  (guide: https://wiki.debian.org/NvidiaGraphicsDrivers), restart your PC, then run this command again."
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

# Which data package fits this PC. Every build comes in three packages with the same game and
# different texture detail; video memory picks one, never the card's maker or model:
#   LOW   8 GB of video memory or less, or graphics built into the CPU (they share system memory)
#   HIGH  10 to 16 GB
#   ULTRA 20 GB or more
# The game's own quality setting (how fast it runs) is separate and stays automatic; the package
# only decides which textures are on disk. DO27_TIER=low|high|ultra overrides the choice, and an
# update keeps the package you installed.
# Every Vulkan device: "<type>\t<largest device-local heap in bytes>\t<name>".
vk_heaps=$(vulkaninfo 2>/dev/null | awk '
  /^GPU[0-9]+:/ {dev=$1; sz=0}
  /^\tdeviceType *=/ && !(dev in typ) {typ[dev]=$NF}
  /^\tdeviceName *=/ && !(dev in nam) {v=$0; sub(/^[^=]*= */, "", v); nam[dev]=v}
  /^\tmemoryHeaps\[[0-9]+\]:/ {sz=0}
  /^\t\tsize *=/ {sz=$3}
  /MEMORY_HEAP_DEVICE_LOCAL_BIT/ && dev != "" {if (sz+0 > best[dev]+0) best[dev]=sz}
  END {for (d in typ) printf "%s\t%.0f\t%s\n", typ[d], best[d]+0, nam[d]}' || true)
# The game runs on the strongest card: the separate (discrete) card with the most video memory.
gpu_pick=$(printf '%s\n' "$vk_heaps" | awk -F'\t' '$1 ~ /DISCRETE/' | sort -t$'\t' -k2,2nr | head -1)
if [ -z "$gpu_pick" ] && command -v nvidia-smi >/dev/null; then
  gpu_pick=$(nvidia-smi --query-gpu=memory.total,name --format=csv,noheader,nounits 2>/dev/null \
    | awk -F', ' '{printf "DISCRETE\t%.0f\t%s\n", $1 * 1048576, $2}' | sort -t$'\t' -k2,2nr | head -1 || true)
fi
if [ -n "$gpu_pick" ]; then
  gpu_name=$(printf '%s' "$gpu_pick" | cut -f3)
  vram_b=$(printf '%s' "$gpu_pick" | cut -f2)
  vram_gb=$(awk -v b="$vram_b" 'BEGIN {printf "%d", b / 1073741824 + 0.5}')
  if [ "$vram_gb" -ge 20 ]; then auto_tier=ultra; elif [ "$vram_gb" -ge 10 ]; then auto_tier=high; else auto_tier=low; fi
  gpu_desc="$gpu_name, $vram_gb GB video memory"
else
  gpu_name=$(printf '%s\n' "$vk_heaps" | awk -F'\t' '$1 ~ /INTEGRATED/ {print $3; exit}')
  auto_tier=low
  gpu_desc="${gpu_name:-graphics built into the CPU}, shared memory"
fi
# Less than 12 GB of system memory can't hold the bigger packages' textures beside the game.
[ "${mem_gb:-0}" -ge 12 ] || auto_tier=low
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
prepared=0   # 1 once a fresh install or update has just been written
say "Looking for the latest alpha build..."
api=$(curl -fsSL ${api_hdr[@]+"${api_hdr[@]}"} "$REL_API" 2>/dev/null) || api=""
tag=$(printf '%s' "$api" | grep -oE '"tag_name": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
# >>> release lookup
# A release carries only the parts that changed since the one before it: an unchanged part
# stays an asset of the older release that first shipped it. Every asset of the GitHub
# release JSON (one release or a list) as one line:
#   <release no.> <tag> <draft> <prerelease> <name> <digest> <api url> <download url>
# A small JSON reader (grep splits the tokens, awk follows the nesting), so the asset's own
# "url" is never confused with its uploader's.
json_assets() {
  LC_ALL=C grep -oE '"([^"\\]|\\.)*"|[][{}:,]|true|false|null' | LC_ALL=C awk '
    { t = $0 }
    t == "{" || t == "[" {
      d++; typ[d] = t; key[d] = ""
      if (t == "{" && !rel && (d == 1 || (d == 2 && typ[1] == "["))) { rel = d; nrel++; tag = ""; dr = "false"; pr = "false"; na = 0 }
      else if (t == "{" && rel && d == rel + 2 && typ[rel + 1] == "[" && key[rel] == "assets") { ast = d; an = ""; ad = ""; au = ""; ab = "" }
      prev = t; next
    }
    t == "}" || t == "]" {
      if (t == "}" && ast && d == ast) { A[++na] = an "\t" ad "\t" au "\t" ab; ast = 0 }
      else if (t == "}" && rel && d == rel) { for (i = 1; i <= na; i++) print nrel "\t" tag "\t" dr "\t" pr "\t" A[i]; rel = 0 }
      d--; prev = t; next
    }
    t == ":" || t == "," { prev = t; next }
    {
      v = t; if (substr(v, 1, 1) == "\"") v = substr(v, 2, length(v) - 2)
      if (prev == ":") {
        k = key[d]
        if (rel && d == rel) { if (k == "tag_name") tag = v; else if (k == "draft") dr = v; else if (k == "prerelease") pr = v }
        else if (ast && d == ast) { if (k == "name") an = v; else if (k == "digest") ad = v; else if (k == "url") au = v; else if (k == "browser_download_url") ab = v }
      } else if (typ[d] == "{") key[d] = v
      prev = t
    }' || true
}
# The assets to search, best first: the release being installed, then every other published
# release, newest version first. Each line: <name> <digest> <api url> <download url>.
list=""
if [ -n "$api" ]; then list=$(curl -fsSL ${api_hdr[@]+"${api_hdr[@]}"} "$LIST" 2>/dev/null) || list=""; fi
ASSETS=$( {
  printf '%s\n' "$api" | json_assets | awk -F'\t' '{print "0\t0\t" $0}' || true
  printf '%s\n' "$list" | json_assets | awk -F'\t' '$3 != "true" && $4 != "true" {v = $2; sub(/^v/, "", v); sub(/[-+].*$/, "", v); print "1\t" v "\t" $0}' || true
} | LC_ALL=C sort -s -t$'\t' -k1,1n -k2,2Vr -k3,3n | cut -f7-10 || true)
URL_FIELD=4; [ -z "$TOKEN" ] || URL_FIELD=3
# part_url NAME [SHA256]: the newest release whose asset NAME has that checksum (GitHub's
# "digest"), else the newest one with an asset NAME (the checksum check after the download
# still stops a wrong file).
part_url() {
  printf '%s\n' "$ASSETS" | awk -F'\t' -v n="$1" -v s="${2:+sha256:$2}" -v f="$URL_FIELD" '
    $1 == n && s != "" && $2 == s {print $f; hit = 1; exit}
    $1 == n && first == "" {first = $f}
    END {if (!hit && first != "") print first}' || true
}
# latest_url NAME: an asset of the release being installed only (its manifests and checksums).
latest_url() { printf '%s\n' "$api" | json_assets | awk -F'\t' -v n="$1" -v f="$((URL_FIELD + 4))" '$5 == n {print $f; exit}' || true; }
# <<< release lookup
STATE="$DEST/chunks"   # one <chunk>.tsv per installed chunk: its "chunk" line + its "file" lines
GAME="$DEST/game"
# The package: DO27_TIER, else the one installed (an update keeps it), else this PC's fit.
have_tier=$(cat "$DEST/TIER" 2>/dev/null || true)
if [ -n "${DO27_TIER:-}" ]; then
  case "$DO27_TIER" in low|high|ultra) tier=$DO27_TIER ;; *) die "DO27_TIER must be low, high or ultra (it is \"$DO27_TIER\")." ;; esac
elif [ -n "$have_tier" ] && [ -x "$GAME/run.sh" ]; then
  tier=$have_tier
else
  tier=$auto_tier
fi
TIER_UP=$(printf '%s' "$tier" | tr '[:lower:]' '[:upper:]')
man_name="manifest-linux-$tier"
man_url=$(latest_url "manifest-linux-$tier.tsv")
sum_url=$(latest_url "manifest-linux-$tier.json.sha256")
if [ -z "$man_url" ]; then
  # A release from before the hardware packages: one package for every PC.
  man_name="manifest-linux"
  man_url=$(latest_url manifest-linux.tsv)
  sum_url=$(latest_url manifest-linux.json.sha256)
  tier=""
fi
if [ -z "$man_url" ] || [ -z "$tag" ]; then
  if [ -x "$GAME/run.sh" ]; then
    warn "Couldn't check for a new build (offline?). Keeping the one you have."
  else
    warn "No alpha build has been released yet. Your system is ready; run this same command again on test day."
    exit 0
  fi
elif [ -f "$DEST/VERSION" ] && [ "$(cat "$DEST/VERSION")" = "$tag" ] && [ -x "$GAME/run.sh" ] && [ -d "$STATE" ] \
     && [ "$have_tier" = "$tier" ]; then
  say "You already have the latest build ($tag${tier:+, $TIER_UP package})."
  [ -z "$tier" ] || say "Your PC: $gpu_desc -> the ${auto_tier^^} package fits it best."
elif [ -n "${DO27_AUTOUPDATE:-}" ] && [ -x "$GAME/run.sh" ] && ! is_newer "$tag" "$(cat "$DEST/VERSION" 2>/dev/null)"; then
  # The automatic update never goes back to an older version (the install line still can).
  say "Keeping $(cat "$DEST/VERSION") (the release is $tag)."
else
  [ -n "$sum_url" ] || die "The release has no checksum file, so the download can't be verified. Please report this."
  dl="$DEST/.download"
  mkdir -p "$dl" "$STATE"
  curl -fsSL ${dl_hdr[@]+"${dl_hdr[@]}"} -o "$dl/sums" "$sum_url" && curl -fsSL ${dl_hdr[@]+"${dl_hdr[@]}"} -o "$dl/$man_name.tsv" "$man_url" \
    || die "Couldn't download the build's file list. Check your internet connection and run the command again."
  (cd "$dl" && grep " $man_name.tsv\$" sums | sha256sum -c --status) \
    || die "The build's file list is damaged (checksum mismatch). Run the command again."
  M="$dl/$man_name.tsv"
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
  if [ -n "$tier" ]; then
    all_dl=$(awk -F'\t' '$1=="chunk" {s+=$5} END {printf "%.0f\n", s}' "$M")
    all_un=$(awk -F'\t' '$1=="chunk" {s+=$6} END {printf "%.0f\n", s}' "$M")
    say "Your PC: $gpu_desc -> $TIER_UP package, $(( (all_dl + 536870911) / 1073741824 )) GB download ($(( (all_un + 536870911) / 1073741824 )) GB installed)."
    [ "$tier" = "$auto_tier" ] || say "(Chosen with DO27_TIER or kept from your install; this PC fits the ${auto_tier^^} package.)"
  fi
  if [ "$free_b" -lt "$need_b" ]; then
    smaller=""; [ "$tier" = ultra ] && smaller=high; [ "$tier" = high ] && smaller=low
    die "Not enough free space in your home folder: $(( free_b / 1073741824 )) GB free, this needs $(( need_b / 1073741824 )) GB. Free some space and run the command again.${smaller:+ Or install the smaller ${smaller^^} package: curl -fsSL $RAW/install.sh | env DO27_TIER=$smaller bash}"
  fi
  total=${#todo[@]}
  # An update that was stopped carries on: the parts already installed are not in "todo", so the
  # numbering and the byte counts come from the plan written when this version was first started.
  grand_total=$total; grand_bytes=$dl_bytes; base_n=0; base_bytes=0
  if [ -f "$dl/plan" ] && [ "$(cut -f1 "$dl/plan")" = "$tag" ]; then
    p_total=$(cut -f2 "$dl/plan"); p_bytes=$(cut -f3 "$dl/plan")
    if [ "${p_total:-0}" -ge "$total" ] && [ "${p_bytes:-0}" -ge "$dl_bytes" ]; then
      grand_total=$p_total; grand_bytes=$p_bytes; base_n=$((p_total - total)); base_bytes=$((p_bytes - dl_bytes))
    fi
  fi
  printf '%s\t%s\t%s\n' "$tag" "$grand_total" "$grand_bytes" > "$dl/plan"
  if [ -d "$STATE" ] && [ "$(ls "$STATE" 2>/dev/null | wc -l)" -gt 0 ] && [ -x "$GAME/run.sh" ]; then
    say "Updating to $tag: $grand_total part(s) changed, $(( (grand_bytes + 524287) / 1048576 )) MB to download."
  else
    say "Downloading $tag: $grand_total parts, $(( (grand_bytes + 536870911) / 1073741824 )) GB (an interrupted download carries on when you run this again)."
  fi
  [ "$base_n" -eq 0 ] || [ ! -f "$DEST/VERSION" ] || printf '%s\n' "$tag" > "$DEST/update.mixed"   # parts of two versions on disk (also an older installer's half update)
  [ "$base_n" -eq 0 ] || say "Carrying on: $base_n part(s) are already installed, $total to go."
  ui_open "Updating to $tag: $grand_total parts, $(fmt_bytes "$grand_bytes")"
  ui_set 0 "Updating to $tag: part $((base_n + 1)) of $grand_total, $(fmt_bytes "$grand_bytes") in all" now
  # Keep only the parts this build still needs in the download folder.
  keep=$(awk -F'\t' '$1=="chunk" {print $4 ".tar.zst"}' "$M")
  for f in "$dl"/*.tar.zst; do
    [ -e "$f" ] || continue
    printf '%s\n' "$keep" | grep -qxF "$(basename "$f")" || rm -f "$f"
  done
  i=0
  done_bytes=$base_bytes   # bytes of the whole update that are on disk
  fetched=0; t_start=$SECONDS   # bytes fetched by this run, for the time estimate
  # progress_line PART_BYTES_SO_FAR WHAT: the window / notification text and the lock message.
  progress_line() {
    local cur=$(( done_bytes + $1 )) pct eta=""
    pct=$(( grand_bytes > 0 ? cur * 100 / grand_bytes : 0 )); [ "$pct" -le 100 ] || pct=100
    if [ $((SECONDS - t_start)) -ge 6 ] && [ "$fetched_now" -gt 0 ]; then
      eta=", $(fmt_eta $(( (grand_bytes - cur) * (SECONDS - t_start) / (fetched + fetched_now) )))"
    fi
    ui_set "$pct" "Updating to $tag: part $part_no of $grand_total, $2 ($(fmt_bytes "$cur") of $(fmt_bytes "$grand_bytes")$eta)"
  }
  fetched_now=0
  for name in "${todo[@]}"; do
    i=$((i + 1)); part_no=$((base_n + i))
    printf 'part %s of %s\n' "$part_no" "$grand_total" > "$PROGRESS_FILE"
    IFS=$'\t' read -r _ _ asset sum size _ < <(awk -F'\t' -v n="$name" '$1=="chunk" && $2==n' "$M")
    url=$(part_url "$asset" "$sum")
    [ -n "$url" ] || die "No release has the part $asset. Please report this."
    part="$dl/$sum.tar.zst"
    # A part file bigger than it should be is damaged: start it again.
    [ ! -f "$part" ] || [ "$(stat -c %s "$part")" -le "$size" ] || rm -f "$part"
    if [ -f "$part" ] && [ "$(stat -c %s "$part")" = "$size" ] && [ "$(sha256sum "$part" | cut -d' ' -f1)" = "$sum" ]; then
      say "Part $part_no of $grand_total ($asset) is already downloaded."
    else
      say "Part $part_no of $grand_total: $asset ($(( (size + 1048575) / 1048576 )) MB)"
      start_size=0; [ ! -f "$part" ] || start_size=$(stat -c %s "$part")
      rc=0
      for attempt in 1 2; do
        if [ "$ui" = text ]; then
          # A terminal (or an older command that pipes this script's text): curl's own bar.
          curl -fL ${dl_hdr[@]+"${dl_hdr[@]}"} --progress-bar -C - --retry 3 -o "$part" "$url" || rc=$?
        else
          # No terminal (the app menu): download in the background and report as it grows.
          curl -fsSL ${dl_hdr[@]+"${dl_hdr[@]}"} -C - --retry 3 -o "$part" "$url" &
          cpid=$!; last_log=-1
          while kill -0 "$cpid" 2>/dev/null; do
            sleep 1
            cur=$(stat -c %s "$part" 2>/dev/null || echo 0)
            fetched_now=$(( cur - start_size )); [ "$fetched_now" -ge 0 ] || fetched_now=0
            progress_line "$cur" "downloading"
            tenth=$(( size > 0 ? cur * 10 / size : 0 ))
            if [ "$tenth" -ne "$last_log" ]; then last_log=$tenth; echo "    ${tenth}0% of part $part_no"; fi
          done
          wait "$cpid" && rc=0 || rc=$?
        fi
        if [ "$rc" = 33 ] || [ "$rc" = 36 ] && [ "$attempt" = 1 ]; then
          # The server can't resume this file: start it again from the beginning.
          rm -f "$part"; start_size=0; rc=0
          continue
        fi
        break
      done
      [ "$rc" = 0 ] || die "The download failed. Check your internet connection and start the game again (finished parts are kept and the update carries on)."
      if [ "$(sha256sum "$part" | cut -d' ' -f1)" != "$sum" ]; then
        rm -f "$part"
        die "A downloaded part is damaged (checksum mismatch). Start the game again."
      fi
      fetched=$(( fetched + $(stat -c %s "$part") - start_size )); fetched_now=0
    fi
    progress_line "$size" "unpacking"
    # Install this part now (the installed record is per part, so an interrupted update
    # carries on with the parts still missing).
    mkdir -p "$GAME"
    # From the first replaced part until VERSION is written the install holds parts of two builds.
    [ ! -x "$GAME/run.sh" ] || printf '%s\n' "$tag" > "$DEST/update.mixed"
    awk -F'\t' -v n="$name" '($1=="chunk" || $1=="file") && $2==n' "$M" > "$dl/$name.new"
    # Files the old version of this part had and the new one doesn't.
    if [ -f "$STATE/$name.tsv" ]; then
      awk -F'\t' 'NR==FNR {if ($1=="file") keep[$3]=1; next} $1=="file" && !($3 in keep) {print $3}' \
        "$dl/$name.new" "$STATE/$name.tsv" | while IFS= read -r rel; do rm -f -- "$GAME/$rel"; done
    fi
    zstd -dc --long=27 "$part" | tar -C "$GAME" -xf - \
      || die "Couldn't unpack the game. Check the free space in your home folder and start the game again."
    mv -f "$dl/$name.new" "$STATE/$name.tsv"
    rm -f "$part"
    done_bytes=$(( done_bytes + size ))
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
  rm -f "$DEST/update.mixed"
  if [ -n "$tier" ]; then printf '%s\n' "$tier" | put "$DEST/TIER"; else rm -f "$DEST/TIER"; fi
  say "Installed $tag${tier:+ ($TIER_UP package)}."
  prepared=1
fi

# Never report success without a game (on Ubuntu, mawk once printed a byte count as 5.1e+10:
# the arithmetic error skipped the install above without stopping the script; the counts
# now use printf "%.0f").
[ -x "$GAME/run.sh" ] || die "The game isn't installed (the step above failed). Run the install command again; if it fails the same way, post this in the alpha channel."

# The alpha license travels with the build: a release asset, kept next to the game. A release
# without it still installs (a warning only). Fetched after an install or update, or when missing.
lic_url=$(part_url LICENSE-ALPHA.txt)
if [ -n "$lic_url" ] && { [ "$prepared" = 1 ] || [ ! -f "$DEST/LICENSE-ALPHA.txt" ]; }; then
  lic_tmp=$(mktemp "$DEST/.license.XXXXXX")
  if curl -fsSL ${dl_hdr[@]+"${dl_hdr[@]}"} -o "$lic_tmp" "$lic_url" && [ -s "$lic_tmp" ]; then
    chmod 644 "$lic_tmp"; mv -f "$lic_tmp" "$DEST/LICENSE-ALPHA.txt"
  else
    rm -f "$lic_tmp"; warn "Couldn't download LICENSE-ALPHA.txt. The game still installs; the license is on the release page."
  fi
elif [ -z "$lic_url" ] && [ "$prepared" = 1 ]; then
  warn "This release has no LICENSE-ALPHA.txt. The game still installs."
fi

# 5. First-launch preparation (--prepare): verify the shipped cook cache covers
# both alpha maps and cook any miss, headless, so the first match never waits on
# texture cooking. Runs after a fresh install and after every update (the GPU
# pipeline warm is Ferrite's half; this is the DO27 CPU half). A warning here
# never blocks the game: a miss just means this run takes a little longer and
# the first launch still works.
if [ "$prepared" = 1 ] && [ -z "${DO27_SKIP_PREPARE:-}" ]; then
  say "Preparing the game for this PC (one-time, after install/update)..."
  echo 'preparing the game' > "$PROGRESS_FILE"
  ui_set 100 "Update installed. Preparing the game for this PC (one-time, a few minutes)..." now
  prep_log="$DEST/prepare.log"
  : >"$prep_log"
  (cd "$GAME" && exec ./do27_launcher --prepare) >"$prep_log" 2>&1 &
  prep_pid=$!
  prep_start=$SECONDS; prep_shown=-1; prep_beat=$SECONDS; prep_total=0
  while kill -0 "$prep_pid" 2>/dev/null; do
    sleep 1
    prog=$(grep -F '{"event":"progress"' "$prep_log" 2>/dev/null | tail -1 || true)
    prep_done=$(printf '%s' "$prog" | sed -nE 's/.*"done":([0-9]+).*/\1/p')
    t=$(printf '%s' "$prog" | sed -nE 's/.*"total":([0-9]+).*/\1/p')
    [ -n "$t" ] && prep_total=$t
    secs=$((SECONDS - prep_start))
    if [ -n "$prep_done" ] && [ "$prep_done" -gt "$prep_shown" ] && [ "$prep_total" -gt 0 ]; then
      prep_shown=$prep_done; prep_beat=$SECONDS
      if [ "$prep_done" -ge 1 ] && [ "$prep_done" -lt "$prep_total" ]; then
        # The steps differ in length: a rough estimate, rounded up to 5 s.
        left=$(( ((secs * (prep_total - prep_done) / prep_done) + 4) / 5 * 5 ))
        echo "    step $prep_done of $prep_total done, $secs s so far, about $left s left"
        ui_set 100 "Preparing the game for this PC: step $prep_done of $prep_total done, about $left s left" now
      else
        echo "    step $prep_done of $prep_total done, $secs s so far"
        ui_set 100 "Preparing the game for this PC: step $prep_done of $prep_total done" now
      fi
    elif [ $((SECONDS - prep_beat)) -ge 20 ]; then
      # Never a silent wait: a heartbeat when no step finished for 20 s.
      prep_beat=$SECONDS
      echo "    still working: $secs s so far, step $(( ${prep_shown/#-1/0} + 1 )) of ${prep_total/#0/6} is running"
      ui_set 100 "Preparing the game for this PC: step $(( ${prep_shown/#-1/0} + 1 )) of ${prep_total/#0/6} is running ($secs s so far)" now
    fi
  done
  wait "$prep_pid" || warn "prepare finished with a warning (the first launch still works)."
  echo "    prepared in $((SECONDS - prep_start)) s."
  grep -E 'RUNTIME_COOK|RUNTIME_BAKE|DATA_TIER|map_resident|PIPELINE_WARM total' "$prep_log" | sed 's/^/    /' || true
  say "Ready."
fi

# 6. A command and an app-menu entry.
# The command is a template (quoted, so nothing in it needs escaping) with the install's
# places filled in. It holds the update lock, runs the update (its progress shows in a window
# or notifications when there is no terminal) and then ALWAYS starts the game: the new build,
# or the one already installed when the update failed.
wrapper=$(cat <<'WRAP'
#!/usr/bin/env bash
# Direct Order 27 alpha (written by the installer, wrapper 2). Each start checks for a newer
# alpha build and installs it first, then starts the game.
DEST="__DEST__"
API="__API__"
RAW="__RAW__"
MIRROR="__MIRROR__"
REPO_OVERRIDE="__REPO__"
mkdir -p "$DEST"
say() {
  echo "Direct Order 27: $*"
  if ! { : </dev/tty; } 2>/dev/null; then
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v zenity >/dev/null; then
      zenity --info --no-wrap --timeout=10 --title="Direct Order 27" --text="$*" >/dev/null 2>&1 9>&- &
    elif command -v notify-send >/dev/null; then
      notify-send -a "Direct Order 27" -h string:x-canonical-private-synchronous:do27-update "Direct Order 27" "$*" 2>/dev/null || true
    fi
  fi
}
# One update at a time: the lock is held (this file descriptor) until the game starts.
if command -v flock >/dev/null; then
  exec 9>"$DEST/update.lock"
  if ! flock -n 9; then
    prog=$(cat "$DEST/update.progress" 2>/dev/null || true)
    say "Already updating${prog:+ ($prog)}. The game starts when the update is done."
    exit 0
  fi
fi
tok=(); [ -z "${DO27_GH_TOKEN:-}" ] || tok=(-H "Authorization: Bearer $DO27_GH_TOKEN")
latest=$(curl -fsS --max-time 4 "${tok[@]}" "$API" 2>/dev/null | grep -oE '"tag_name": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
have=$(cat "$DEST/VERSION" 2>/dev/null || true)
# Numeric per field (v0.0.9 < v0.0.10 < v0.1.0); the same version under another tag is a re-publish.
vnum() { printf '%s' "$1" | sed -E 's/^v//; s/[-+].*$//'; }
newer=0
if [ -n "$latest" ] && [ "$latest" != "$have" ]; then
  if [ "$(vnum "$latest")" = "$(vnum "$have")" ] || [ "$(printf '%s\n%s\n' "$(vnum "$latest")" "$(vnum "$have")" | sort -V | tail -1)" = "$(vnum "$latest")" ]; then newer=1; fi
fi
if [ "$newer" = 1 ]; then
  # (A quick notification only: the update's own progress window opens a moment later.)
  echo "Direct Order 27: updating to $latest... (the game starts by itself when this is done)"
  { : </dev/tty; } 2>/dev/null || { command -v notify-send >/dev/null && notify-send -a "Direct Order 27" -h string:x-canonical-private-synchronous:do27-update "Direct Order 27" "Updating to $latest..." 2>/dev/null; } || true
  tmp=$(mktemp "$DEST/.install.XXXXXX")
  if curl -fsSL "${tok[@]}" -o "$tmp" "$RAW/install.sh"; then
    rc=0
    env DO27_AUTOUPDATE=1 DO27_WRAPPER=2 DO27_LOCK_HELD=1 ${MIRROR:+DO27_ALPHA_MIRROR="$MIRROR"} ${REPO_OVERRIDE:+DO27_REPO_OVERRIDE="$REPO_OVERRIDE"} \
      bash "$tmp" </dev/null 2>&1 | tee -a "$DEST/update.log"
    rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] || echo "Direct Order 27: the update did not finish (code $rc); details are in $DEST/update.log"
  else
    say "Couldn't download the updater (offline?). Starting the version you have."
  fi
  rm -f "$tmp"
fi
if [ -f "$DEST/update.mixed" ]; then
  # A half-applied update: parts of two builds. Not safe to start; the next start carries on.
  say "The update to $(head -1 "$DEST/update.mixed") did not finish. Start Direct Order 27 again to continue it (it picks up where it stopped)."
  exit 1
fi
if [ -x "$DEST/game/run.sh" ]; then
  # The game must not inherit the update lock (fd 9).
  cd "$DEST/game" && exec ./run.sh "$@" 9>&-
fi
say "Direct Order 27 isn't installed. Run the install command again."
exit 1
WRAP
)
shopt -u patsub_replacement 2>/dev/null || true
wrapper=${wrapper//__DEST__/$DEST}; wrapper=${wrapper//__API__/$API}; wrapper=${wrapper//__RAW__/$RAW}
wrapper=${wrapper//__MIRROR__/$MIRROR}; wrapper=${wrapper//__REPO__/${REPO_OVERRIDE:+$REPO}}
printf '%s\n' "$wrapper" | put "$BIN/do27" 755
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

# 7. Uninstaller. Your alpha username stays reserved (it can't change during the alpha).
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

# 8. Preflight: the game's own check of the graphics driver, audio, disk and memory.
if [ -x "$DEST/game/run.sh" ] && [ -z "${DO27_AUTOUPDATE:-}" ]; then
  say "Checking your system for the game..."
  pre=$("$DEST/game/run.sh" preflight 2>&1 || true)
  printf '%s\n' "$pre" | sed 's/^/    /'
  if printf '%s\n' "$pre" | grep -q 'MISSING'; then
    warn "The game will still start; the lines above say what to install for the best result."
  fi
fi

# An auto-update (the do27 command) goes straight on to start the game.
if [ -n "$AUTO" ]; then
  if [ "$prepared" = 1 ]; then
    say "Update done, starting Direct Order 27."
    ui_set 100 "Update done, starting Direct Order 27" now
    sleep 2
  fi
  exit 0
fi
printf '\n%sDone:%s open %sDirect Order 27 (alpha)%s from your app menu, or type %sdo27%s in a terminal.\n' "$B$G" "$N" "$B" "$N" "$B" "$N"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) printf 'To use the do27 command, open a new terminal first. If it still is not found, run %sfish_add_path ~/.local/bin%s (fish) or add ~/.local/bin to your PATH (bash).\n' "$B" "$N" ;;
esac
[ ! -f "$DEST/LICENSE-ALPHA.txt" ] || printf 'This build is a private alpha under LICENSE-ALPHA.txt in %s\n' "$DEST"
printf 'The first time it starts, the game asks you to choose your alpha username.\n'
printf '%s\n' "This alpha sends every log (game, engine, match, network, crash, performance), your username and your IP address to the developer automatically. It can't be turned off. Playing means you agree."
printf 'It updates itself each time you start it. To remove it: do27-uninstall\n\n'
