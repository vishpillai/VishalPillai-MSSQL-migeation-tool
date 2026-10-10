[CmdletBinding()]
param(
    [Parameter()][string] $InstallPath,
    [Parameter()][switch] $CurrentUser,
    [Parameter()][switch] $NoDesktopShortcut,
    [Parameter()][switch] $NoStartMenuShortcut
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This installer requires PowerShell 7 or later.'
}

if (-not $IsWindows) {
    throw 'This installer is intended for Windows.'
}

$sourceRoot = $PSScriptRoot
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "The source application folder was not found: $sourceRoot"
}

if (-not $InstallPath) {
    if ($CurrentUser) {
        $InstallPath = Join-Path $env:LOCALAPPDATA 'DbMigrationTool'
    }
    else {
        $InstallPath = Join-Path ${env:ProgramFiles} 'DbMigrationTool'
    }
}

$resolvedInstallPath = [System.IO.Path]::GetFullPath($InstallPath)
if ($CurrentUser -and -not ($resolvedInstallPath -like "$($env:LOCALAPPDATA)*")) {
    $resolvedInstallPath = Join-Path $env:LOCALAPPDATA 'DbMigrationTool'
}

if (-not $CurrentUser) {
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($currentIdentity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'System-wide installation requires an elevated PowerShell session.'
    }
}

$requiredFiles = @(
    'Start-PortableDbMigrationWeb.ps1',
    'Invoke-DbMigrationWeb.ps1',
    'web\index.html',
    'config\migration.config.json'
)

foreach ($relativePath in $requiredFiles) {
    $fullPath = Join-Path $sourceRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Required application file missing from source: $relativePath"
    }
}

$null = New-Item -ItemType Directory -Path $resolvedInstallPath -Force -ErrorAction Stop

$excludedNames = @('.git', '.vscode', 'installer', 'bin', 'obj')
Get-ChildItem -LiteralPath $sourceRoot -Force | Where-Object {
    $_.Name -notin $excludedNames
} | ForEach-Object {
    $sourceItem = $_
    $destinationPath = Join-Path $resolvedInstallPath $sourceItem.Name

    if (Test-Path -LiteralPath $destinationPath -PathType Container) {
        Remove-Item -LiteralPath $destinationPath -Recurse -Force
    }
    elseif (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
        Remove-Item -LiteralPath $destinationPath -Force
    }

    if ($sourceItem.PSIsContainer) {
        Copy-Item -Path $sourceItem.FullName -Destination $destinationPath -Recurse -Force
    }
    else {
        Copy-Item -Path $sourceItem.FullName -Destination $destinationPath -Force
    }
}

$portableAuthDirectory = Join-Path $resolvedInstallPath 'portable\auth'
$portableLogsDirectory = Join-Path $resolvedInstallPath 'portable\logs'
$null = New-Item -ItemType Directory -Path $portableAuthDirectory -Force -ErrorAction Stop
$null = New-Item -ItemType Directory -Path $portableLogsDirectory -Force -ErrorAction Stop

$launcherPath = Join-Path $resolvedInstallPath 'Start-DbMigrationWeb.cmd'
@'
@echo off
setlocal
set "APPROOT=%~dp0"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%APPROOT%Start-PortableDbMigrationWeb.ps1"
'@ | Set-Content -LiteralPath $launcherPath -Encoding ASCII

$appInfoPath = Join-Path $resolvedInstallPath 'appinfo.json'
@{
    Name = 'Db Migration Tool'
    Version = '1.0.0'
    InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
    InstallPath = $resolvedInstallPath
    DefaultUsername = 'migration-admin'
    DefaultPassword = 'MigrationAdmin123!'
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $appInfoPath -Encoding UTF8

function New-DesktopShortcut {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][string] $WorkingDirectory
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $Target
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.IconLocation = Join-Path $WorkingDirectory 'web\favicon.ico'
    $shortcut.Save()
}

if (-not $NoDesktopShortcut) {
    $desktopFolder = [System.Environment]::GetFolderPath('Desktop')
    if ($desktopFolder) {
        $desktopShortcutPath = Join-Path $desktopFolder 'Db Migration Tool.lnk'
        New-DesktopShortcut -Path $desktopShortcutPath -Target $launcherPath -WorkingDirectory $resolvedInstallPath
    }
}

if (-not $NoStartMenuShortcut) {
    $startMenuFolder = [System.Environment]::GetFolderPath('StartMenu')
    $programsFolder = Join-Path $startMenuFolder 'Programs'
    $null = New-Item -ItemType Directory -Path $programsFolder -Force -ErrorAction SilentlyContinue
    $startMenuShortcutPath = Join-Path $programsFolder 'Db Migration Tool.lnk'
    New-DesktopShortcut -Path $startMenuShortcutPath -Target $launcherPath -WorkingDirectory $resolvedInstallPath
}

Write-Host "Installed Db Migration Tool.`nLocation: $resolvedInstallPath`nLaunch with: $launcherPath`nDefault login: migration-admin / MigrationAdmin123!"
