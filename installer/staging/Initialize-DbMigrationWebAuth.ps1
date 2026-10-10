[CmdletBinding()]
param(
    [Parameter()][string] $Username,
    [Parameter()][string] $RunAsAccount = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
    [Parameter()][switch] $PortableMode,
    [Parameter()][string] $AppRoot = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.WebAuth.psm1') -Force

$storage = Resolve-MigrationWebStoragePaths -AppRoot $AppRoot -PortableMode:$PortableMode
$directory = $storage.AuthDirectory
$fullPath = $storage.AuthPath

if (-not $PortableMode) {
    if (-not [string]::Equals(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            $RunAsAccount,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Run credential initialization as the same Windows account that will host the browser app.'
    }
}

if ([string]::IsNullOrWhiteSpace($Username)) {
    $Username = Read-Host 'Dedicated migration app username'
}
$password = Read-Host 'Dedicated migration app password (14+ characters)' -AsSecureString
$confirmation = Read-Host 'Re-enter the application password' -AsSecureString
$passwordPointer = [IntPtr]::Zero
$confirmationPointer = [IntPtr]::Zero
try {
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($password)
    $confirmationPointer = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($confirmation)
    $passwordText = [Runtime.InteropServices.Marshal]::PtrToStringUni($passwordPointer)
    $confirmationText = [Runtime.InteropServices.Marshal]::PtrToStringUni($confirmationPointer)
    if (-not [string]::Equals($passwordText, $confirmationText, [StringComparison]::Ordinal)) {
        throw 'The passwords do not match. No credentials were changed; run the script again.'
    }
    $record = New-MigrationWebPasswordRecord -Username $Username -Password $password
}
finally {
    if ($passwordPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($passwordPointer)
    }
    if ($confirmationPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($confirmationPointer)
    }
    $passwordText = $null
    $confirmationText = $null
    $password.Dispose()
    $confirmation.Dispose()
}

$null = New-Item -ItemType Directory -Path $directory -Force

if (-not $PortableMode) {
    $allowedIdentities = @(
        ([System.Security.Principal.NTAccount]::new($RunAsAccount).Translate([System.Security.Principal.SecurityIdentifier]))
        ([System.Security.Principal.SecurityIdentifier]::new([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null))
        ([System.Security.Principal.SecurityIdentifier]::new([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null))
    )
    $directoryItem = Get-Item -LiteralPath $directory -Force
    if ($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Authentication directory must not be a reparse point: $directory"
    }
    $directoryAcl = Get-Acl -LiteralPath $directory
    $directoryAcl.SetAccessRuleProtection($true, $false)
    foreach ($existingRule in @($directoryAcl.Access)) {
        $directoryAcl.RemoveAccessRuleSpecific($existingRule)
    }
    foreach ($identity in $allowedIdentities) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity, 'FullControl', 'Allow'
        )
        $directoryAcl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $directory -AclObject $directoryAcl
}

if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    $null = New-Item -ItemType File -Path $fullPath -Force
}

if (-not $PortableMode) {
    $authItem = Get-Item -LiteralPath $fullPath -Force
    if ($authItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Authentication file must not be a reparse point: $fullPath"
    }
    $authAcl = Get-Acl -LiteralPath $fullPath
    $authAcl.SetAccessRuleProtection($true, $false)
    foreach ($existingRule in @($authAcl.Access)) {
        $authAcl.RemoveAccessRuleSpecific($existingRule)
    }
    foreach ($identity in $allowedIdentities) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity, 'FullControl', 'Allow'
        )
        $authAcl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $fullPath -AclObject $authAcl
}
$record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fullPath -Encoding utf8

Write-Output "Authentication record created at $fullPath. Password material is stored only as a salted PBKDF2 hash."
