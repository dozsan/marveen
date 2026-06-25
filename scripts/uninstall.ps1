# Marveen - Windows uninstall wrapper (WSL-based)
#
# On Windows the agent runs inside WSL (the installer is WSL-based: see
# install-windows.ps1, which runs install-linux.sh inside the Ubuntu distro).
# Uninstall is therefore the Linux uninstall.sh run inside WSL. This script
# forwards all arguments through.
#
# Usage (PowerShell):
#   .\scripts\uninstall.ps1               # remove services + seeded content (keeps data)
#   .\scripts\uninstall.ps1 --dry-run
#   .\scripts\uninstall.ps1 --purge --yes
#
# Assumes the default install location inside WSL (~/marveen). Override with the
# MARVEEN_WSL_DIR environment variable if you installed elsewhere.
#
# Note: this does NOT remove WSL itself or the Ubuntu distro. To remove the
# distro entirely, use `wsl --unregister <distro>` from PowerShell afterwards.

$ErrorActionPreference = "Stop"

$installDir = if ($env:MARVEEN_WSL_DIR) { $env:MARVEEN_WSL_DIR } else { '$HOME/marveen' }
$fwd = ($args | ForEach-Object { "'$_'" }) -join ' '

wsl bash -lc "$installDir/scripts/uninstall.sh $fwd"
exit $LASTEXITCODE
