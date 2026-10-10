[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$')][string] $HostName,
    [Parameter()][ValidateRange(1, 65535)][int] $Port = 8443,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9 ]{40,59}$')][string] $CertificateThumbprint,
    [Parameter(Mandatory)][string] $RunAsAccount
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this setup script from an elevated PowerShell session.'
}

$thumbprint = ($CertificateThumbprint -replace '\s', '').ToUpperInvariant()
if ($thumbprint.Length -ne 40) {
    throw 'Certificate thumbprint must be a 40-character SHA-1 thumbprint.'
}
$certificate = Get-Item -LiteralPath "Cert:\LocalMachine\My\$thumbprint" -ErrorAction Stop
if (-not $certificate.HasPrivateKey) {
    throw "Certificate $thumbprint does not have an accessible private key."
}
if ($certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
    $certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow) {
    throw "Certificate $thumbprint is not currently valid."
}
if (@($certificate.DnsNameList | ForEach-Object Unicode | Where-Object { $_ -ieq $HostName }).Count -eq 0) {
    throw "Certificate $thumbprint does not list '$HostName' in its DNS names."
}

$netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
$binding = "$HostName`:$Port"
$showBinding = & $netsh http show sslcert "hostnameport=$binding" 2>&1
$showBindingExitCode = $LASTEXITCODE
$bindingDetails = $showBinding -join [Environment]::NewLine
if ($showBindingExitCode -ne 0 -and
    $bindingDetails -notmatch '(?i)cannot find the file specified|no SSL certificate binding') {
    throw "Could not inspect HTTPS certificate binding '$binding': $bindingDetails"
}
if ($bindingDetails.IndexOf($binding, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
    throw "An HTTPS certificate binding already exists for $binding. Review it manually before changing the binding."
}
$showUrl = "https://$HostName`:$Port/"
$showUrlResult = & $netsh http show urlacl "url=$showUrl" 2>&1
$showUrlExitCode = $LASTEXITCODE
$urlDetails = $showUrlResult -join [Environment]::NewLine
if ($showUrlExitCode -ne 0 -and
    $urlDetails -notmatch '(?i)URL reservation|The system cannot find the file specified') {
    throw "Could not inspect URL reservation '$showUrl': $urlDetails"
}
if ($urlDetails.IndexOf($showUrl, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
    throw "A URL reservation already exists for $showUrl. Review it manually before changing the reservation."
}

$applicationId = '{D2D35233-9AC1-4D8C-9E80-85AD8809A923}'
$addBinding = & $netsh http add sslcert "hostnameport=$binding" "certhash=$thumbprint" `
    "appid=$applicationId" 'certstorename=MY' 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Could not register the HTTPS certificate binding: $($addBinding -join ' ')"
}

$addReservation = & $netsh http add urlacl "url=$showUrl" "user=$RunAsAccount" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "HTTPS certificate binding was added, but URL reservation failed: $($addReservation -join ' '). Remove or complete the binding manually."
}

Write-Output "HTTPS registered for https://$HostName`:$Port/ and reserved for $RunAsAccount."
