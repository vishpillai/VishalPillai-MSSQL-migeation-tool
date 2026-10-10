[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PlanPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $plan = Get-Content -LiteralPath $PlanPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    Import-Module dbatools -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.Patching.psm1') -Force

    if ($plan.Action -eq 'Download') {
        $result = Save-MigrationSqlServerPatch -KB ([string]$plan.KB) -Path ([string]$plan.UpdatePath)
        Write-Output "Downloaded KB$($result.KB) ($($result.SizeBytes) bytes) to $($result.Path)."
        exit 0
    }
    if ($plan.Action -ne 'Apply') {
        throw "Unsupported patch action '$($plan.Action)'."
    }

    foreach ($target in $plan.Targets) {
        Write-Output "Applying KB$($plan.KB) to $($target.Role) instance '$($target.SqlInstance)'."
        $result = Invoke-MigrationSqlServerPatch -SqlInstance $target.SqlInstance `
            -UpdatePath $plan.UpdatePath -KB ([string]$plan.KB) -Restart:([bool]$plan.Restart)
        Write-Output "Completed $($result.SqlInstance): $($result.CurrentVersion) -> $($result.TargetBuild) (KB$($result.KB))."
    }
}
catch {
    [Console]::Error.WriteLine("SQL Server patch failed: $($_.Exception.Message)")
    exit 1
}