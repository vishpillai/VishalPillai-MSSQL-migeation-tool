[CmdletBinding()]
param(
    [Parameter()][string] $Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$stagingRoot = Join-Path $PSScriptRoot 'staging'

if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
$null = New-Item -ItemType Directory -Path $stagingRoot -Force -ErrorAction Stop

Get-ChildItem -LiteralPath $repoRoot -Force | Where-Object {
    $_.Name -notin @('.git', '.gitignore', '.vscode', 'installer')
} | ForEach-Object {
    $destination = Join-Path $stagingRoot $_.Name
    Copy-Item -Path $_.FullName -Destination $destination -Recurse -Force
}

$launcherPath = Join-Path $stagingRoot 'Start-DbMigrationWeb.cmd'
@'
@echo off
setlocal
set "APPROOT=%~dp0"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%APPROOT%Start-PortableDbMigrationWeb.ps1"
'@ | Set-Content -LiteralPath $launcherPath -Encoding ASCII

$manifest = [System.Collections.Generic.List[string]]::new()
$manifest.Add('<?xml version="1.0" encoding="utf-8"?>')
$manifest.Add('<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">')
$manifest.Add('  <Package Name="Db Migration Tool" Manufacturer="Vishal Pillai" Version="1.0.0.0" UpgradeCode="5D339A8D-CA1E-45D4-A266-4F0812FE5981" Language="1033" Scope="perUser">')
$manifest.Add('    <MediaTemplate CompressionLevel="high" />')
$manifest.Add('    <Feature Id="MainFeature" Title="Db Migration Tool" Level="1">')
$manifest.Add('      <ComponentGroupRef Id="AppFiles" />')
$manifest.Add('      <ComponentRef Id="AppStartMenuShortcut" />')
$manifest.Add('      <ComponentRef Id="AppDesktopShortcut" />')
$manifest.Add('    </Feature>')
$manifest.Add('    <StandardDirectory Id="LocalAppDataFolder">')
$manifest.Add('      <Directory Id="INSTALLFOLDER" Name="DbMigrationTool" />')
$manifest.Add('    </StandardDirectory>')
$manifest.Add('    <StandardDirectory Id="ProgramMenuFolder" />')
$manifest.Add('    <StandardDirectory Id="DesktopFolder" />')
$manifest.Add('    <Component Id="AppStartMenuShortcut" Directory="ProgramMenuFolder" Guid="{2D9E0C4A-F9A1-4A55-B4F6-09D0CBF82E0D}">')
$manifest.Add('      <Shortcut Id="AppShortcut" Name="Db Migration Tool" Target="[INSTALLFOLDER]Start-DbMigrationWeb.cmd" WorkingDirectory="INSTALLFOLDER" />')
$manifest.Add('      <RegistryValue Root="HKCU" Key="Software\DbMigrationTool" Name="StartMenuShortcut" Type="integer" Value="1" KeyPath="yes" />')
$manifest.Add('    </Component>')
$manifest.Add('    <Component Id="AppDesktopShortcut" Directory="DesktopFolder" Guid="{919DEE3A-6F4E-4EA8-A09B-0F8A356D82B2}">')
$manifest.Add('      <Shortcut Id="DesktopShortcut" Name="Db Migration Tool" Target="[INSTALLFOLDER]Start-DbMigrationWeb.cmd" WorkingDirectory="INSTALLFOLDER" />')
$manifest.Add('      <RegistryValue Root="HKCU" Key="Software\DbMigrationTool" Name="DesktopShortcut" Type="integer" Value="1" KeyPath="yes" />')
$manifest.Add('    </Component>')
$manifest.Add('  </Package>')
$manifest.Add('  <Fragment>')
$manifest.Add('    <DirectoryRef Id="INSTALLFOLDER">')

$componentRefs = [System.Collections.Generic.List[string]]::new()

function Get-SafeId {
    param([Parameter(Mandatory)][string] $Value)
    $safe = ($Value -replace '[^A-Za-z0-9_]', '_').Trim('_')
    if ([string]::IsNullOrEmpty($safe)) { $safe = 'item' }
    if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
    return $safe
}

function Add-DirectoryEntries {
    param(
        [Parameter(Mandatory)][string] $CurrentPath,
        [Parameter(Mandatory)][string] $ParentDirectoryId,
        [Parameter(Mandatory)][string] $LogicalPath
    )

    $entries = Get-ChildItem -LiteralPath $CurrentPath -Force | Sort-Object Name
    foreach ($entry in $entries) {
        if ($entry.PSIsContainer) {
            $dirId = 'dir_' + (Get-SafeId -Value ($LogicalPath + '_' + $entry.Name))
            $manifest.Add('      <Directory Id="' + $dirId + '" Name="' + $entry.Name + '">')
            Add-DirectoryEntries -CurrentPath $entry.FullName -ParentDirectoryId $dirId -LogicalPath ($LogicalPath + '_' + $entry.Name)
            $manifest.Add('      </Directory>')
            continue
        }

        $componentId = 'cmp_' + (Get-SafeId -Value ($LogicalPath + '_' + $entry.Name))
        $fileId = 'file_' + (Get-SafeId -Value ($LogicalPath + '_' + $entry.Name))
        $source = [System.IO.Path]::GetRelativePath($stagingRoot, $entry.FullName) -replace '\\', '/'
        $guid = [guid]::NewGuid().ToString('B')
        $manifest.Add('      <Component Id="' + $componentId + '" Guid="' + $guid + '" Directory="' + $ParentDirectoryId + '">')
        $manifest.Add('        <File Id="' + $fileId + '" Source="' + $source + '" />')
        $manifest.Add('        <RegistryValue Root="HKCU" Key="Software\DbMigrationTool\AppFiles" Name="' + $componentId + '" Type="string" Value="' + $source + '" KeyPath="yes" />')
        $manifest.Add('      </Component>')
        $componentRefs.Add('      <ComponentRef Id="' + $componentId + '" />')
    }
}

Get-ChildItem -LiteralPath $stagingRoot -Force | Sort-Object Name | ForEach-Object {
    if ($_.PSIsContainer) {
        $dirId = 'dir_' + (Get-SafeId -Value ('root_' + $_.Name))
        $manifest.Add('      <Directory Id="' + $dirId + '" Name="' + $_.Name + '">')
        Add-DirectoryEntries -CurrentPath $_.FullName -ParentDirectoryId $dirId -LogicalPath ('root_' + $_.Name)
        $manifest.Add('      </Directory>')
        return
    }

    $componentId = 'cmp_' + (Get-SafeId -Value ('root_' + $_.Name))
    $fileId = 'file_' + (Get-SafeId -Value ('root_' + $_.Name))
    $source = [System.IO.Path]::GetRelativePath($stagingRoot, $_.FullName) -replace '\\', '/'
    $guid = [guid]::NewGuid().ToString('B')
    $manifest.Add('      <Component Id="' + $componentId + '" Guid="' + $guid + '" Directory="INSTALLFOLDER">')
    $manifest.Add('        <File Id="' + $fileId + '" Source="' + $source + '" />')
    $manifest.Add('        <RegistryValue Root="HKCU" Key="Software\DbMigrationTool\AppFiles" Name="' + $componentId + '" Type="string" Value="' + $source + '" KeyPath="yes" />')
    $manifest.Add('      </Component>')
    $componentRefs.Add('      <ComponentRef Id="' + $componentId + '" />')
}

$manifest.Add('    </DirectoryRef>')
$manifest.Add('    <ComponentGroup Id="AppFiles">')
foreach ($ref in $componentRefs) {
    $manifest.Add($ref)
}
$manifest.Add('    </ComponentGroup>')
$manifest.Add('  </Fragment>')
$manifest.Add('</Wix>')

$manifestPath = Join-Path $PSScriptRoot 'Product.wxs'
$manifest.ToArray() | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$legacyAppFilesPath = Join-Path $PSScriptRoot 'AppFiles.wxs'
if (Test-Path -LiteralPath $legacyAppFilesPath) {
    Remove-Item -LiteralPath $legacyAppFilesPath -Force
}

$projectPath = Join-Path $PSScriptRoot 'DbMigrationTool.Installer.wixproj'
& dotnet build $projectPath -c $Configuration --nologo
if ($LASTEXITCODE -ne 0) {
    throw 'WiX build failed.'
}

$artifact = Get-ChildItem -Path (Join-Path $PSScriptRoot 'bin') -Recurse -File -Filter '*.msi' | Sort-Object LastWriteTimeUtc | Select-Object -Last 1
if (-not $artifact) {
    throw 'No MSI was generated.'
}

Write-Host "Installer artifact: $($artifact.FullName)"
