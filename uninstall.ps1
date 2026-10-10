# Direct Order 27 alpha: remove the game from Windows.
#   irm https://raw.githubusercontent.com/PiercingXX/Alpha-test-DO27/main/uninstall.ps1 | iex
# Same as Settings > Apps > Installed apps > Uninstall, or the do27-uninstall command.
# Your alpha username stays reserved.
& {
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
}
