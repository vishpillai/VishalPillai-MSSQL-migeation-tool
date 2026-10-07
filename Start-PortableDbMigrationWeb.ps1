[CmdletBinding()]
param(
    [Parameter()][string] $HostName = 'localhost',
    [Parameter()][ValidateRange(1, 65535)][int] $Port = 9080,
    [Parameter()][string] $Username = 'migration-admin',
    [Parameter()][string] $Password = 'MigrationAdmin123!',
    [Parameter()][string] $AppRoot = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FreeTcpPort {
    param([Parameter()][int] $PreferredPort)

    $candidate = $PreferredPort
    for ($offset = 0; $offset -lt 50; $offset++) {
        $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $candidate)
        try {
            $tcpListener.Start()
            return $candidate
        }
        catch {
            $candidate = $PreferredPort + $offset + 1
        }
        finally {
            $tcpListener.Stop()
        }
    }

    throw "Could not find a free loopback port near $PreferredPort."
}

Import-Module (Join-Path $AppRoot 'src\DbMigration.WebAuth.psm1') -Force
$storage = Resolve-MigrationWebStoragePaths -AppRoot $AppRoot -PortableMode

if (-not (Test-Path -LiteralPath $storage.AuthPath -PathType Leaf)) {
    $null = New-Item -ItemType Directory -Path $storage.AuthDirectory -Force -ErrorAction Stop
    $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
    $record = New-MigrationWebPasswordRecord -Username $Username -Password $securePassword
    $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $storage.AuthPath -Encoding utf8
    Write-Host "Portable auth file created at $($storage.AuthPath)"
}

$selectedPort = Get-FreeTcpPort -PreferredPort $Port
if ($selectedPort -ne $Port) {
    Write-Host "Port $Port is unavailable; starting portable web app on $selectedPort instead."
}

& (Join-Path $AppRoot 'Invoke-DbMigrationWeb.ps1') -HostName $HostName -Port $selectedPort -PortableMode -AppRoot $AppRoot
