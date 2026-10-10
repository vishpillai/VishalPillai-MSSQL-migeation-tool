[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Discover', 'Validate', 'Migrate')]
    [string] $Mode = 'Discover',

    [Parameter()]
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config\migration.config.json'),

    [Parameter()]
    [string] $StatePath,

    [Parameter()]
    [string] $OutputPath,

    [Parameter()]
    [string] $ProgressPath,

    [Parameter()]
    [string] $ControlPath,

    [Parameter()]
    [switch] $SuppressOverallProgress
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleDirectory = Join-Path $PSScriptRoot 'src'
foreach ($moduleName in @(
    'DbMigration.Core.psm1',
    'DbMigration.Discovery.psm1',
    'DbMigration.Transfer.psm1',
    'DbMigration.PostMigration.psm1'
)) {
    Import-Module (Join-Path $moduleDirectory $moduleName) -Force
}
Import-Module dbatools -ErrorAction Stop

$configuration = Import-MigrationConfiguration -Path $ConfigPath
foreach ($property in @('OutputPath', 'LinkedServersCsv')) {
    if (-not [System.IO.Path]::IsPathRooted($configuration[$property])) {
        $configuration[$property] = Join-Path $PSScriptRoot $configuration[$property]
    }
}
foreach ($pair in $configuration.SourceTargets) {
    if (-not [System.IO.Path]::IsPathRooted($pair.BackupPath)) {
        $pair.BackupPath = Join-Path $PSScriptRoot $pair.BackupPath
    }
}
if (-not $StatePath) {
    $StatePath = Join-Path $PSScriptRoot 'MigrationState.json'
}
if (-not $OutputPath) {
    $OutputPath = $configuration.OutputPath
}

if ($Mode -eq 'Discover') {
    $results = @(Get-MigrationDiscovery -Configuration $configuration)
    $null = Write-MigrationReports -Rows $results -OutputPath $OutputPath -Name 'Discovery'
    $results
    return
}

if ($Mode -eq 'Validate') {
    $results = @(Test-MigrationConfiguration -Configuration $configuration)
    $null = Write-MigrationReports -Rows $results -OutputPath $OutputPath -Name 'Validation'
    $results
    if (@($results | Where-Object Status -eq 'Failed').Count -gt 0) {
        throw 'Migration validation failed. Review the generated reports before proceeding.'
    }
    return
}

if ($ProgressPath -and -not $SuppressOverallProgress) {
    $ProgressPath = [System.IO.Path]::GetFullPath($ProgressPath)
    $null = New-Item -ItemType Directory -Path $ProgressPath -Force -ErrorAction Stop
    Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source '' -Target '' `
        -Stage 'Migration' -Status 'Started' -Message 'Migration process started.'
}

$validation = @(Test-MigrationConfiguration -Configuration $configuration)
$null = Write-MigrationReports -Rows $validation -OutputPath $OutputPath -Name 'PreMigrationValidation'
$validation
if ($ProgressPath) {
    foreach ($validationResult in $validation) {
        $validationStatus = if ($validationResult.Status -eq 'Passed') { 'Completed' } else { 'Failed' }
        Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $validationResult.Source -Target $validationResult.Target `
            -Stage "Validation:$($validationResult.Role)" -Status $validationStatus -Message $validationResult.Message
    }
}
if (@($validation | Where-Object Status -eq 'Failed').Count -gt 0) {
    if ($ProgressPath -and -not $SuppressOverallProgress) {
        Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source '' -Target '' `
            -Stage 'Migration' -Status 'Failed' -Message 'Migration validation failed; no migration was started.'
    }
    throw 'Migration preflight validation failed. No migration was started.'
}

$migrationResults = [System.Collections.Generic.List[object]]::new()
foreach ($pair in $configuration.SourceTargets) {
    $pairResultStart = $migrationResults.Count
    $backupRoot = $pair.BackupPath
    $runBackupDirectory = Get-MigrationRunBackupDirectory -RootDirectory $backupRoot -Source $pair.Source -Target $pair.Target -RunId ([guid]::NewGuid())
    $databases = @()
    $pairResults = @()
    $previousBackupDirectories = [System.Collections.Generic.List[string]]::new()
    try {
        $databases = @(Get-MigrationDatabase -SqlInstance $pair.Source -Configuration $configuration)
        $targetPaths = Get-DbaDefaultPath -SqlInstance $pair.Target -EnableException -ErrorAction Stop
        $eligibleDatabases = [System.Collections.Generic.List[object]]::new()
        $migrationState = Get-MigrationState -Path $StatePath
        foreach ($database in $databases) {
            try {
                $stateKey = Get-MigrationStateKey -Source $pair.Source -Target $pair.Target -Database $database.Name
                $stateEntry = $migrationState.Databases[$stateKey]
                if ($stateEntry -and $stateEntry.BackupPath -and (Test-Path -LiteralPath $stateEntry.BackupPath -PathType Container)) {
                    $previousBackupDirectory = [System.IO.Path]::GetFullPath([string]$stateEntry.BackupPath)
                    $backupRootPath = [System.IO.Path]::GetFullPath($backupRoot).TrimEnd('\')
                    $previousParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $previousBackupDirectory)).TrimEnd('\')
                    if ($previousParent -ne $backupRootPath -and (Split-Path -Leaf $previousBackupDirectory).StartsWith('database-', [System.StringComparison]::OrdinalIgnoreCase)) {
                        $previousBackupDirectory = $previousParent
                        $previousParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $previousBackupDirectory)).TrimEnd('\')
                    }
                    if ($previousParent -eq $backupRootPath) {
                        $previousBackupDirectories.Add($previousBackupDirectory)
                    }
                }
                $targetExists = Test-MigrationDatabaseExists -SqlInstance $pair.Target -Database $database.Name
                $stateStatus = if ($stateEntry) { [string]$stateEntry.Status } else { '' }
                $targetDecision = Get-MigrationTargetDatabaseDecision -Database $database.Name `
                    -TargetExists $targetExists -StateStatus $stateStatus -Configuration $configuration
                if ($targetDecision -eq 'SkipRequested') {
                    $pairResults += [pscustomobject]@{
                        Source = $pair.Source; Target = $pair.Target; Database = $database.Name; Stage = 'Database'
                        Status = 'Skipped'; BackupPath = $null; Message = 'Overwrite declined in GUI; existing target database was left unchanged.'
                    }
                    if ($ProgressPath) {
                        Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                            -Database $database.Name -Stage 'Database' -Status 'Skipped' -Message 'Overwrite declined; existing target database left unchanged.'
                    }
                    continue
                }
                if ($targetDecision -eq 'SkipCompleted') {
                    $pairResults += [pscustomobject]@{
                        Source = $pair.Source; Target = $pair.Target; Database = $database.Name; Stage = 'Database'
                        Status = 'Skipped'; BackupPath = $stateEntry.BackupPath; Message = 'Completed state verified against accessible target database.'
                    }
                    if ($ProgressPath) {
                        Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                            -Database $database.Name -Stage 'Database' -Status 'Skipped' -Message 'Completed state verified against target database.'
                    }
                    continue
                }
                if ($targetDecision -eq 'Blocked') {
                    $migrationResults.Add([pscustomobject]@{
                        Source = $pair.Source; Target = $pair.Target; Database = $database.Name; Stage = 'TargetReplacementPreflight'
                        Status = 'Failed'; Message = 'Target database exists. Set AllowTargetReplace to true only after reviewing and approving replacement.'
                    })
                    if ($ProgressPath) {
                        Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                            -Database $database.Name -Stage 'TargetReplacementPreflight' -Status 'Failed' -Message 'Target database exists; replacement was not approved.'
                    }
                    continue
                }
                if ($ProgressPath) {
                    Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                        -Database $database.Name -Stage 'CapacityPreflight' -Status 'Started' -Message 'Checking target data and log capacity.'
                }
                $capacity = Test-MigrationRestoreCapacity -Source $pair.Source -Target $pair.Target -Database $database.Name -BufferPercent ([double]$configuration.RestoreSpaceBufferPercent)
                $migrationResults.Add($capacity)
                if ($ProgressPath) {
                    $capacityStatus = if ($capacity.Status -eq 'Passed') { 'Completed' } else { 'Failed' }
                    Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                        -Database $database.Name -Stage 'CapacityPreflight' -Status $capacityStatus -Message $capacity.Message
                }
                if ($capacity.Status -eq 'Passed') {
                    $eligibleDatabases.Add($database)
                }
            }
            catch {
                $migrationResults.Add([pscustomobject]@{
                    Source = $pair.Source; Target = $pair.Target; Database = $database.Name; Stage = 'CapacityPreflight'
                    Status = 'Failed'; Message = $_.Exception.Message
                })
                if ($ProgressPath) {
                    Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                        -Database $database.Name -Stage 'CapacityPreflight' -Status 'Failed' -Message $_.Exception.Message
                }
            }
        }
        if ($eligibleDatabases.Count -gt 0) {
            $pair.BackupPath = $runBackupDirectory
            if (-not (Test-Path -LiteralPath $runBackupDirectory -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $runBackupDirectory -Force -ErrorAction Stop
            }
            $pairResults += @(Invoke-DatabaseMigration -Pair $pair -Databases @($eligibleDatabases) `
                -StatePath $StatePath -ThrottleLimit $configuration.ThrottleLimit `
                -ModulePath (Join-Path $moduleDirectory 'DbMigration.Core.psm1') `
                -TransferModulePath (Join-Path $moduleDirectory 'DbMigration.Transfer.psm1') `
                -DestinationDataDirectory $targetPaths.Data -DestinationLogDirectory $targetPaths.Log `
                -BackupFileCount ([int]$configuration.BackupFileCount) `
                -OverwriteDatabases @($configuration.OverwriteExistingDatabases) `
                -AllowTargetReplace ([bool]$configuration.AllowTargetReplace) `
                -ProgressPath $ProgressPath -ControlPath $ControlPath)
        }
        foreach ($result in $pairResults) {
            $migrationResults.Add($result)
        }
    }
    catch {
        $migrationResults.Add([pscustomobject]@{
            Source = $pair.Source; Target = $pair.Target; Database = '*'; Stage = 'DatabaseMigration'
            Status = 'Failed'; BackupPath = $null; Message = $_.Exception.Message
        })
        if ($ProgressPath) {
            Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                -Database '*' -Stage 'DatabaseMigration' -Status 'Failed' -Message $_.Exception.Message
        }
    }

    $serverSteps = @()
    if ($configuration.MigrateLogins -or $configuration.MigrateAgentJobs -or $configuration.MigrateAgentOperators) {
        $serverSteps += @{
            Name = 'ServerObjects'
            Action = {
                Invoke-ServerObjectMigration -Pair $pair `
                    -MigrateLogins ([bool]$configuration.MigrateLogins) `
                    -MigrateAgentJobs ([bool]$configuration.MigrateAgentJobs) `
                    -MigrateAgentOperators ([bool]$configuration.MigrateAgentOperators)
            }
        }
    }
    if ($configuration.ConfigureLinkedServers) {
        $serverSteps += @{ Name = 'LinkedServers'; Action = { Invoke-LinkedServerConfiguration -Pair $pair -CsvPath $configuration.LinkedServersCsv } }
    }
    foreach ($serverStep in $serverSteps) {
        try {
            $null = Wait-MigrationControl -ControlPath $ControlPath -ProgressPath $ProgressPath `
                -Source $pair.Source -Target $pair.Target
            if ($ProgressPath) {
                Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                    -Database '*' -Stage $serverStep.Name -Status 'Started' -Message 'Server-object stage started.'
            }
            & $serverStep.Action | ForEach-Object {
                $serverObject = $_
                if ($ProgressPath -and $serverObject.PSObject.Properties.Name -contains 'Status') {
                    $objectStatus = [string]$serverObject.Status
                    $eventStatus = if ($objectStatus -match '^(Successful|Completed)$') {
                        'Completed'
                    }
                    elseif ($objectStatus -match '^(Failed|No matching login)$') {
                        'Failed'
                    }
                    elseif ($objectStatus -eq 'Skipped') {
                        'Skipped'
                    }
                    else {
                        'InProgress'
                    }
                    $objectName = if ($serverObject.PSObject.Properties.Name -contains 'Name') { [string]$serverObject.Name } else { '' }
                    $objectType = if ($serverObject.PSObject.Properties.Name -contains 'Type') { [string]$serverObject.Type } else { '' }
                    $objectMessage = if ($serverObject.PSObject.Properties.Name -contains 'Notes') { [string]$serverObject.Notes } else { '' }
                    if ($objectStatus -notin @('Successful', 'Completed', 'Failed', 'Skipped')) {
                        $objectMessage = (@($objectStatus, $objectMessage) | Where-Object { $_ }) -join '; '
                    }
                    Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                        -Database '*' -Stage "$($serverStep.Name):$objectType" -Status $eventStatus `
                        -Message ((@($objectName, $objectMessage) | Where-Object { $_ }) -join ': ')
                }
                $serverObject
            }
            $migrationResults.Add([pscustomobject]@{
                Source = $pair.Source; Target = $pair.Target; Database = '*'; Stage = $serverStep.Name
                Status = 'Completed'; BackupPath = $null; Message = 'Operation completed.'
            })
            if ($ProgressPath) {
                Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                    -Database '*' -Stage $serverStep.Name -Status 'Completed' -Message 'Server-object stage completed.'
            }
        }
        catch {
            $migrationResults.Add([pscustomobject]@{
                Source = $pair.Source; Target = $pair.Target; Database = '*'; Stage = $serverStep.Name
                Status = 'Failed'; BackupPath = $null; Message = $_.Exception.Message
            })
            if ($ProgressPath) {
                Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                    -Database '*' -Stage $serverStep.Name -Status 'Failed' -Message $_.Exception.Message
            }
        }
    }

    foreach ($databaseResult in @($pairResults | Where-Object Status -eq 'Completed')) {
        try {
            $null = Wait-MigrationControl -ControlPath $ControlPath -ProgressPath $ProgressPath `
                -Source $pair.Source -Target $pair.Target -Database $databaseResult.Database
            if ($ProgressPath) {
                Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                    -Database $databaseResult.Database -Stage 'PostMigration' -Status 'Started' -Message 'Post-migration actions started.'
            }
            Invoke-DatabasePostMigration -SqlInstance $pair.Target -Database $databaseResult.Database `
                -UpdateStatistics ([bool]$configuration.UpdateStatistics) `
                -RepairOrphanUsers ([bool]$configuration.RepairOrphanUsers)
            $migrationResults.Add([pscustomobject]@{
                Source = $pair.Source; Target = $pair.Target; Database = $databaseResult.Database; Stage = 'PostMigration'
                Status = 'Completed'; BackupPath = $databaseResult.BackupPath; Message = 'Configured post-migration actions completed.'
            })
            if ($ProgressPath) {
                Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                    -Database $databaseResult.Database -Stage 'PostMigration' -Status 'Completed' -Message 'Post-migration actions completed.'
            }
        }
        catch {
            $migrationResults.Add([pscustomobject]@{
                Source = $pair.Source; Target = $pair.Target; Database = $databaseResult.Database; Stage = 'PostMigration'
                Status = 'Failed'; BackupPath = $databaseResult.BackupPath; Message = $_.Exception.Message
            })
            if ($ProgressPath) {
                Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                    -Database $databaseResult.Database -Stage 'PostMigration' -Status 'Failed' -Message $_.Exception.Message
            }
        }
    }

    if ($ProgressPath) {
        foreach ($database in $databases) {
            $databaseName = [string]$database.Name
            $databaseRows = @($migrationResults | Select-Object -Skip $pairResultStart | Where-Object Database -eq $databaseName)
            $failure = @($databaseRows | Where-Object Status -eq 'Failed' | Select-Object -Last 1)
            $skipped = @($databaseRows | Where-Object { $_.Status -eq 'Skipped' -and $_.Stage -eq 'Database' })
            if ($failure.Count -gt 0) {
                Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                    -Database $databaseName -Stage 'DatabaseOutcome' -Status 'Failed' -Message $failure[0].Message
            }
            elseif ($skipped.Count -gt 0) {
                Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                    -Database $databaseName -Stage 'DatabaseOutcome' -Status 'Skipped' -Message $skipped[0].Message
            }
            else {
                Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                    -Database $databaseName -Stage 'DatabaseOutcome' -Status 'Completed' -Message 'All enabled database stages completed.'
            }
        }
    }

    $pairFailures = @($migrationResults | Select-Object -Skip $pairResultStart | Where-Object Status -eq 'Failed')
    if ($pairFailures.Count -eq 0) {
        $safeSourceName = [regex]::Replace($pair.Source, '[^A-Za-z0-9._-]', '_').TrimEnd([char[]]@('.', ' '))
        $safeTargetName = [regex]::Replace($pair.Target, '[^A-Za-z0-9._-]', '_').TrimEnd([char[]]@('.', ' '))
        if ([string]::IsNullOrWhiteSpace($safeSourceName)) { $safeSourceName = 'source' }
        if ([string]::IsNullOrWhiteSpace($safeTargetName)) { $safeTargetName = 'target' }
        $expectedFolderPrefix = "migration-$safeSourceName-to-$safeTargetName-"
        $backupRootFullPath = [System.IO.Path]::GetFullPath($backupRoot).TrimEnd('\')
        $backupDirectoriesToRemove = [System.Collections.Generic.List[string]]::new()
        $backupDirectoriesToRemove.Add($runBackupDirectory)
        foreach ($previousBackupDirectory in $previousBackupDirectories) {
            $backupDirectoriesToRemove.Add($previousBackupDirectory)
        }
        foreach ($result in $pairResults) {
            if (-not $result.BackupPath -or -not (Test-Path -LiteralPath $result.BackupPath -PathType Container)) {
                continue
            }
            $candidate = [System.IO.Path]::GetFullPath($result.BackupPath)
            $candidateParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $candidate)).TrimEnd('\')
            $candidateLeaf = Split-Path -Leaf $candidate
            if ($candidateParent -eq $backupRootFullPath -and
                $candidateLeaf.StartsWith($expectedFolderPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
                $candidateLeaf -match '^migration-.+-to-.+-[a-f0-9]{32}$') {
                $backupDirectoriesToRemove.Add($candidate)
            }
        }
        foreach ($backupDirectory in @($backupDirectoriesToRemove | Sort-Object -Unique)) {
            try {
                $null = Wait-MigrationControl -ControlPath $ControlPath -ProgressPath $ProgressPath `
                    -Source $pair.Source -Target $pair.Target
                if ($ProgressPath) {
                    Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                        -Database '*' -Stage 'BackupCleanup' -Status 'Started' -Message 'Cleaning successful temporary backup folders.'
                }
                $removed = Remove-MigrationRunBackupDirectory -RootDirectory $backupRoot -Directory $backupDirectory -Source $pair.Source -Target $pair.Target -ErrorAction Stop
                if ($removed) {
                    $removedPath = [System.IO.Path]::GetFullPath($backupDirectory).TrimEnd('\') + '\'
                    foreach ($databaseResult in @($pairResults | Where-Object { $_.Database -and $_.Database -ne '*' -and $_.BackupPath })) {
                        $databaseBackupPath = [System.IO.Path]::GetFullPath($databaseResult.BackupPath)
                        if ($databaseBackupPath.TrimEnd('\').Equals($removedPath.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) -or
                            $databaseBackupPath.StartsWith($removedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                            Set-MigrationState -Path $StatePath -Source $pair.Source -Target $pair.Target `
                                -Database $databaseResult.Database -Status Completed -BackupPath ''
                        }
                    }
                    $migrationResults.Add([pscustomobject]@{
                        Source = $pair.Source; Target = $pair.Target; Database = '*'; Stage = 'BackupCleanup'
                        Status = 'Completed'; BackupPath = $backupDirectory; Message = 'Temporary striped backup folder deleted after successful migration.'
                    })
                    if ($ProgressPath) {
                        Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                            -Database '*' -Stage 'BackupCleanup' -Status 'Completed' -Message 'Temporary backup folder deleted.'
                    }
                }
            }
            catch {
                $migrationResults.Add([pscustomobject]@{
                    Source = $pair.Source; Target = $pair.Target; Database = '*'; Stage = 'BackupCleanup'
                    Status = 'Failed'; BackupPath = $backupDirectory; Message = "Migration succeeded, but temporary backup folder cleanup failed: $($_.Exception.Message)"
                })
                if ($ProgressPath) {
                    Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $pair.Source -Target $pair.Target `
                        -Database '*' -Stage 'BackupCleanup' -Status 'Failed' -Message $_.Exception.Message
                }
            }
        }
    }
}

$null = Write-MigrationReports -Rows @($migrationResults) -OutputPath $OutputPath -Name 'Migration'
$migrationResults
$migrationFailed = @($migrationResults | Where-Object Status -eq 'Failed').Count -gt 0
if ($ProgressPath -and -not $SuppressOverallProgress) {
    $finalStatus = if ($migrationFailed) { 'Failed' } else { 'Completed' }
    Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source '' -Target '' `
        -Stage 'Migration' -Status $finalStatus -Message "Migration finished with status $finalStatus."
}
if ($migrationFailed) {
    throw 'One or more database migrations failed. Review the generated migration reports and MigrationState.json.'
}
