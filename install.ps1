# Direct Order 27 alpha installer for Windows.
# Install or update (paste into PowerShell):
#   irm https://raw.githubusercontent.com/PiercingXX/Alpha-test-DO27/main/install.ps1 | iex
# Running it again updates the game. Nothing here needs editing.
# Windows PowerShell 5.1 compatible. No "exit": a pasted line must never close the window.

& {
# 'Continue', not 'Stop': Windows PowerShell 5.1 turns a native program's stderr (curl's
# progress bar) into errors whenever output is redirected, and 'Stop' would end the install
# there. Every step that matters checks its result or uses -ErrorAction Stop.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$Repo = 'PiercingXX/Alpha-test-DO27'
$Api = "https://api.github.com/repos/$Repo/releases/latest"
$Raw = "https://raw.githubusercontent.com/$Repo/main"
# Release-test hook: a local copy of the release (latest.json in the GitHub API shape,
# install.ps1 and the assets) served over HTTP.
$Mirror = $env:DO27_ALPHA_MIRROR
if ($Mirror) { $Api = "$Mirror/latest.json"; $Raw = $Mirror }
$Auto = [bool]$env:DO27_AUTOUPDATE

$Dest = Join-Path $env:LOCALAPPDATA 'DO27-alpha'
$Game = Join-Path $Dest 'game'
$Bin = Join-Path $Dest 'bin'
$Data = Join-Path $env:LOCALAPPDATA 'DO27'
$Config = Join-Path $env:APPDATA 'DO27'
$StartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Direct Order 27 (alpha).lnk'
$StartMenuUn = Join-Path ([Environment]::GetFolderPath('Programs')) 'Uninstall Direct Order 27 (alpha).lnk'
$Desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Direct Order 27 (alpha).lnk'
$ArpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DO27-alpha'
$Exe = 'do27_launcher.exe'
$NeedGB = 60   # before a release is known: the unpacked game (~55 GB) + one part being unpacked

function Say($t) { Write-Host '==> ' -ForegroundColor Green -NoNewline; Write-Host $t }
function Warn($t) { Write-Host '!!  ' -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Fail($t) { throw [System.Exception]::new("DO27:$t") }
function Size($bytes) { if ($bytes -ge 1GB) { '{0:N1} GB' -f ($bytes / 1GB) } else { '{0:N0} MB' -f [math]::Max(1, $bytes / 1MB) } }
# Release tags are vMAJOR.MINOR.PATCH (v0.0.1 ... v0.0.9, v0.1.0): compared field by field as
# numbers, never as text. $null for a tag that isn't one.
function TagVersion($t) {
  if ("$t" -match '^v?(\d+)\.(\d+)\.(\d+)') { return [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]) }
  return $null
}
# Every graphics card DXGI lists (the adapters the game itself sees), with its own (dedicated)
# video memory: @{ Name; Bytes; Vendor }. Software adapters are left out. A card built into the
# CPU reports only a small carve-out, so it lands in the LOW package. $null if DXGI can't be asked.
function DxgiCards {
  try {
    if (-not ('Do27Dxgi' -as [type])) {
      Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class Do27Dxgi {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct Desc1 {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
    public uint VendorId, DeviceId, SubSysId, Revision;
    public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
    public long AdapterLuid;
    public uint Flags;
  }
  [ComImport, Guid("770aae78-f26f-4dba-a829-253c83d1b387"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IFactory1 {
    void O0(); void O1(); void O2(); void O3();          // IDXGIObject
    void F0(); void F1(); void F2(); void F3(); void F4(); // IDXGIFactory
    [PreserveSig] int EnumAdapters1(uint index, out IAdapter1 adapter);
  }
  [ComImport, Guid("29038f61-3839-4626-91fd-086879011a05"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAdapter1 {
    void O0(); void O1(); void O2(); void O3();          // IDXGIObject
    void A0(); void A1(); void A2();                     // IDXGIAdapter
    [PreserveSig] int GetDesc1(out Desc1 desc);
  }
  [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid riid, out IFactory1 factory);
  public static string[] List() {
    var iid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
    IFactory1 f;
    if (CreateDXGIFactory1(ref iid, out f) != 0) return new string[0];
    var list = new List<string>();
    for (uint i = 0; i < 16; i++) {
      IAdapter1 a;
      if (f.EnumAdapters1(i, out a) != 0) break;
      Desc1 d;
      if (a.GetDesc1(out d) == 0 && (d.Flags & 2) == 0 && d.VendorId != 0x1414)
        list.Add(d.DedicatedVideoMemory.ToUInt64() + "|" + d.VendorId + "|" + d.Description);
    }
    return list.ToArray();
  }
}
'@
    }
    return @([Do27Dxgi]::List() | ForEach-Object { $p = $_ -split '\|', 3; @{ Bytes = [double]$p[0]; Vendor = [int]$p[1]; Name = $p[2] } })
  } catch { return $null }
}

try {
  Write-Host ''
  Write-Host 'Direct Order 27: alpha installer' -ForegroundColor White
  Write-Host ''

  # 1. The system.
  $os = Get-CimInstance Win32_OperatingSystem
  $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
  $osName = $os.Caption -replace '^Microsoft ', ''
  if ($build -ge 22000) { $osName = $osName -replace 'Windows 10', 'Windows 11' }
  if (-not [Environment]::Is64BitOperatingSystem -or ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'AMD64')) {
    Fail 'This alpha needs 64-bit Windows on an Intel or AMD processor (x64).'
  }
  if ($build -lt 19044) {
    Fail "This alpha needs Windows 10 version 21H2 or newer, or Windows 11. Your system is $osName (build $build). Run Windows Update, restart, then run this command again."
  }
  Say "System: $osName (build $build)"

  # 2. Graphics (DirectX 12), memory and disk.
  $cards = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name } | ForEach-Object { $_.Name })
  $real = @($cards | Where-Object { $_ -notmatch 'Basic Display|Basic Render|Remote Display|Hyper-V|Parsec|Virtual' })
  $dx12 = $null
  if (-not $Auto) {
    Say 'Checking your graphics card (this takes a few seconds)...'
    $dxFile = Join-Path $env:TEMP "do27-dxdiag-$PID.txt"
    try {
      $p = Start-Process dxdiag.exe -ArgumentList '/whql:off', '/t', "`"$dxFile`"" -PassThru -WindowStyle Hidden
      if (-not $p.WaitForExit(90000)) { try { $p.Kill() } catch {} }
      if (Test-Path $dxFile) {
        $dx = Get-Content $dxFile
        $dx12 = [bool]($dx | Where-Object { $_ -match 'DDI Version:\s*12' })
        Remove-Item $dxFile -Force -ErrorAction SilentlyContinue
      }
    } catch {}
  }
  if ($real.Count -eq 0) {
    if ($env:DO27_ALLOW_BASIC_DISPLAY) {
      Warn "No graphics driver found ($($cards -join ', ')). Continuing on the software renderer (test mode)."
    } elseif ($Auto) {
      Warn 'No graphics driver found.'
    } else {
      Fail 'No graphics driver found: Windows is using its basic display driver. Install the driver for your graphics card (NVIDIA, AMD or Intel website, or Windows Update), restart your PC, then run this command again.'
    }
  } else {
    Say "Graphics: $($real[0])"
    if ($dx12 -eq $false) {
      Fail 'Your graphics card or driver has no DirectX 12. Update your graphics driver, restart your PC, then run this command again.'
    }
    if ($real[0] -match 'GTX|Quadro [KMP]|RX [45][0-9]{2}([^0-9]|$)|RX 5[0-9]{3}|Vega|Polaris|UHD|Iris|Radeon\(TM\) Graphics') {
      Warn "This graphics card is below the alpha's minimum (RTX 2080 or RX 6000 class). The game may run slowly."
    }
  }
  $memGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
  if ($memGB -lt 15) { Warn "This PC has $memGB GB of memory; the alpha wants 16 GB. Close other programs before playing." }

  # Which data package fits this PC. Every build comes in three packages with the same game and
  # different texture detail; video memory picks one, never the card's maker or model:
  #   LOW   8 GB of video memory or less, or graphics built into the CPU (they share system memory)
  #   HIGH  10 to 16 GB
  #   ULTRA 20 GB or more
  # The game's own quality setting (how fast it runs) is separate and stays automatic; the package
  # only decides which textures are on disk. $env:DO27_TIER = low|high|ultra overrides the choice,
  # and an update keeps the package you installed.
  $gpuPick = $null
  $dxgi = DxgiCards
  if ($dxgi) { $gpuPick = $dxgi | Sort-Object { $_.Bytes } -Descending | Select-Object -First 1 }
  if (-not $gpuPick) {
    # No DXGI answer: the display drivers' own memory size (a 64-bit value, unlike Win32_VideoController's).
    $gpuPick = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue |
      ForEach-Object { $k = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($k -and $k.'HardwareInformation.qwMemorySize') { @{ Bytes = [double]$k.'HardwareInformation.qwMemorySize'; Name = $k.DriverDesc } } } |
      Sort-Object { $_.Bytes } -Descending | Select-Object -First 1
  }
  $vramGB = if ($gpuPick) { [math]::Round($gpuPick.Bytes / 1GB) } else { 0 }
  $autoTier = if ($vramGB -ge 20) { 'ultra' } elseif ($vramGB -ge 10) { 'high' } else { 'low' }
  # Less than 12 GB of system memory can't hold the bigger packages' textures beside the game.
  if ($memGB -lt 12) { $autoTier = 'low' }
  $gpuDesc = if ($gpuPick) { "$($gpuPick.Name), $vramGB GB video memory" } else { "$(if ($real.Count) { $real[0] } else { 'unknown graphics' }), video memory unknown" }
  New-Item -ItemType Directory -Force -Path $Dest, $Bin -ErrorAction Stop | Out-Null
  $driveName = $Dest.Substring(0, 1)
  $freeGB = [math]::Floor((Get-PSDrive -Name $driveName).Free / 1GB)
  $haveGame = Test-Path (Join-Path $Game $Exe)
  try {
    $media = (Get-Partition -DriveLetter $driveName | Get-Disk | Get-PhysicalDisk).MediaType
    if ("$media" -match 'HDD') { Warn "Drive $driveName is a spinning hard disk. The game loads much faster from an SSD." }
  } catch {}
  # Smart App Control blocks unsigned programs and has no "run anyway".
  try {
    $sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop).VerifiedAndReputablePolicyState
    if ($sac -eq 1) {
      Warn 'Smart App Control is on. It blocks the alpha, because the alpha is not signed yet. To play, turn it off: Start > Windows Security > App & browser control > Smart App control settings > Off.'
    }
  } catch {}

  # 3. The latest alpha build: manifest-windows.json lists the chunks (parts) of the game,
  #    each a .tar.zst of up to 2 GB with its checksum. A first install fetches every chunk;
  #    an update fetches only the chunks whose checksum changed. Each chunk is recorded in
  #    manifest-installed.json as soon as it is unpacked, so an interrupted install or
  #    update carries on where it stopped when the command runs again.
  Say 'Looking for the latest alpha build...'
  $rel = $null; $man = $null; $todo = $null
  try { $rel = Invoke-RestMethod -Uri $Api -TimeoutSec 30 -Headers @{ 'User-Agent' = 'do27-installer' } } catch {}
  $tag = $null; $assets = @{}
  if ($rel) {
    $tag = $rel.tag_name
    foreach ($a in @($rel.assets)) { if ($a.name) { $assets[$a.name] = $a } }
  }
  $verFile = Join-Path $Dest 'VERSION'
  $tierFile = Join-Path $Dest 'TIER'
  $instFile = Join-Path $Dest 'manifest-installed.json'
  $prepared = $false   # $true once a fresh install or update has just been written
  $haveTag = if (Test-Path $verFile) { (Get-Content $verFile -TotalCount 1).Trim() } else { '' }
  # The package: DO27_TIER, else the one installed (an update keeps it), else this PC's fit.
  $haveTier = if (Test-Path $tierFile) { (Get-Content $tierFile -TotalCount 1).Trim() } else { '' }
  if ($env:DO27_TIER) {
    if ($env:DO27_TIER -notin @('low', 'high', 'ultra')) { Fail "DO27_TIER must be low, high or ultra (it is `"$($env:DO27_TIER)`")." }
    $tier = $env:DO27_TIER
  } elseif ($haveTier -and $haveGame) { $tier = $haveTier } else { $tier = $autoTier }
  $manName = "manifest-windows-$tier"
  if (-not $assets["$manName.json"]) { $manName = 'manifest-windows'; $tier = '' }   # a release from before the packages
  $tierUp = $tier.ToUpper()
  $manAsset = $assets["$manName.json"]
  if (-not $manAsset -or -not $tag) {
    if ($haveGame) {
      Warn "Couldn't check for a new build (offline?). Keeping the one you have."
    } else {
      if ($freeGB -lt $NeedGB) { Warn "The game will need about $NeedGB GB free on drive $driveName (you have $freeGB GB)." }
      Warn 'No Windows alpha build has been released yet. Your PC is ready; run this same command again on test day.'
      return
    }
  } elseif ($haveGame -and $haveTier -eq $tier -and ($haveTag -eq $tag -or ((TagVersion $haveTag) -and (TagVersion $tag) -and (TagVersion $haveTag) -ge (TagVersion $tag)))) {
    Say "You already have the latest build ($haveTag$(if ($tier) { ", $tierUp package" }))."
  } else {
    if (-not $assets["$manName.json.sha256"]) { Fail "The release has no checksum file, so the download can't be verified. Please report this." }
    if (Get-Process -Name 'do27_launcher' -ErrorAction SilentlyContinue) {
      Fail 'The game is running. Close it, then run this command again.'
    }
    $dl = Join-Path $Dest '.download'
    New-Item -ItemType Directory -Force -Path $dl, $Game | Out-Null
    $manFile = Join-Path $dl 'manifest-windows.json'
    $manSumFile = Join-Path $dl 'manifest-windows.json.sha256'
    & curl.exe -fsSL --retry 3 -o $manFile $manAsset.browser_download_url
    $rc1 = $LASTEXITCODE
    & curl.exe -fsSL --retry 3 -o $manSumFile $assets["$manName.json.sha256"].browser_download_url
    if ($rc1 -ne 0 -or $LASTEXITCODE -ne 0) { Fail "Couldn't download the build's file list. Check your internet connection and run the command again." }
    $wantMan = ((Get-Content $manSumFile -TotalCount 1) -split '\s+')[0].ToLower()
    if ((Get-FileHash -Algorithm SHA256 $manFile).Hash.ToLower() -ne $wantMan) { Fail "The build's file list is damaged (checksum mismatch). Run the command again." }
    # Windows PowerShell's ConvertFrom-Json stops at 2 MB: read it with no size limit.
    Add-Type -AssemblyName System.Web.Extensions
    $json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $json.MaxJsonLength = [int]::MaxValue
    $man = $json.DeserializeObject([IO.File]::ReadAllText($manFile))
    if ($man['format'] -ne 1 -or $man['platform'] -ne 'windows') { Fail 'This build needs a newer installer. Run the install command from the alpha page again.' }
    $chunks = @($man['chunks'])
    $installed = @{}
    if ($haveGame -and (Test-Path $instFile)) {
      try { $prev = $json.DeserializeObject([IO.File]::ReadAllText($instFile)); foreach ($k in $prev.Keys) { $installed[$k] = $prev[$k] } } catch {}
    }
    $todo = @($chunks | Where-Object { $installed[$_['name']] -ne $_['sha256'] })
    if ($tier) {
      $allDl = (($chunks | ForEach-Object { [double]$_['size'] }) | Measure-Object -Sum).Sum
      $allUn = (($chunks | ForEach-Object { [double]$_['unpacked'] }) | Measure-Object -Sum).Sum
      Say "Your PC: $gpuDesc -> $tierUp package, $([math]::Ceiling($allDl / 1GB)) GB download ($([math]::Ceiling($allUn / 1GB)) GB installed)."
      if ($tier -ne $autoTier) { Say "(Chosen with DO27_TIER or kept from your install; this PC fits the $($autoTier.ToUpper()) package.)" }
    }
    $fetchBytes = [double]((($todo | ForEach-Object { [double]$_['size'] }) | Measure-Object -Sum).Sum)
    # Space: what the chunks unpack to (an update overwrites most of it, so this is generous),
    # the biggest download, and 2 GB to spare.
    $NeedGB = [math]::Ceiling(((($todo | ForEach-Object { [double]$_['unpacked'] }) | Measure-Object -Sum).Sum +
      (($todo | ForEach-Object { [double]$_['size'] }) | Measure-Object -Maximum).Maximum) / 1GB) + 2
    if ($freeGB -lt $NeedGB) {
      if ($haveGame) {
        Warn "A new build ($tag) is out, but updating needs about $NeedGB GB free on drive $driveName and you have $freeGB GB. Free some space, then run the install command again. Keeping the build you have."
        $todo = $null
      } else {
        $smaller = if ($tier -eq 'ultra') { 'high' } elseif ($tier -eq 'high') { 'low' } else { '' }
        Fail ("Not enough free space on drive ${driveName}: $freeGB GB free, the game needs about $NeedGB GB." +
          $(if ($smaller) { " Or install the smaller $($smaller.ToUpper()) package: set `$env:DO27_TIER='$smaller' in PowerShell, then run the install command again." } else { '' }))
      }
    }
  }
  if ($null -ne $todo -and $man) {
    # Windows 11's tar.exe reads .tar.zst itself; Windows 10's needs zstd.exe (from the release) in front.
    $zstdExe = $null
    $tarZstd = ((& tar.exe --version) -join ' ') -match 'libzstd'
    if ($env:DO27_TEST_NO_TAR_ZSTD) { $tarZstd = $false }
    if (-not $tarZstd) {
      $tool = @($man['tools']) | Where-Object { $_['name'] -eq 'zstd' } | Select-Object -First 1
      if (-not $tool -or -not $assets[$tool['asset']]) { Fail 'This PC needs zstd to unpack the game, and the release has none. Please report this.' }
      $toolsDir = Join-Path $Dest 'tools'
      New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
      $zstdExe = Join-Path $toolsDir 'zstd.exe'
      if (-not (Test-Path $zstdExe) -or (Get-FileHash -Algorithm SHA256 $zstdExe).Hash.ToLower() -ne $tool['sha256']) {
        & curl.exe -fsSL --retry 3 -o $zstdExe $assets[$tool['asset']].browser_download_url
        if ($LASTEXITCODE -ne 0 -or (Get-FileHash -Algorithm SHA256 $zstdExe).Hash.ToLower() -ne $tool['sha256']) {
          Remove-Item $zstdExe -Force -ErrorAction SilentlyContinue
          Fail "Couldn't download zstd (needed to unpack the game on Windows 10). Run the command again."
        }
      }
    }
    if ($todo.Count -gt 0) {
      Say ("Downloading {0} ({1} part(s), about {2}; if it stops, run the command again and it carries on)..." -f $tag, $todo.Count, (Size $fetchBytes))
    }
    $n = 0
    foreach ($c in $todo) {
      $n++
      $asset = $assets[$c['asset']]
      if (-not $asset) { Fail "The release is missing part $($c['asset']). Please report this." }
      $file = Join-Path $dl $c['asset']
      $have = ''
      if ((Test-Path $file) -and (Get-Item $file).Length -eq [int64]$c['size']) { $have = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLower() }
      if ($have -ne $c['sha256']) {
        if ((Test-Path $file) -and (Get-Item $file).Length -gt [int64]$c['size']) { Remove-Item $file -Force }
        Write-Host ("    part {0} of {1}: {2} ({3})" -f $n, $todo.Count, $c['name'], (Size ([double]$c['size'])))
        & curl.exe -fL '-#' -C - --retry 3 -o $file $asset.browser_download_url
        $rc = $LASTEXITCODE
        if ($rc -eq 33 -or $rc -eq 36) {
          # The server can't resume this file: start it again from the beginning.
          Remove-Item $file -Force -ErrorAction SilentlyContinue
          & curl.exe -fL '-#' --retry 3 -o $file $asset.browser_download_url
          $rc = $LASTEXITCODE
        }
        if ($rc -ne 0) { Fail 'The download failed. Check your internet connection and run the command again.' }
        $have = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLower()
        if ($have -ne $c['sha256']) {
          Remove-Item $file -Force -ErrorAction SilentlyContinue
          Fail 'A download is damaged (checksum mismatch). Run the command again.'
        }
      }
      # Unpack over the game folder (files of this chunk are replaced).
      if ($tarZstd) {
        & tar.exe -xf $file -C $Game
        $rc = $LASTEXITCODE
      } else {
        $line = '/d /s /c ""' + $zstdExe + '" -dcq --long=27 "' + $file + '" | tar.exe -xf - -C "' + $Game + '""'
        $rc = (Start-Process cmd.exe -ArgumentList $line -NoNewWindow -Wait -PassThru).ExitCode
      }
      if ($rc -ne 0) { Fail "Couldn't unpack the game. Check the free space on drive $driveName, then run the command again." }
      Remove-Item $file -Force -ErrorAction SilentlyContinue
      $installed[$c['name']] = $c['sha256']
      ($installed | ConvertTo-Json -Compress) | Set-Content -Path $instFile -Encoding Ascii
    }
    # Files no chunk lists (left by an older build) go, then empty folders.
    Say 'Tidying up...'
    $keep = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($c in $chunks) {
      [void]$names.Add($c['name'])
      foreach ($f in @($c['files'])) { [void]$keep.Add($f.Replace('/', '\')) }
    }
    # Identical files ship once; "links" lists the other paths ([path, target]).
    $links = @($man['links'])
    foreach ($l in $links) { if ($l) { [void]$keep.Add(([string]$l[0]).Replace('/', '\')) } }
    $root = (Resolve-Path $Game).Path.TrimEnd('\') + '\'
    Get-ChildItem $Game -Recurse -File -Force | Where-Object { -not $keep.Contains($_.FullName.Substring($root.Length)) } | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $Game -Recurse -Directory -Force | Sort-Object { $_.FullName.Length } -Descending |
      Where-Object { -not (Get-ChildItem $_.FullName -Force) } | Remove-Item -Force -ErrorAction SilentlyContinue
    # Re-make the links (a hard link to the shipped file, or a copy where the drive can't link).
    foreach ($l in $links) {
      if (-not $l) { continue }
      $path = Join-Path $Game (([string]$l[0]).Replace('/', '\'))
      $target = Join-Path $Game (([string]$l[1]).Replace('/', '\'))
      if (-not (Test-Path -LiteralPath $target)) { continue }
      New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
      if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
      try { New-Item -ItemType HardLink -Path $path -Target $target -ErrorAction Stop | Out-Null } catch { Copy-Item -LiteralPath $target $path -Force }
    }
    foreach ($k in @($installed.Keys)) { if (-not $names.Contains($k)) { $installed.Remove($k) } }
    ($installed | ConvertTo-Json -Compress) | Set-Content -Path $instFile -Encoding Ascii
    # Leftovers of the first (single zip) installer, if any.
    foreach ($d in @((Join-Path $Dest 'game.old'), (Join-Path $Dest '.new'), $dl)) { if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } }
    if (-not (Test-Path (Join-Path $Game $Exe))) { Fail 'The build looks incomplete (no game program). Please report this.' }
    Set-Content -Path $verFile -Value $tag -Encoding Ascii -ErrorAction Stop
    if ($tier) { Set-Content -Path $tierFile -Value $tier -Encoding Ascii -ErrorAction Stop } elseif (Test-Path $tierFile) { Remove-Item $tierFile -Force }
    $pkgNote = if ($tier) { " ($tierUp package)" } else { '' }
    if ($todo.Count -gt 0) { Say "Installed $tag$pkgNote." } else { Say "Installed $tag$pkgNote (nothing new to download)." }
    $prepared = $true
  }

  # 5. First-launch preparation (--prepare): verify the shipped cook cache covers
  # both alpha maps and cook any miss, headless, so the first match never waits
  # on texture cooking. Runs after a fresh install and after every update (the
  # GPU pipeline warm is Ferrite's half; this is the DO27 CPU half). A warning
  # here never blocks the game.
  if ($prepared -and -not $env:DO27_SKIP_PREPARE) {
    Say 'Preparing the game for this PC (one-time, after install/update)...'
    $prepLog = Join-Path $Dest 'prepare.log'
    $prepLine = '/d /s /c ""' + (Join-Path $Game $Exe) + '" --prepare > "' + $prepLog + '" 2>&1"'
    $prc = (Start-Process cmd.exe -ArgumentList $prepLine -WorkingDirectory $Game -NoNewWindow -Wait -PassThru).ExitCode
    if ($prc -ne 0) { Warn 'prepare finished with a warning (the first launch still works).' }
    if (Test-Path $prepLog) {
      Get-Content $prepLog | Select-String -Pattern 'RUNTIME_COOK|map_resident' | ForEach-Object { Write-Host ('    ' + $_.Line) }
    }
    Say 'Ready.'
  }

  # 6. The do27 launcher, the Start menu and desktop shortcuts, the uninstaller.
  # do27.ps1: each start checks for a newer alpha build and installs it first (a few
  # seconds; skipped when offline), then starts the game with its console output saved
  # next to the session logs.
  $launcher = @'
param([switch]$FromShortcut, [Parameter(ValueFromRemainingArguments = $true)][string[]]$GameArgs)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
$Dest = Join-Path $env:LOCALAPPDATA 'DO27-alpha'
$Game = Join-Path $Dest 'game'
$Api = '__API__'
$Raw = '__RAW__'
$Mirror = '__MIRROR__'
if ($GameArgs -and $GameArgs[0] -eq 'preflight') {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dest 'preflight.ps1')
  return
}
$latest = $null
try { $latest = (Invoke-RestMethod -Uri $Api -TimeoutSec 4 -Headers @{ 'User-Agent' = 'do27-launcher' }).tag_name } catch {}
$have = ''
if (Test-Path (Join-Path $Dest 'VERSION')) { $have = (Get-Content (Join-Path $Dest 'VERSION') -TotalCount 1).Trim() }
# Update only to a NEWER build: tags compared field by field as numbers (v0.0.9 < v0.1.0).
function TagVersion($t) {
  if ("$t" -match '^v?(\d+)\.(\d+)\.(\d+)') { return [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]) }
  return $null
}
$vLatest = TagVersion $latest
$vHave = TagVersion $have
if ($latest -and $latest -ne $have -and $vLatest -and (-not $vHave -or $vLatest -gt $vHave)) {
  $log = Join-Path $Dest 'update.log'
  # The update's messages also go to update.log (a transcript: the curl progress stays on screen).
  $cmd = "Start-Transcript -Append -Path '$log' | Out-Null; `$env:DO27_AUTOUPDATE='1'; " +
    $(if ($Mirror) { "`$env:DO27_ALPHA_MIRROR='$Mirror'; " } else { '' }) +
    "Write-Host 'Direct Order 27: updating to $latest...'; irm '$Raw/install.ps1' | iex; Stop-Transcript | Out-Null"
  # -EncodedCommand: no quoting trouble on any command line.
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
  if ($FromShortcut) {
    # Started from the Start menu (no window): show the update in a window of its own.
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc -Wait
  } else {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc
  }
}
$exe = Join-Path $Game 'do27_launcher.exe'
if (-not (Test-Path $exe)) {
  Write-Host 'Direct Order 27 is not installed. Run the install command from the alpha page again.'
  if ($FromShortcut) { Start-Sleep 8 }
  return
}
# Console capture: everything the game prints (engine warnings, panics, driver errors) also
# goes to a console log next to the session log. The newest 8 are kept.
$logs = Join-Path $env:LOCALAPPDATA 'DO27\logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
Get-ChildItem $logs -Filter 'console-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 7 | Remove-Item -Force -ErrorAction SilentlyContinue
$console = Join-Path $logs ("console-{0}-{1}.log" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'), $PID)
# (No arguments: $null piped into ForEach-Object would still run once and pass "".)
$argText = ''
if ($GameArgs) { $argText = (@($GameArgs) | ForEach-Object { '"' + ($_ -replace '"', '') + '"' }) -join ' ' }
$line = '/d /s /c ""' + $exe + '" ' + $argText + ' > "' + $console + '" 2>&1"'
$p = Start-Process cmd.exe -ArgumentList $line -WorkingDirectory $Game -WindowStyle Hidden -PassThru
if (-not $FromShortcut) {
  Write-Host "Direct Order 27 is starting. Its console output goes to $console"
  $p.WaitForExit()
}
'@
  $launcher = $launcher.Replace('__API__', $Api).Replace('__RAW__', $Raw).Replace('__MIRROR__', "$Mirror")
  Set-Content -Path (Join-Path $Dest 'do27.ps1') -Value $launcher -Encoding UTF8

  # preflight.ps1: what "do27 preflight" prints (for bug reports).
  $preflight = @'
$ErrorActionPreference = 'Continue'
function Line($t) { Write-Host "do27: $t" }
$n = 0
$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$name = $os.Caption -replace '^Microsoft ', ''
if ([int]$cv.CurrentBuildNumber -ge 22000) { $name = $name -replace 'Windows 10', 'Windows 11' }
Line "system $name $($cv.DisplayVersion) build $($cv.CurrentBuildNumber).$($cv.UBR)"
Line "cpu $((Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim())"
foreach ($v in Get-CimInstance Win32_VideoController) { Line "gpu $($v.Name) driver $($v.DriverVersion)" }
$f = Join-Path $env:TEMP "do27-dxdiag-$PID.txt"
$p = Start-Process dxdiag.exe -ArgumentList '/whql:off', '/t', "`"$f`"" -PassThru -WindowStyle Hidden
if ($p.WaitForExit(90000) -and (Test-Path $f)) {
  $ddi = (Get-Content $f | Where-Object { $_ -match 'DDI Version:' } | ForEach-Object { ($_ -split ':', 2)[1].Trim() }) -join ', '
  Line "directx ddi $ddi"
  if ($ddi -notmatch '12') { Line 'MISSING DirectX 12: update your graphics driver'; $n++ }
  Remove-Item $f -Force -ErrorAction SilentlyContinue
}
$d = Get-PSDrive -Name $env:LOCALAPPDATA.Substring(0, 1)
Line ("disk free on {0}: {1} GB" -f $d.Name, [math]::Floor($d.Free / 1GB))
if ($d.Free -lt 1GB) { Line 'MISSING under 1 GB free. Free some space.'; $n++ }
$mem = Get-CimInstance Win32_OperatingSystem
Line ("memory {0} GB total, {1} GB available" -f [math]::Round($mem.TotalVisibleMemorySize / 1MB), [math]::Round($mem.FreePhysicalMemory / 1MB))
if ($mem.FreePhysicalMemory -lt 4MB) { Line 'MISSING under 4 GB RAM available. Close other programs.'; $n++ }
$ver = Join-Path $env:LOCALAPPDATA 'DO27-alpha\VERSION'
if (Test-Path $ver) { Line "build $((Get-Content $ver -TotalCount 1).Trim())" }
if ($n -eq 0) { Line 'preflight OK' } else { Line "preflight found $n problem(s) (the MISSING lines above; the game still starts)" }
'@
  Set-Content -Path (Join-Path $Dest 'preflight.ps1') -Value $preflight -Encoding UTF8

  # uninstall.ps1: removes everything but the alpha username (it stays reserved).
  $uninstall = @'
$ErrorActionPreference = 'Continue'
$Dest = Join-Path $env:LOCALAPPDATA 'DO27-alpha'
if (Get-Process -Name 'do27_launcher' -ErrorAction SilentlyContinue) {
  Write-Host 'Close Direct Order 27 first, then run the uninstaller again.'
  Start-Sleep 8
  return
}
Write-Host 'Removing Direct Order 27 (alpha)...'
foreach ($f in @(
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'Direct Order 27 (alpha).lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'Uninstall Direct Order 27 (alpha).lnk'),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Direct Order 27 (alpha).lnk'))) {
  Remove-Item $f -Force -ErrorAction SilentlyContinue
}
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DO27-alpha' -Recurse -Force -ErrorAction SilentlyContinue
$bin = Join-Path $Dest 'bin'
$path = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($path) {
  $kept = ($path -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $bin }) -join ';'
  if ($kept -ne $path) { [Environment]::SetEnvironmentVariable('Path', $kept, 'User') }
}
Remove-Item (Join-Path $env:APPDATA 'DO27') -Recurse -Force -ErrorAction SilentlyContinue
$data = Join-Path $env:LOCALAPPDATA 'DO27'
if (Test-Path $data) { Get-ChildItem $data -Force | Where-Object { $_.Name -ne 'profile' } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item $Dest -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path $Dest) { Write-Host "Some files are still in use; delete $Dest after a restart." }
Write-Host 'Direct Order 27 alpha removed. Your alpha username stays reserved for the rest of the alpha.'
if ($env:DO27_UNINSTALL_PAUSE) { Start-Sleep 6 }
'@
  Set-Content -Path (Join-Path $Dest 'uninstall.ps1') -Value $uninstall -Encoding UTF8

  # The commands: do27, do27-uninstall (in a folder on your user PATH).
  Set-Content -Path (Join-Path $Bin 'do27.cmd') -Encoding Ascii -Value "@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Dest\do27.ps1`" %*"
  # The uninstaller runs from a temporary copy, so it can delete its own folder; "(goto)"
  # leaves this batch file first, so cmd doesn't look for it again once it's deleted.
  $unCmd = "@copy /y `"$Dest\uninstall.ps1`" `"%TEMP%\do27-uninstall.ps1`" >nul & (goto) 2>nul & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%TEMP%\do27-uninstall.ps1`""
  Set-Content -Path (Join-Path $Bin 'do27-uninstall.cmd') -Encoding Ascii -Value $unCmd
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not $userPath) { $userPath = '' }
  if (-not (($userPath -split ';') | Where-Object { $_.TrimEnd('\') -eq $Bin })) {
    [Environment]::SetEnvironmentVariable('Path', (($userPath.TrimEnd(';') + ";$Bin").TrimStart(';')), 'User')
  }

  $icon = Join-Path $Game 'icon.ico'
  $shell = New-Object -ComObject WScript.Shell
  foreach ($lnkPath in @($StartMenu, $Desktop)) {
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dest\do27.ps1`" -FromShortcut"
    $lnk.WorkingDirectory = $Dest
    $lnk.Description = 'Direct Order 27 (alpha)'
    if (Test-Path $icon) { $lnk.IconLocation = "$icon,0" }
    $lnk.WindowStyle = 7
    $lnk.Save()
  }
  $lnk = $shell.CreateShortcut($StartMenuUn)
  $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $lnk.Arguments = "/c set DO27_UNINSTALL_PAUSE=1 && `"$Bin\do27-uninstall.cmd`""
  $lnk.Description = 'Remove Direct Order 27 (alpha)'
  $lnk.Save()
  # Settings > Apps > Installed apps lists it, with an Uninstall button.
  New-Item -Path $ArpKey -Force | Out-Null
  $sizeKB = 0
  try { $sizeKB = [int]((Get-ChildItem $Game -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1KB) } catch {}
  $verNow = if (Test-Path $verFile) { (Get-Content $verFile -TotalCount 1).Trim() } else { '' }
  $props = @{
    DisplayName = 'Direct Order 27 (alpha)'; Publisher = 'PiercingXX'; DisplayVersion = $verNow
    InstallLocation = $Dest; DisplayIcon = $icon
    UninstallString = "cmd.exe /c set DO27_UNINSTALL_PAUSE=1 && `"$Bin\do27-uninstall.cmd`""
  }
  foreach ($k in $props.Keys) { New-ItemProperty -Path $ArpKey -Name $k -Value $props[$k] -PropertyType String -Force | Out-Null }
  foreach ($k in @('NoModify', 'NoRepair')) { New-ItemProperty -Path $ArpKey -Name $k -Value 1 -PropertyType DWord -Force | Out-Null }
  New-ItemProperty -Path $ArpKey -Name 'EstimatedSize' -Value $sizeKB -PropertyType DWord -Force | Out-Null

  # 7. A quick check that the game program starts on this PC.
  if (-not $Auto -and (Test-Path (Join-Path $Game $Exe))) {
    $out = & (Join-Path $Game $Exe) --help 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -and $out -notmatch 'usage') {
      Warn "The game program didn't start ($LASTEXITCODE). Your antivirus may have blocked it: allow $Game, then try again."
    }
  }

  if ($Auto) { return }
  Write-Host ''
  Write-Host 'Done: ' -ForegroundColor Green -NoNewline
  Write-Host 'open "Direct Order 27 (alpha)" from the Start menu or your desktop, or type do27 in a new terminal.'
  Write-Host 'The first time it starts, the game asks you to choose your alpha username.'
  Write-Host "This alpha sends every log (game, engine, match, network, crash, performance), your username and your IP address to the developer automatically. It can't be turned off. Playing means you agree."
  Write-Host 'It updates itself each time you start it. To remove it: Settings > Apps > Installed apps, or type do27-uninstall.'
  Write-Host ''
} catch {
  $msg = $_.Exception.Message
  if ($msg -like 'DO27:*') { $msg = $msg.Substring(5) } else { $msg = "Something went wrong: $msg" }
  Write-Host 'XX  ' -ForegroundColor Red -NoNewline
  Write-Host $msg
  Write-Host '    Need help? Post this message in the alpha channel on Discord.'
}
}
