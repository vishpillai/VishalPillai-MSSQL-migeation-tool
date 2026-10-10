Set-StrictMode -Version Latest

function ConvertTo-MigrationPatchRecord {
    param(
        [Parameter(Mandatory)] $Build,
        [Parameter()][string] $KB = ''
    )

    $kb = if ($KB) { $KB } else { [regex]::Match([string]$Build.KBLevel, '\d+').Value }
    if (-not $kb -or [string]::IsNullOrWhiteSpace([string]$Build.BuildLevel)) {
        return
    }

    [pscustomobject]@{
        KB = $kb
        Product = "SQL Server $($Build.NameLevel)"
        MajorVersion = [string]$Build.NameLevel
        ServicePack = [string]$Build.SPLevel
        UpdateLevel = [string]$Build.CULevel
        Build = [string]$Build.Build
        BuildLevel = [string]$Build.BuildLevel
        ReleaseDate = if ($Build.ReleaseDate) { ([datetime]$Build.ReleaseDate).ToString('o') } else { '' }
        SupportedUntil = if ($Build.SupportedUntil) { ([datetime]$Build.SupportedUntil).ToString('o') } else { '' }
        MatchType = [string]$Build.MatchType
        Title = "SQL Server $($Build.NameLevel) $($Build.SPLevel) $($Build.CULevel) (KB$kb)".Trim()
    }
}

function Get-MigrationSqlServerPatchCatalog {
    [CmdletBinding()]
    param([Parameter()][switch] $Refresh)

    if ($Refresh) {
        Update-DbaBuildReference -EnableException -ErrorAction Stop | Out-Null
    }

    $branches = @(
        @{ MajorVersion = 'SQL2012'; ServicePacks = @('SP3', 'SP4') }
        @{ MajorVersion = 'SQL2016'; ServicePacks = @('SP2', 'SP3') }
        @{ MajorVersion = 'SQL2019'; ServicePacks = @('RTM') }
        @{ MajorVersion = 'SQL2022'; ServicePacks = @('RTM') }
    )
    $catalog = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($branch in $branches) {
        foreach ($servicePack in $branch.ServicePacks) {
            $previousKb = ''
            $repeatedKbCount = 0
            for ($updateNumber = 0; $updateNumber -le 50; $updateNumber++) {
                $updateLabel = "CU$updateNumber"
                $builds = @(Get-DbaBuild -MajorVersion $branch.MajorVersion -ServicePack $servicePack `
                    -CumulativeUpdate $updateLabel -ErrorAction SilentlyContinue)
                if ($builds.Count -eq 0) {
                    if ($updateNumber -gt 0) { break }
                    continue
                }

                foreach ($build in $builds) {
                    $kbValues = @([regex]::Matches([string]$build.KBLevel, '\d{5,10}') | ForEach-Object Value | Select-Object -Unique)
                    foreach ($kb in $kbValues) {
                        $patchBuild = @()
                        if ($kbValues.Count -gt 1) {
                            $patchBuild = @(Get-DbaBuild -KB $kb -ErrorAction SilentlyContinue | Select-Object -First 1)
                        }
                        $recordBuild = if ($patchBuild) { $patchBuild[0] } else { $build }
                        $patch = ConvertTo-MigrationPatchRecord -Build $recordBuild -KB $kb
                        if (-not $patch) { continue }
                        if ($updateNumber -eq 0 -and $servicePack -ne 'RTM') {
                            $patch.UpdateLevel = 'Service Pack'
                        }
                        elseif ($updateNumber -gt 0 -and [string]::IsNullOrWhiteSpace($patch.UpdateLevel)) {
                            $patch.UpdateLevel = 'GDR'
                        }
                        $catalogKey = "$($patch.MajorVersion)|$($patch.KB)"
                        if (-not $catalog.ContainsKey($catalogKey)) {
                            $catalog[$catalogKey] = $patch
                        }
                        if ($patch.KB -eq $previousKb) {
                            $repeatedKbCount++
                        }
                        else {
                            $previousKb = $patch.KB
                            $repeatedKbCount = 0
                        }
                    }
                }

                if ($repeatedKbCount -ge 2) { break }
            }
        }
    }

    @($catalog.Values | Sort-Object -Property @{ Expression = 'ReleaseDate'; Descending = $true }, 'Product', 'Build')
}

function Get-MigrationSqlServerPatchByKB {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^\d{5,10}$')][string] $KB)

    $build = @(Get-DbaBuild -KB $KB -EnableException -ErrorAction Stop | Select-Object -First 1)
    if (-not $build) {
        throw "KB$KB is not in the SQL Server build reference catalog. Refresh the patch catalog and choose a listed update."
    }
    ConvertTo-MigrationPatchRecord -Build $build[0]
}

function Get-MigrationSqlServerPatchServerInfoInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $SqlInstance)

    Invoke-DbaQuery -SqlInstance $SqlInstance -Database master -EnableException -ErrorAction Stop -Query @'
SELECT
    CONVERT(nvarchar(128), SERVERPROPERTY('MachineName')) AS MachineName,
    CONVERT(nvarchar(128), SERVERPROPERTY('InstanceName')) AS InstanceName,
    CONVERT(int, SERVERPROPERTY('IsClustered')) AS IsClustered,
    CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')) AS ProductVersion;
'@ | Select-Object -First 1
}

function Get-MigrationSqlServerPatchAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $SqlInstance,
        [Parameter(Mandatory)][ValidatePattern('^\d{5,10}$')][string] $KB
    )

    $patch = Get-MigrationSqlServerPatchByKB -KB $KB
    $server = Get-MigrationSqlServerPatchServerInfoInternal -SqlInstance $SqlInstance
    if (-not $server -or [string]::IsNullOrWhiteSpace([string]$server.ProductVersion)) {
        throw "Could not read the installed SQL Server build from '$SqlInstance'."
    }
    $installedBuild = @(Get-DbaBuild -Build ([string]$server.ProductVersion) -EnableException -ErrorAction Stop |
        Select-Object -First 1)

    $status = 'Eligible'
    $reason = 'The selected patch is newer and matches this SQL Server major version and service-pack branch.'
    if ([int]$server.IsClustered -eq 1) {
        $status = 'UnsupportedCluster'
        $reason = 'Clustered instances require a cluster-aware patch procedure.'
    }
    elseif (-not $installedBuild) {
        $status = 'UnknownBuild'
        $reason = 'The installed build could not be matched to the SQL Server build reference.'
    }
    elseif ([string]$installedBuild[0].NameLevel -ne $patch.MajorVersion) {
        $status = 'VersionMismatch'
        $reason = "Patch is for SQL Server $($patch.MajorVersion); this instance is SQL Server $($installedBuild[0].NameLevel)."
    }
    else {
        $currentBuildLevel = [version]$installedBuild[0].BuildLevel
        $candidateBuildLevel = [version]$patch.BuildLevel
        $isServicePackUpgrade = $patch.UpdateLevel -match 'Service Pack' -and $patch.ServicePack -ne [string]$installedBuild[0].SPLevel
        if ($patch.ServicePack -ne [string]$installedBuild[0].SPLevel -and -not $isServicePackUpgrade) {
            $status = 'ServicePackMismatch'
            $reason = "Patch targets $($patch.ServicePack); this instance is on $($installedBuild[0].SPLevel). Select a matching update or service-pack upgrade."
        }
        elseif ($patch.KB -in @([regex]::Matches([string]$installedBuild[0].KBLevel, '\d{5,10}') | ForEach-Object Value)) {
            $status = 'AlreadyInstalled'
            $reason = 'This exact KB is reported for the installed SQL Server build.'
        }
        elseif ($candidateBuildLevel -lt $currentBuildLevel) {
            $status = 'Superseded'
            $reason = 'The installed SQL Server build is newer than the selected patch.'
        }
        elseif ($candidateBuildLevel -eq $currentBuildLevel) {
            $status = 'SameBuild'
            $reason = 'The installed build level matches this patch; no update is needed.'
        }
    }

    [pscustomobject]@{
        SqlInstance = $SqlInstance
        ComputerName = [string]$server.MachineName
        InstanceName = if ([string]::IsNullOrWhiteSpace([string]$server.InstanceName)) { 'MSSQLSERVER' } else { [string]$server.InstanceName }
        CurrentVersion = [string]$server.ProductVersion
        CurrentKB = if ($installedBuild) { @([regex]::Matches([string]$installedBuild[0].KBLevel, '\d{5,10}') | ForEach-Object Value) -join ', ' } else { '' }
        CurrentPatch = if ($installedBuild) { "$($installedBuild[0].SPLevel) $($installedBuild[0].CULevel)".Trim() } else { '' }
        SupportedUntil = if ($installedBuild -and $installedBuild[0].SupportedUntil) { ([datetime]$installedBuild[0].SupportedUntil).ToString('o') } else { '' }
        IsClustered = [bool]$server.IsClustered
        PatchKB = $patch.KB
        PatchTitle = $patch.Title
        PatchBuild = $patch.BuildLevel
        PatchSupportedUntil = $patch.SupportedUntil
        Status = $status
        Reason = $reason
    }
}

function Save-MigrationSqlServerPatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^\d{5,10}$')][string] $KB,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Path
    )

    $patch = Get-MigrationSqlServerPatchByKB -KB $KB
    $null = Get-DbaKbUpdate -Name "KB$KB" -Simple -EnableException -ErrorAction Stop
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $null = New-Item -ItemType Directory -Path $fullPath -Force -ErrorAction Stop
    Save-DbaKbUpdate -Name "KB$KB" -Path $fullPath -Architecture x64 -ErrorAction Stop | Out-Null
    $package = Get-ChildItem -LiteralPath $fullPath -File -Recurse -ErrorAction Stop |
        Where-Object { $_.Name -match "(?i)KB$KB" } | Select-Object -First 1
    if (-not $package) {
        throw "The Microsoft update download completed without a package file for KB$KB in '$fullPath'."
    }

    [pscustomobject]@{
        KB = $patch.KB
        Title = $patch.Title
        Path = $package.FullName
        SizeBytes = $package.Length
        Build = $patch.BuildLevel
    }
}

function Invoke-MigrationSqlServerPatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $SqlInstance,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $UpdatePath,
        [Parameter(Mandatory)][ValidatePattern('^\d{5,10}$')][string] $KB,
        [Parameter()][switch] $Restart
    )

    if (-not (Test-Path -LiteralPath $UpdatePath -PathType Container)) {
        throw "SQL Server update repository folder was not found: $UpdatePath"
    }
    $package = Get-ChildItem -LiteralPath $UpdatePath -File -Recurse -ErrorAction Stop |
        Where-Object { $_.Name -match "(?i)KB$KB" } | Select-Object -First 1
    if (-not $package) {
        throw "KB$KB is not downloaded in the selected update repository. Download the selected patch first."
    }

    $assessment = Get-MigrationSqlServerPatchAssessment -SqlInstance $SqlInstance -KB $KB
    if ($assessment.Status -ne 'Eligible') {
        throw "Patch preflight blocked '$SqlInstance': $($assessment.Status) - $($assessment.Reason)"
    }
    Invoke-MigrationSqlServerPatchInternal -Assessment $assessment -UpdatePath ([System.IO.Path]::GetFullPath($UpdatePath)) `
        -KB $KB -Restart:$Restart
}

function Invoke-MigrationSqlServerPatchInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Assessment,
        [Parameter(Mandatory)][string] $UpdatePath,
        [Parameter(Mandatory)][string] $KB,
        [Parameter()][switch] $Restart
    )

    $parameters = @{
        ComputerName = [string]$Assessment.ComputerName
        InstanceName = [string]$Assessment.InstanceName
        Path = $UpdatePath
        KB = $KB
        Confirm = $false
        EnableException = $true
        ErrorAction = 'Stop'
    }
    if ($Restart) {
        $parameters.Restart = $true
    }

    Update-DbaInstance @parameters | Out-Null
    [pscustomobject]@{
        SqlInstance = $Assessment.SqlInstance
        ComputerName = $Assessment.ComputerName
        InstanceName = $Assessment.InstanceName
        CurrentVersion = $Assessment.CurrentVersion
        TargetBuild = $Assessment.PatchBuild
        KB = $KB
        Status = 'Completed'
    }
}

Export-ModuleMember -Function Get-MigrationSqlServerPatchCatalog, Get-MigrationSqlServerPatchByKB, Get-MigrationSqlServerPatchAssessment, Save-MigrationSqlServerPatch, Invoke-MigrationSqlServerPatch