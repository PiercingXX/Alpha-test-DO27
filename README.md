# Direct Order 27: alpha test

Thanks for testing! This repository holds the packaged alpha build only. It runs on Linux (Arch, CachyOS, or Ubuntu 22.04 or 24.04) and on Windows 10 or 11.

## Linux: install in 3 steps

1. Open a terminal, paste this line, and press Enter:

   ```
   curl -fsSL https://raw.githubusercontent.com/PiercingXX/Alpha-test-DO27/main/install.sh | bash
   ```

   On Ubuntu, paste this line instead (Ubuntu comes without `curl`):

   ```
   wget -qO- https://raw.githubusercontent.com/PiercingXX/Alpha-test-DO27/main/install.sh | bash
   ```

2. Wait. It checks your system, installs anything missing (it may ask for your password once), downloads the game (about 28 GB, in parts; an interrupted download carries on when you run the line again) and checks every part.

3. Play: open **Direct Order 27 (alpha)** from your app menu, or type `do27` in a terminal. The first time, the game asks you to choose your alpha username.

The game updates itself: each time you start it, it checks for a new alpha build and installs it first. An update downloads only the parts that changed (a small patch is a few MB). Running the install line again also updates it.

## Windows: install in 3 steps

1. Open PowerShell: press the Windows key, type `powershell`, and press Enter. Paste this line (right-click pastes), and press Enter:

   ```
   irm https://raw.githubusercontent.com/PiercingXX/Alpha-test-DO27/main/install.ps1 | iex
   ```

2. Wait. It checks your PC (Windows version, graphics card, free space), downloads the game in parts (about 29 GB; if the download stops, run the same line again and it carries on) and checks the download. It doesn't need administrator rights.

3. Play: open **Direct Order 27 (alpha)** from the Start menu or the shortcut on your desktop, or type `do27` in a new PowerShell window. The first time, the game asks you to choose your alpha username.

The game updates itself: each time you start it, it checks for a new alpha build and installs it first (a window shows the download). An update downloads only the parts that changed. Running the install line again also updates it.

### If Windows warns you about the game

The alpha isn't signed with a certificate yet, so Windows may not know it:

- **A blue box, "Windows protected your PC":** click **More info**, then **Run anyway**. You only see this once.
- **"Smart App Control blocked an app":** Smart App Control has no "run anyway". The installer tells you if it's on. To play, turn it off: Start > **Windows Security** > **App & browser control** > **Smart App Control settings** > **Off**.
- **Your antivirus removes or blocks `do27_launcher.exe`:** allow the folder `%LOCALAPPDATA%\DO27-alpha` in your antivirus, then run the install line again.

## What you need

On Linux:

- Arch Linux or CachyOS (64-bit), updated in the last year (`sudo pacman -Syu`), or Ubuntu 22.04 or 24.04 (64-bit)
- On Ubuntu with an NVIDIA card: the NVIDIA driver, installed before the game. Open **Software & Updates > Additional Drivers**, pick the recommended NVIDIA driver, restart, then run the install line. The installer never installs an NVIDIA driver itself. AMD and Intel cards need nothing extra.
- A graphics card with Vulkan: an NVIDIA RTX 2080 or newer, or an AMD RX 6000 or newer
- An NVMe SSD with 55 GB free (the game takes about 52 GB once installed)
- 16 GB of RAM

On Windows:

- Windows 10 (version 21H2 or newer) or Windows 11, 64-bit
- A graphics card with DirectX 12 and an up-to-date driver: an NVIDIA RTX 2080 or newer, or an AMD RX 6000 or newer
- An SSD with 60 GB free on the drive Windows is on (the game takes about 52 GB once installed)
- 16 GB of RAM

## Your alpha username

On the first start you choose a username: 3 to 24 letters, digits, `-` or `_`. It is locked for the whole alpha and can't be changed, so pick the name you want to be known by. Names that pose as the dev team (admin, dev, PiercingXX and the like) are refused.

## What gets installed where

On Linux:

- The game: `~/.local/share/do27-alpha/`
- The `do27` and `do27-uninstall` commands: `~/.local/bin/`
- The app-menu entry: `~/.local/share/applications/do27-alpha.desktop`
- Your settings and keys: `~/.config/DO27/`
- Your username, logs and crash reports: `~/.local/share/do27/`
- Graphics caches: `~/.cache/do27/`
- System packages, only if they're missing. Arch and CachyOS: `vulkan-icd-loader`, `vulkan-tools`, your graphics driver (`nvidia-utils`, `vulkan-radeon` or `vulkan-intel`), `curl`, `tar`, `zstd`. Ubuntu: `libvulkan1`, `mesa-vulkan-drivers`, `vulkan-tools`, `curl`, `tar`, `zstd` and a few standard libraries a desktop already has (sound, X11/Wayland, EGL)

On Windows:

- The game: `%LOCALAPPDATA%\DO27-alpha\` (the `do27` and `do27-uninstall` commands are in its `bin` folder, which the installer adds to your user PATH)
- The Start menu and desktop shortcuts, and an entry in **Settings > Apps > Installed apps**
- Your settings and keys: `%APPDATA%\DO27\`
- Your username, logs and crash reports: `%LOCALAPPDATA%\DO27\`
- Graphics caches: `%LOCALAPPDATA%\DO27\cache\`
- Nothing else: no system files, no drivers, no administrator changes

## Reporting problems

Crash and session logs are sent to the dev team automatically, so a crash gets reported even if you do nothing. To tell us what happened, open an issue here (**Issues > New issue > Bug report**) or post in the alpha channel on Discord. Include your alpha username and the time it happened.

## What the alpha logs

By playing the alpha you agree that these are sent to the dev team with every session and crash, on Linux and on Windows:

- your alpha username
- your IP address
- your system: Linux distribution and kernel, or Windows version and build; processor, graphics card and driver, memory
- the game's and the engine's session logs, crash and freeze reports (on Windows these include a small memory dump of the game's threads when it freezes) and performance numbers

## Uninstall

On Linux:

```
do27-uninstall
```

On Windows: **Settings > Apps > Installed apps > Direct Order 27 (alpha) > Uninstall**, or **Uninstall Direct Order 27 (alpha)** in the Start menu, or type `do27-uninstall` in PowerShell.

This removes the game, the commands, the app-menu or Start menu entries, your settings, logs and caches. Your alpha username stays reserved until the alpha ends. On Linux the system packages stay: they're standard Arch or Ubuntu packages that other programs use too.

This is a test build under the alpha license in `LICENSE-ALPHA.txt`. Please don't share it outside the alpha.
