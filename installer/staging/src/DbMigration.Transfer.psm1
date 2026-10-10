Set-StrictMode -Version Latest

function Invoke-MigrationTrackedDatabaseOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Backup', 'Restore')][string] $Operation,
        [Parameter(Mandatory)][string] $SqlInstance,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][string] $Database,
        [Parameter(Mandatory)][AllowEmptyString()][string] $ProgressPath,
        [Parameter()][string] $BackupDirectory = '',
        [Parameter()][int] $BackupFileCount = 4,
        [Parameter()][string[]] $BackupFiles = @(),
        [Parameter()][string] $DestinationDataDirectory = '',
        [Parameter()][string] $DestinationLogDirectory = ''
    )

    $job = Start-Job -Name "$Operation-$Database" -ArgumentList @(
        $Operation, $SqlInstance, $Database, $BackupDirectory, $BackupFileCount,
        (ConvertTo-Json -InputObject $BackupFiles -Compress),
        $DestinationDataDirectory, $DestinationLogDirectory
    ) -ScriptBlock {
        param(
            [string]$JobOperation,
            [string]$JobSqlInstance,
            [string]$JobDatabase,
            [string]$JobBackupDirectory,
            [int]$JobBackupFileCount,
            [string]$JobBackupFilesJson,
            [string]$JobDestinationDataDirectory,
            [string]$JobDestinationLogDirectory
        )

        Import-Module dbatools -ErrorAction Stop
        if ($JobOperation -eq 'Backup') {
            Backup-DbaDatabase -SqlInstance $JobSqlInstance -Database $JobDatabase `
                -Path $JobBackupDirectory -FileCount $JobBackupFileCount `
                -Type Full -CopyOnly -Checksum -CompressBackup -Verify `
                -EnableException -ErrorAction Stop -WarningAction Stop | Out-Null
            return
        }

        $jobBackupFiles = @(ConvertFrom-Json -InputObject $JobBackupFilesJson -ErrorAction Stop)
        Restore-DbaDatabase -SqlInstance $JobSqlInstance -Path $jobBackupFiles `
            -DatabaseName $JobDatabase -DestinationDataDirectory $JobDestinationDataDirectory `
            -DestinationLogDirectory $JobDestinationLogDirectory `
            -WithReplace -EnableException -ErrorAction Stop -WarningAction Stop | Out-Null
    }

    $escapedDatabase = $Database.Replace("'", "''")
    $progressQuery = @"
SELECT TOP (1)
    CONVERT(int, percent_complete) AS PercentComplete,
    CONVERT(bigint, cpu_time) AS CpuTimeMilliseconds,
    CONVERT(bigint, total_elapsed_time) AS ElapsedMilliseconds
FROM sys.dm_exec_requests
WHERE database_id = DB_ID(N'$escapedDatabase')
  AND (command LIKE 'BACKUP%' OR command LIKE 'RESTORE%')
ORDER BY start_time DESC;
"@
    $lastProgressAt = [DateTime]::MinValue
    $lastHeartbeatAt = [DateTime]::UtcNow
    $lastPercentComplete = -1
    $progressQueryFailed = $false

    try {
        while ($job.State -in @('NotStarted', 'Running')) {
            $now = [DateTime]::UtcNow
            if ($ProgressPath -and -not $progressQueryFailed -and ($now - $lastProgressAt).TotalSeconds -ge 2) {
                $lastProgressAt = $now
                try {
                    $operationProgress = Invoke-DbaQuery -SqlInstance $SqlInstance -Database master `
                        -Query $progressQuery -EnableException -ErrorAction Stop | Select-Object -First 1
                    if ($operationProgress) {
                        $percentComplete = [int]$operationProgress.PercentComplete
                        if ($percentComplete -ne $lastPercentComplete) {
                            $lastPercentComplete = $percentComplete
                            $cpuSeconds = [math]::Round(([double]$operationProgress.CpuTimeMilliseconds / 1000), 1)
                            $elapsedSeconds = [math]::Round(([double]$operationProgress.ElapsedMilliseconds / 1000), 1)
                            Write-MigrationProgressEvent -ProgressPath $ProgressPath `
                                -Source $Source -Target $Target -Database $Database -Stage $Operation `
                                -Status 'InProgress' -PercentComplete $percentComplete `
                                -Message ("SQL Server reports {0} progress; request CPU {1}s, elapsed {2}s." -f `
                                    $Operation.ToLowerInvariant(), $cpuSeconds, $elapsedSeconds)
                        }
                    }
                }
                catch {
                    $progressQueryFailed = $true
                    Write-MigrationProgressEvent -ProgressPath $ProgressPath `
                        -Source $Source -Target $Target -Database $Database -Stage $Operation `
                        -Status 'InProgress' -PercentComplete $lastPercentComplete `
                        -Message "SQL operation continues; live percentage is unavailable because its progress query failed: $($_.Exception.Message)"
                }
            }
            $null = Wait-Job -Job $job -Timeout 1
            if ($ProgressPath -and ($now - $lastHeartbeatAt).TotalSeconds -ge 10) {
                Write-MigrationProgressEvent -ProgressPath $ProgressPath `
                    -Source $Source -Target $Target -Database $Database -Stage $Operation `
                    -Status 'InProgress' -PercentComplete $lastPercentComplete `
                    -Message "$Operation is still running; waiting for SQL Server progress."
                $lastHeartbeatAt = [DateTime]::UtcNow
            }
        }

        if ($job.State -ne 'Completed') {
            $jobError = $job.ChildJobs[0].JobStateInfo.Reason
            if ($jobError) {
                throw $jobError
            }
            throw "$Operation job ended in state '$($job.State)'."
        }
        $null = Receive-Job -Job $job -ErrorAction Stop
    }
    finally {
        if ($job.State -in @('NotStarted', 'Running')) {
            $null = Wait-Job -Job $job
        }
        Remove-Job -Job $job -Force -ErrorAction Stop
    }
}

function Invoke-DatabaseMigration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Pair,
        [Parameter(Mandatory)][object[]] $Databases,
        [Parameter(Mandatory)][string] $StatePath,
        [Parameter(Mandatory)][ValidateRange(1, 128)][int] $ThrottleLimit,
        [Parameter(Mandatory)][string] $ModulePath,
        [Parameter(Mandatory)][string] $TransferModulePath,
        [Parameter(Mandatory)][string] $DestinationDataDirectory,
        [Parameter(Mandatory)][string] $DestinationLogDirectory,
        [Parameter(Mandatory)][ValidateRange(1, 32)][int] $BackupFileCount,
        [Parameter()][string[]] $OverwriteDatabases = @(),
        [Parameter()][bool] $AllowTargetReplace = $false,
        [Parameter()][string] $ProgressPath = '',
        [Parameter()][string] $ControlPath = ''
    )

    $databaseNames = @($Databases | ForEach-Object { $_.Name })
    if ($databaseNames.Count -eq 0) {
        return
    }

    $databaseNames | ForEach-Object -Parallel {
        Import-Module $using:ModulePath -Force
        Import-Module $using:TransferModulePath -Force
        Import-Module dbatools -ErrorAction Stop
        $source = $using:Pair.Source
        $target = $using:Pair.Target
        $database = $_
        $statePath = $using:StatePath
        $runBackupDirectory = $using:Pair.BackupPath
        $destinationDataDirectory = $using:DestinationDataDirectory
        $destinationLogDirectory = $using:DestinationLogDirectory
        $backupFileCount = $using:BackupFileCount
        $progressPath = $using:ProgressPath
        $controlPath = $using:ControlPath
        $databaseBackupDirectory = Get-MigrationDatabaseBackupDirectory -RunDirectory $runBackupDirectory `
            -Source $source -Target $target -Database $database
        $backupPath = $databaseBackupDirectory
        $backupCompleted = $false
        try {
            $null = Wait-MigrationControl -ControlPath $controlPath -ProgressPath $progressPath `
                -Source $source -Target $target -Database $database
            $state = Get-MigrationState -Path $statePath
            $stateKey = Get-MigrationStateKey -Source $source -Target $target -Database $database
            $entry = $state.Databases[$stateKey]
            $completedStateNeedsRepair = $false
            if ($entry -and $entry.Status -eq 'Completed') {
                $overwriteApproved = $using:AllowTargetReplace -or $database -in $using:OverwriteDatabases
                if ((Test-MigrationDatabaseExists -SqlInstance $target -Database $database) -and -not $overwriteApproved) {
                    [pscustomobject]@{ Source = $source; Target = $target; Database = $database; Stage = 'Database'; Status = 'Skipped'; BackupPath = $entry.BackupPath; Message = 'Already completed and present on target.' }
                    return
                }

                $completedStateNeedsRepair = $true
            }

            $backupIsReusable = $false
            $stripeFiles = @()
            if ($entry -and $entry.Status -in @('BackupCompleted', 'Completed') -and $entry.BackupPath) {
                if (Test-Path -LiteralPath $entry.BackupPath -PathType Leaf) {
                    $backupPath = $entry.BackupPath
                    $backupIsReusable = $true
                }
                elseif (Test-Path -LiteralPath $entry.BackupPath -PathType Container) {
                    $stripeFiles = @(Get-MigrationBackupStripeFiles -Directory $entry.BackupPath `
                        -Database $database -FileCount $backupFileCount)
                    $backupPath = $entry.BackupPath
                    $backupIsReusable = $stripeFiles.Count -eq $backupFileCount
                }
            }
            if ($backupIsReusable) {
                $backupCompleted = $true
                if ($progressPath) {
                    Write-MigrationProgressEvent -ProgressPath $progressPath -Source $source -Target $target `
                        -Database $database -Stage 'Backup' -Status 'Completed' -Message 'Reusing verified backup stripes.'
                }
            }
            else {
                $backupPath = $databaseBackupDirectory
                if (-not (Test-Path -LiteralPath $databaseBackupDirectory -PathType Container)) {
                    $null = New-Item -ItemType Directory -Path $databaseBackupDirectory -Force
                }
                if ($progressPath) {
                    Write-MigrationProgressEvent -ProgressPath $progressPath -Source $source -Target $target `
                        -Database $database -Stage 'Backup' -Status 'Started' -Message "Creating $backupFileCount verified backup stripes."
                }
                Invoke-MigrationTrackedDatabaseOperation -Operation Backup -SqlInstance $source `
                    -Source $source -Target $target -Database $database -ProgressPath $progressPath -BackupDirectory $databaseBackupDirectory `
                    -BackupFileCount $backupFileCount
                $stripeFiles = @(Get-MigrationBackupStripeFiles -Directory $databaseBackupDirectory `
                    -Database $database -FileCount $backupFileCount)
                if ($stripeFiles.Count -ne $backupFileCount) {
                    $totalBackupFiles = @(Get-ChildItem -LiteralPath $databaseBackupDirectory -Filter '*.bak' -File).Count
                    throw "Backup for '$database' did not produce exactly $backupFileCount valid stripe files in '$databaseBackupDirectory'; found $($stripeFiles.Count) valid stripe file(s) among $totalBackupFiles backup file(s)."
                }
                Set-MigrationState -Path $statePath -Source $source -Target $target -Database $database -Status BackupCompleted -BackupPath $backupPath
                $backupCompleted = $true
                if ($progressPath) {
                    Write-MigrationProgressEvent -ProgressPath $progressPath -Source $source -Target $target `
                        -Database $database -Stage 'Backup' -Status 'Completed' -Message "Verified $backupFileCount backup stripes."
                }
            }

            if (Test-Path -LiteralPath $backupPath -PathType Container) {
                $restoreFiles = @($stripeFiles | ForEach-Object FullName)
                if ($restoreFiles.Count -ne $backupFileCount) {
                    throw "Cannot restore '$database': expected $backupFileCount isolated stripe files in '$backupPath', found $($restoreFiles.Count)."
                }
            }
            else {
                $restoreFiles = @($backupPath)
            }
            $null = Wait-MigrationControl -ControlPath $controlPath -ProgressPath $progressPath `
                -Source $source -Target $target -Database $database
            if ($progressPath) {
                Write-MigrationProgressEvent -ProgressPath $progressPath -Source $source -Target $target `
                    -Database $database -Stage 'Restore' -Status 'Started' -Message 'Restoring database to target.'
            }
            Invoke-MigrationTrackedDatabaseOperation -Operation Restore -SqlInstance $target `
                -Source $source -Target $target -Database $database -ProgressPath $progressPath -BackupFiles $restoreFiles `
                -DestinationDataDirectory $destinationDataDirectory `
                -DestinationLogDirectory $destinationLogDirectory
            if (-not (Test-MigrationDatabaseExists -SqlInstance $target -Database $database)) {
                throw "Restore completed without making database '$database' visible on target '$target'."
            }
            Set-MigrationState -Path $statePath -Source $source -Target $target -Database $database -Status Completed -BackupPath $backupPath
            $message = if ($completedStateNeedsRepair) { 'Target database was missing; restored from backup.' } else { 'Backup and restore completed.' }
            if ($progressPath) {
                Write-MigrationProgressEvent -ProgressPath $progressPath -Source $source -Target $target `
                    -Database $database -Stage 'Restore' -Status 'Completed' -Message 'Target database is online and accessible.'
            }
            [pscustomobject]@{ Source = $source; Target = $target; Database = $database; Stage = 'Database'; Status = 'Completed'; BackupPath = $backupPath; Message = $message }
        }
        catch {
            $migrationError = $_.Exception.Message
            try {
                $stateStatus = if ($backupCompleted) { 'BackupCompleted' } else { 'Failed' }
                Set-MigrationState -Path $statePath -Source $source -Target $target -Database $database -Status $stateStatus -BackupPath $backupPath -ErrorMessage $migrationError
            }
            catch {
                Write-Error "Migration failed and state could not be recorded for $source/$database -> $target`: $($_.Exception.Message)"
            }
            if ($progressPath) {
                Write-MigrationProgressEvent -ProgressPath $progressPath -Source $source -Target $target `
                    -Database $database -Stage 'Database' -Status 'Failed' -Message $migrationError
            }
            [pscustomobject]@{ Source = $source; Target = $target; Database = $database; Stage = 'Database'; Status = 'Failed'; BackupPath = $backupPath; Message = $migrationError }
        }
    } -ThrottleLimit $ThrottleLimit
}

function Invoke-DatabaseSchemaOnlyMigration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Pair,
        [Parameter(Mandatory)][string] $Database,
        [Parameter(Mandatory)][bool] $Overwrite,
        [Parameter()][string] $ProgressPath = '',
        [Parameter()][string] $ControlPath = ''
    )

    $emit = {
        param([string]$Stage, [string]$Status, [int]$Percent, [string]$Message)
        if ($ProgressPath) {
            Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $Pair.Source -Target $Pair.Target `
                -Database $Database -Stage $Stage -Status $Status -PercentComplete $Percent -Message $Message
        }
    }

    try {
        $null = & $emit 'SchemaTransfer' 'Started' 0 'Preparing a schema-only database transfer; table data will not be copied.'
        if (-not (Wait-MigrationControl -ControlPath $ControlPath -ProgressPath $ProgressPath `
                -Source $Pair.Source -Target $Pair.Target -Database $Database -HonorStop)) {
            return [pscustomobject]@{
                Source = $Pair.Source; Target = $Pair.Target; Database = $Database; Stage = 'SchemaTransfer'
                Status = 'Stopped'; BackupPath = $null; Message = 'Stopped before schema changes began.'
            }
        }

        $sourceServer = Connect-DbaInstance -SqlInstance $Pair.Source -ErrorAction Stop
        $sourceDatabase = Get-DbaDatabase -SqlInstance $sourceServer -Database $Database -EnableException -ErrorAction Stop |
            Select-Object -First 1
        if (-not $sourceDatabase -or $sourceDatabase.Status -ne 'Normal') {
            throw "Source database '$Database' is missing or not online on '$($Pair.Source)'."
        }
        $null = & $emit 'SchemaTransfer' 'InProgress' 10 'Connected to the source and verified that the database is online.'

        $destinationServer = Connect-DbaInstance -SqlInstance $Pair.Target -ErrorAction Stop
        $destinationDatabase = Get-DbaDatabase -SqlInstance $destinationServer -Database $Database -EnableException -ErrorAction Stop |
            Select-Object -First 1
        if ($destinationDatabase -and -not $Overwrite) {
            $message = 'Target database already exists; schema-only replacement was not approved, so it was left unchanged.'
            $null = & $emit 'SchemaTransfer' 'Skipped' 100 $message
            return [pscustomobject]@{
                Source = $Pair.Source; Target = $Pair.Target; Database = $Database; Stage = 'SchemaTransfer'
                Status = 'Skipped'; BackupPath = $null; Message = $message
            }
        }

        $transfer = [Microsoft.SqlServer.Management.Smo.Transfer]::new($sourceDatabase)
        $transfer.DestinationServerConnection = $destinationServer.ConnectionContext.Copy()
        $transfer.DestinationDatabase = $Database
        $transfer.CreateTargetDatabase = $false
        $transfer.CopySchema = $true
        $transfer.CopyData = $false
        $transfer.CopyAllObjects = $true
        $transfer.CopyAllSchemas = $true
        $transfer.CopyAllUsers = $true
        $transfer.CopyAllRoles = $true
        $transfer.CopyAllLogins = $false
        $transfer.CopyAllDatabaseTriggers = $true
        $transfer.DropDestinationObjectsFirst = $false
        $transfer.Options.DriAll = $true
        $transfer.Options.Indexes = $true
        $transfer.Options.Triggers = $true
        $transfer.Options.FullTextCatalogs = $true
        $transfer.Options.FullTextIndexes = $true
        $transfer.Options.FullTextStopLists = $true
        $transfer.Options.Permissions = $true
        $transfer.Options.WithDependencies = $true
        $null = $transfer.ScriptTransfer()
        $null = & $emit 'SchemaTransfer' 'InProgress' 30 'Schema scripting preflight completed; no data-copy operation is enabled.'

        if (-not (Wait-MigrationControl -ControlPath $ControlPath -ProgressPath $ProgressPath `
                -Source $Pair.Source -Target $Pair.Target -Database $Database -HonorStop)) {
            return [pscustomobject]@{
                Source = $Pair.Source; Target = $Pair.Target; Database = $Database; Stage = 'SchemaTransfer'
                Status = 'Stopped'; BackupPath = $null; Message = 'Stopped before target database replacement began.'
            }
        }

        if ($destinationDatabase) {
            $null = & $emit 'SchemaTransfer' 'InProgress' 40 'Explicit overwrite approved; removing the existing target database before recreating schema only.'
            Remove-DbaDatabase -SqlInstance $destinationServer -Database $Database -Confirm:$false -EnableException -ErrorAction Stop
        }
        $null = New-DbaDatabase -SqlInstance $destinationServer -Name $Database `
            -Collation $sourceDatabase.Collation -RecoveryModel $sourceDatabase.RecoveryModel `
            -EnableException -ErrorAction Stop
        $null = & $emit 'SchemaTransfer' 'InProgress' 55 'Created an empty target database; applying schema without table data.'

        $null = $transfer.TransferData()
        $null = & $emit 'SchemaTransfer' 'InProgress' 90 'Schema transfer completed; verifying target accessibility and absence of table rows.'
        $targetDatabase = Get-DbaDatabase -SqlInstance $destinationServer -Database $Database -EnableException -ErrorAction Stop |
            Select-Object -First 1
        if (-not $targetDatabase -or $targetDatabase.Status -ne 'Normal') {
            throw "Schema transfer did not leave '$Database' online and accessible on '$($Pair.Target)'."
        }
        $verification = Invoke-DbaQuery -SqlInstance $destinationServer -Database $Database `
            -Query @'
SELECT COALESCE(SUM(CONVERT(bigint, p.rows)), 0) AS UserTableRows
FROM sys.tables AS t
JOIN sys.partitions AS p ON p.object_id = t.object_id
WHERE p.index_id IN (0, 1);
'@ -EnableException -ErrorAction Stop | Select-Object -Last 1
        if (-not $verification -or [long]$verification.UserTableRows -ne 0) {
            throw "Schema-only verification found table rows in '$Database' on '$($Pair.Target)'."
        }
        $objectCount = Invoke-DbaQuery -SqlInstance $destinationServer -Database $Database `
            -Query "SELECT COUNT_BIG(*) AS SchemaObjectCount FROM sys.objects WHERE is_ms_shipped = 0;" `
            -EnableException -ErrorAction Stop | Select-Object -Last 1
        $message = "Schema-only transfer completed; copied schema objects without table data. Verified $($objectCount.SchemaObjectCount) user objects and zero user-table rows."
        $null = & $emit 'SchemaTransfer' 'Completed' 100 $message
        [pscustomobject]@{
            Source = $Pair.Source; Target = $Pair.Target; Database = $Database; Stage = 'SchemaTransfer'
            Status = 'Completed'; BackupPath = $null; Message = $message
        }
    }
    catch {
        $message = $_.Exception.Message
        $null = & $emit 'SchemaTransfer' 'Failed' 100 $message
        [pscustomobject]@{
            Source = $Pair.Source; Target = $Pair.Target; Database = $Database; Stage = 'SchemaTransfer'
            Status = 'Failed'; BackupPath = $null; Message = $message
        }
    }
}

Export-ModuleMember -Function Invoke-MigrationTrackedDatabaseOperation, Invoke-DatabaseMigration, Invoke-DatabaseSchemaOnlyMigration
