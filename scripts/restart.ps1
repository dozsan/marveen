# Marveen - Windows restart wrapper (WSL-based)
#
# On Windows the agent runs inside WSL (the installer is WSL-based: see
# install-windows.ps1, which runs install-linux.sh inside the Ubuntu distro).
# There is no native Windows service, so restart is just the Linux restart.sh
# run inside WSL. This script forwards all arguments through.
#
# Usage (PowerShell):
#   .\scripts\restart.ps1                 # restart dashboard + channels
#   .\scripts\restart.ps1 --dry-run
#   .\scripts\restart.ps1 channels
#
# Assumes the default install location inside WSL (~/marveen). Override with the
# MARVEEN_WSL_DIR environment variable if you installed elsewhere.

$ErrorActionPreference = "Stop"

$installDir = if ($env:MARVEEN_WSL_DIR) { $env:MARVEEN_WSL_DIR } else { '$HOME/marveen' }
$fwd = ($args | ForEach-Object { "'$_'" }) -join ' '

wsl bash -lc "$installDir/scripts/restart.sh $fwd"
exit $LASTEXITCODE
