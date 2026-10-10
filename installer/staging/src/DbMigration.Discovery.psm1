Set-StrictMode -Version Latest

function Get-MigrationVolumeDetails {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [object[]] $Disks
    )

    $root = [System.IO.Path]::GetPathRoot($Path)
    $disk = $Disks | Where-Object { $_.Name.TrimEnd('\') -eq $root.TrimEnd('\') } | Select-Object -First 1
    if (-not $disk) {
        return [pscustomobject]@{
            Volume = $root
            CapacityGB = $null
            FreeGB = $null
            PercentFree = $null
        }
    }

    [pscustomobject]@{
        Volume = $disk.Name
        CapacityGB = [math]::Round([double]$disk.SizeInGB, 2)
        FreeGB = [math]::Round([double]$disk.FreeInGB, 2)
        PercentFree = [math]::Round([double]$disk.PercentFree, 2)
    }
}

function Test-MigrationRestoreCapacity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Source,

        [Parameter(Mandatory)]
        [string] $Target,

        [Parameter(Mandatory)]
        [string] $Database,

        [Parameter(Mandatory)]
        [ValidateRange(0, 100)]
        [double] $BufferPercent = 20
    )

    $files = @(Get-DbaDbFile -SqlInstance $Source -Database $Database -EnableException -ErrorAction Stop)
    $dataFiles = @($files | Where-Object TypeDescription -eq 'ROWS')
    $logFiles = @($files | Where-Object TypeDescription -eq 'LOG')
    if ($dataFiles.Count -eq 0 -or $logFiles.Count -eq 0) {
        throw "Could not determine both data and log file sizes for '$Database' on '$Source'."
    }

    $targetPaths = Get-DbaDefaultPath -SqlInstance $Target -EnableException -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace([string]$targetPaths.Data) -or [string]::IsNullOrWhiteSpace([string]$targetPaths.Log)) {
        throw "Target '$Target' does not have default data and log paths configured."
    }
    $targetConnection = Connect-DbaInstance -SqlInstance $Target -ErrorAction Stop
    $targetDisks = @(Get-DbaDiskSpace -ComputerName $targetConnection.ComputerName -Unit GB -EnableException -ErrorAction Stop)
    $dataVolume = Get-MigrationVolumeDetails -Path $targetPaths.Data -Disks $targetDisks
    $logVolume = Get-MigrationVolumeDetails -Path $targetPaths.Log -Disks $targetDisks
    if ($null -eq $dataVolume.FreeGB -or $null -eq $logVolume.FreeGB) {
        throw "Could not determine free space for the target data or log volume on '$Target'."
    }

    $dataBytes = (@($dataFiles | ForEach-Object { [double]$_.Size.Byte } | Measure-Object -Sum).Sum)
    $logBytes = (@($logFiles | ForEach-Object { [double]$_.Size.Byte } | Measure-Object -Sum).Sum)
    $dataRequiredGB = [math]::Round(([double]$dataBytes / 1GB), 2)
    $logRequiredGB = [math]::Round(([double]$logBytes / 1GB), 2)
    $bufferMultiplier = 1 + ($BufferPercent / 100)
    $dataRequiredWithBufferGB = [math]::Round($dataRequiredGB * $bufferMultiplier, 2)
    $logRequiredWithBufferGB = [math]::Round($logRequiredGB * $bufferMultiplier, 2)
    $dataFits = $dataVolume.FreeGB -ge $dataRequiredWithBufferGB
    $logFits = $logVolume.FreeGB -ge $logRequiredWithBufferGB
    $status = if ($dataFits -and $logFits) { 'Passed' } else { 'Failed' }
    $message = "Data requires $dataRequiredWithBufferGB GB including $BufferPercent% buffer; target has $($dataVolume.FreeGB) GB free. Log requires $logRequiredWithBufferGB GB including buffer; target has $($logVolume.FreeGB) GB free."

    [pscustomobject]@{
        Source = $Source
        Target = $Target
        Database = $Database
        Stage = 'CapacityPreflight'
        Status = $status
        DataFilesRequiredGB = $dataRequiredGB
        DataRequiredWithBufferGB = $dataRequiredWithBufferGB
        TargetDataPath = $targetPaths.Data
        TargetDataVolume = $dataVolume.Volume
        TargetDataCapacityGB = $dataVolume.CapacityGB
        TargetDataFreeGB = $dataVolume.FreeGB
        LogFilesRequiredGB = $logRequiredGB
        LogRequiredWithBufferGB = $logRequiredWithBufferGB
        TargetLogPath = $targetPaths.Log
        TargetLogVolume = $logVolume.Volume
        TargetLogCapacityGB = $logVolume.CapacityGB
        TargetLogFreeGB = $logVolume.FreeGB
        Message = $message
    }
}

function Get-MigrationServerObjectCounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SqlInstance
    )

    [pscustomobject]@{
        LoginCount = @(Get-DbaLogin -SqlInstance $SqlInstance -EnableException -ErrorAction Stop).Count
        LinkedServerCount = @(Get-DbaLinkedServer -SqlInstance $SqlInstance -EnableException -ErrorAction Stop).Count
        AgentJobCount = @(Get-DbaAgentJob -SqlInstance $SqlInstance -EnableException -ErrorAction Stop).Count
    }
}

function Get-MigrationDiscovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration
    )

    foreach ($pair in $Configuration.SourceTargets) {
        $migrationMode = if ($pair.Contains('MigrationMode')) { [string]$pair.MigrationMode } else { 'Full' }
        $sourceConnection = Connect-DbaInstance -SqlInstance $pair.Source -ErrorAction Stop
        $targetConnection = Connect-DbaInstance -SqlInstance $pair.Target -ErrorAction Stop
        $sourceDisks = @(Get-DbaDiskSpace -ComputerName $sourceConnection.ComputerName -Unit GB -EnableException -ErrorAction Stop)
        $targetDisks = @(Get-DbaDiskSpace -ComputerName $targetConnection.ComputerName -Unit GB -EnableException -ErrorAction Stop)
        $targetPaths = Get-DbaDefaultPath -SqlInstance $pair.Target -EnableException -ErrorAction Stop
        $targetDataVolume = Get-MigrationVolumeDetails -Path $targetPaths.Data -Disks $targetDisks
        $targetLogVolume = Get-MigrationVolumeDetails -Path $targetPaths.Log -Disks $targetDisks
        $serverObjectCounts = Get-MigrationServerObjectCounts -SqlInstance $pair.Source

        foreach ($database in (Get-MigrationDatabase -SqlInstance $pair.Source -Configuration $Configuration)) {
            $files = @(Get-DbaDbFile -SqlInstance $pair.Source -Database $database.Name -EnableException -ErrorAction Stop)
            $dataFiles = @($files | Where-Object TypeDescription -eq 'ROWS')
            $logFiles = @($files | Where-Object TypeDescription -eq 'LOG')
            $volumePaths = @($files | ForEach-Object { [System.IO.Path]::GetPathRoot($_.PhysicalName) } | Sort-Object -Unique)
            $sourceVolumeDetails = foreach ($volumePath in $volumePaths) {
                $volume = Get-MigrationVolumeDetails -Path $volumePath -Disks $sourceDisks
                if ($null -eq $volume.CapacityGB) {
                    "$($volume.Volume) (capacity/free space unavailable)"
                }
                else {
                    "$($volume.Volume) ($($volume.CapacityGB) GB total, $($volume.FreeGB) GB free, $($volume.PercentFree)% free)"
                }
            }
            $compatibility = [string]$database.Compatibility
            $compatibilityNumber = if ($compatibility -match '(\d+)$') { [int]$Matches[1] } else { $null }

            [pscustomobject]@{
                Source = $pair.Source
                Target = $pair.Target
                Database = $database.Name
                SizeMB = [math]::Round([double]$database.SizeMB, 2)
                SizeGB = [math]::Round([double]$database.SizeMB / 1024, 2)
                SourceLoginCount = $serverObjectCounts.LoginCount
                SourceLinkedServerCount = $serverObjectCounts.LinkedServerCount
                SourceAgentJobCount = $serverObjectCounts.AgentJobCount
                CompatibilityLevel = $compatibility
                CompatibilityLevelNumber = $compatibilityNumber
                State = $database.Status
                RecoveryModel = [string]$database.RecoveryModel
                DataFileCount = $dataFiles.Count
                LogFileCount = $logFiles.Count
                DataFileLocations = (@($dataFiles | ForEach-Object { "$($_.LogicalName): $($_.PhysicalName) ($($_.Size))" }) -join '; ')
                LogFileLocations = (@($logFiles | ForEach-Object { "$($_.LogicalName): $($_.PhysicalName) ($($_.Size))" }) -join '; ')
                SourceVolumeSpace = (@($sourceVolumeDetails) -join '; ')
                TargetDataPath = $targetPaths.Data
                TargetDataVolume = $targetDataVolume.Volume
                TargetDataCapacityGB = $targetDataVolume.CapacityGB
                TargetDataFreeGB = $targetDataVolume.FreeGB
                TargetDataPercentFree = $targetDataVolume.PercentFree
                TargetLogPath = $targetPaths.Log
                TargetLogVolume = $targetLogVolume.Volume
                TargetLogCapacityGB = $targetLogVolume.CapacityGB
                TargetLogFreeGB = $targetLogVolume.FreeGB
                TargetLogPercentFree = $targetLogVolume.PercentFree
                TargetCapacityPreflight = if ($migrationMode -eq 'SchemaOnly') {
                    'NotRequired'
                } else {
                    (Test-MigrationRestoreCapacity -Source $pair.Source -Target $pair.Target -Database $database.Name -BufferPercent $(if ($Configuration.Contains('RestoreSpaceBufferPercent')) { [double]$Configuration.RestoreSpaceBufferPercent } else { 20 })).Status
                }
                Status = 'Discovered'
            }
        }
    }
}

function Test-MigrationConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration
    )

    if (-not (Get-Module -Name dbatools)) {
        try {
            Import-Module dbatools -ErrorAction Stop
        }
        catch {
            throw "The dbatools module is required. Install it with Install-Module dbatools. $($_.Exception.Message)"
        }
    }

    foreach ($pair in $Configuration.SourceTargets) {
        $migrationMode = if ($pair.Contains('MigrationMode')) { [string]$pair.MigrationMode } else { 'Full' }
        foreach ($endpoint in @(
            @{ Role = 'Source'; Name = $pair.Source; AllowedVersions = @(11, 13, 15) },
            @{ Role = 'Target'; Name = $pair.Target; AllowedVersions = @(16) }
        )) {
            try {
                $instance = Connect-DbaInstance -SqlInstance $endpoint.Name -ErrorAction Stop
                $majorVersion = [int]$instance.VersionMajor
                $expectedVersions = $endpoint.AllowedVersions -join ', '
                if ($majorVersion -notin $endpoint.AllowedVersions) {
                    [pscustomobject]@{
                        Source = $pair.Source
                        Target = $pair.Target
                        Endpoint = $endpoint.Name
                        Role = $endpoint.Role
                        SqlVersionMajor = $majorVersion
                        Status = 'Failed'
                        Message = "Unsupported SQL Server version. Expected major version(s): $expectedVersions."
                    }
                }
                else {
                    [pscustomobject]@{
                        Source = $pair.Source
                        Target = $pair.Target
                        Endpoint = $endpoint.Name
                        Role = $endpoint.Role
                        SqlVersionMajor = $majorVersion
                        Status = 'Passed'
                        Message = 'Connection successful and SQL Server version is supported.'
                    }
                }
            }
            catch {
                [pscustomobject]@{
                    Source = $pair.Source
                    Target = $pair.Target
                    Endpoint = $endpoint.Name
                    Role = $endpoint.Role
                    SqlVersionMajor = $null
                    Status = 'Failed'
                    Message = $_.Exception.Message
                }
            }
        }
        if ($migrationMode -eq 'SchemaOnly') {
            [pscustomobject]@{
                Source = $pair.Source
                Target = $pair.Target
                Endpoint = $pair.BackupPath
                Role = 'BackupPath'
                SqlVersionMajor = $null
                Status = 'Skipped'
                Message = 'Backup-path validation is not required for schema-only migration.'
            }
            continue
        }
        try {
            $sourceCanSeeBackupPath = Test-DbaPath -SqlInstance $pair.Source -Path $pair.BackupPath -EnableException -ErrorAction Stop
            $targetCanSeeBackupPath = Test-DbaPath -SqlInstance $pair.Target -Path $pair.BackupPath -EnableException -ErrorAction Stop
            if ($sourceCanSeeBackupPath -and $targetCanSeeBackupPath) {
                [pscustomobject]@{
                    Source = $pair.Source
                    Target = $pair.Target
                    Endpoint = $pair.BackupPath
                    Role = 'BackupPath'
                    SqlVersionMajor = $null
                    Status = 'Passed'
                    Message = 'Backup path is visible to both SQL Server services.'
                }
            }
            else {
                [pscustomobject]@{
                    Source = $pair.Source
                    Target = $pair.Target
                    Endpoint = $pair.BackupPath
                    Role = 'BackupPath'
                    SqlVersionMajor = $null
                    Status = 'Failed'
                    Message = 'Backup path is not visible to both SQL Server services.'
                }
            }
        }
        catch {
            [pscustomobject]@{
                Source = $pair.Source
                Target = $pair.Target
                Endpoint = $pair.BackupPath
                Role = 'BackupPath'
                SqlVersionMajor = $null
                Status = 'Failed'
                Message = $_.Exception.Message
            }
        }
    }
}

Export-ModuleMember -Function Get-MigrationDiscovery, Get-MigrationServerObjectCounts, Test-MigrationRestoreCapacity, Test-MigrationConfiguration
