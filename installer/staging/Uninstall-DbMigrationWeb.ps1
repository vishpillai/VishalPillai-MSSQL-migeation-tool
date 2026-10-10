[CmdletBinding()]
param(
    [Parameter()][string] $InstallPath = (Join-Path $env:LOCALAPPDATA 'DbMigrationTool')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedInstallPath = [System.IO.Path]::GetFullPath($InstallPath)
if (Test-Path -LiteralPath $resolvedInstallPath -PathType Container) {
    Remove-Item -LiteralPath $resolvedInstallPath -Recurse -Force -ErrorAction Stop
}

$desktopShortcut = Join-Path ([System.Environment]::GetFolderPath('Desktop')) 'Db Migration Tool.lnk'
if (Test-Path -LiteralPath $desktopShortcut) {
    Remove-Item -LiteralPath $desktopShortcut -Force
}

$startMenuFolder = [System.Environment]::GetFolderPath('StartMenu')
if ($startMenuFolder) {
    $startMenuShortcut = Join-Path $startMenuFolder 'Programs\Db Migration Tool.lnk'
    if (Test-Path -LiteralPath $startMenuShortcut) {
        Remove-Item -LiteralPath $startMenuShortcut -Force
    }
}

Write-Host "Removed Db Migration Tool from $resolvedInstallPath."
