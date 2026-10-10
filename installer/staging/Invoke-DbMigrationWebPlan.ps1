[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PlanPath,
    [Parameter(Mandatory)][string] $ProgressPath,
    [Parameter(Mandatory)][string] $StatePath,
    [Parameter(Mandatory)][string] $ControlPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fullPlanPath = [System.IO.Path]::GetFullPath($PlanPath)
$fullProgressPath = [System.IO.Path]::GetFullPath($ProgressPath)
$fullStatePath = [System.IO.Path]::GetFullPath($StatePath)
$fullControlPath = [System.IO.Path]::GetFullPath($ControlPath)
$moduleDirectory = Join-Path $PSScriptRoot 'src'
Import-Module (Join-Path $moduleDirectory 'DbMigration.Core.psm1') -Force
Import-Module (Join-Path $moduleDirectory 'DbMigration.Discovery.psm1') -Force
Import-Module (Join-Path $moduleDirectory 'DbMigration.Transfer.psm1') -Force
Import-Module dbatools -ErrorAction Stop

$plan = Get-Content -LiteralPath $fullPlanPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
if (-not $plan.Contains('Configuration') -or -not $plan.Contains('Pairs') -or -not $plan.Contains('Options')) {
    throw 'Migration plan is missing Configuration, Pairs, or Options.'
}
if (@($plan.Pairs).Count -lt 1 -or @($plan.Pairs).Count -gt 3) {
    throw 'A browser migration plan must contain between one and three source/target pairs.'
}
foreach ($pairPlan in $plan.Pairs) {
    if (-not $pairPlan.Contains('MigrationMode')) {
        $pairPlan.MigrationMode = 'Full'
    }
    if ([string]$pairPlan.MigrationMode -notin @('Full', 'SchemaOnly')) {
        throw "Unsupported migration mode '$($pairPlan.MigrationMode)'."
    }
}
if (-not $plan.Options.Contains('SkipLinkedServers')) {
    $plan.Options.SkipLinkedServers = $false
}

$configuration = $plan.Configuration
$configuration.SourceTargets = @($plan.Pairs | ForEach-Object {
    @{
        Source = [string]$_.Source
        Target = [string]$_.Target
        BackupPath = [string]$_.BackupPath
        MigrationMode = [string]$_.MigrationMode
    }
})
$configuration.AllowTargetReplace = $false
$null = New-Item -ItemType Directory -Path $fullProgressPath -Force -ErrorAction Stop
Write-MigrationProgressEvent -ProgressPath $fullProgressPath -Source '' -Target '' `
    -Stage 'Migration' -Status 'Started' -Message 'Sequential migration run started; source/target pairs and databases will run one at a time.'

$migrationScript = Join-Path $PSScriptRoot 'Invoke-DbMigration.ps1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "DbMigrationWebPlan-$([guid]::NewGuid().ToString('N'))"
$temporaryReports = Join-Path $temporaryRoot 'reports'
$null = New-Item -ItemType Directory -Path $temporaryReports -Force -ErrorAction Stop
$migrationRows = [System.Collections.Generic.List[object]]::new()
$runFailed = $false
$runStopped = $false
$runFailureMessage = ''
$outputPath = [string]$configuration.OutputPath
if (-not [System.IO.Path]::IsPathRooted($outputPath)) {
    $outputPath = Join-Path $PSScriptRoot $outputPath
}
$linkedServersPath = [string]$configuration.LinkedServersCsv
if (-not [System.IO.Path]::IsPathRooted($linkedServersPath)) {
    $linkedServersPath = Join-Path $PSScriptRoot $linkedServersPath
}
$configuration.OutputPath = $outputPath
$configuration.LinkedServersCsv = $linkedServersPath

function Invoke-MigrationWorker {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $WorkerConfiguration,
        [Parameter(Mandatory)][string] $WorkerName
    )

    $configPath = Join-Path $temporaryRoot "$WorkerName.json"
    $workerOutput = Join-Path $temporaryReports $WorkerName
    $null = New-Item -ItemType Directory -Path $workerOutput -Force -ErrorAction Stop
    $WorkerConfiguration | ConvertTo-Json -Depth 12 |
        Set-Content -LiteralPath $configPath -Encoding utf8 -ErrorAction Stop
    try {
        $workerArguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $migrationScript,
            '-Mode', 'Migrate', '-ConfigPath', $configPath, '-ProgressPath', $fullProgressPath,
            '-StatePath', $fullStatePath, '-OutputPath', $workerOutput,
            '-ControlPath', $fullControlPath, '-SuppressOverallProgress'
        )
        $previousNativePreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
        & (Join-Path $PSHOME 'pwsh.exe') @workerArguments | Out-Host
        $workerExitCode = $LASTEXITCODE
        $PSNativeCommandUseErrorActionPreference = $previousNativePreference
        $workerRows = [System.Collections.Generic.List[object]]::new()
        foreach ($report in Get-ChildItem -LiteralPath $workerOutput -Filter 'Migration-*.csv' -File -ErrorAction Stop) {
            foreach ($row in Import-Csv -LiteralPath $report.FullName -ErrorAction Stop) {
                $migrationRows.Add($row)
                $workerRows.Add($row)
            }
        }
        return @{
            ExitCode = $workerExitCode
            Rows = @($workerRows)
        }
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $previousNativePreference
        Remove-Item -LiteralPath $configPath -Force -ErrorAction Stop
    }
}

try {
    $validation = @(Test-MigrationConfiguration -Configuration $configuration)
    $null = Write-MigrationReports -Rows $validation -OutputPath $outputPath -Name 'PreMigrationValidation'
    foreach ($validationResult in $validation) {
        $validationStatus = switch ($validationResult.Status) {
            'Passed' { 'Completed' }
            'Skipped' { 'Skipped' }
            default { 'Failed' }
        }
        Write-MigrationProgressEvent -ProgressPath $fullProgressPath -Source $validationResult.Source `
            -Target $validationResult.Target -Stage "Validation:$($validationResult.Role)" `
            -Status $validationStatus -Message $validationResult.Message
    }
    if (@($validation | Where-Object Status -eq 'Failed').Count -gt 0) {
        throw 'Migration configuration validation failed. No databases were migrated.'
    }

    for ($pairIndex = 0; $pairIndex -lt $plan.Pairs.Count -and -not $runFailed; $pairIndex++) {
        if (-not (Wait-MigrationControl -ControlPath $fullControlPath -ProgressPath $fullProgressPath -HonorStop)) {
            $runStopped = $true
            break
        }
        $pairPlan = $plan.Pairs[$pairIndex]
        $pair = @{
            Source = [string]$pairPlan.Source
            Target = [string]$pairPlan.Target
            BackupPath = [string]$pairPlan.BackupPath
            MigrationMode = [string]$pairPlan.MigrationMode
        }
        Write-MigrationProgressEvent -ProgressPath $fullProgressPath -Source $pair.Source -Target $pair.Target `
            -Stage 'InstanceSequence' -Status 'Started' `
            -Message "Starting source/target pair $($pairIndex + 1) of $($plan.Pairs.Count)."

        $availableDatabases = @(Get-MigrationDatabase -SqlInstance $pair.Source -Configuration $configuration |
            ForEach-Object { [string]$_.Name })
        $selectedNames = @($pairPlan.Databases | ForEach-Object { [string]$_.Database })
        $missingDatabases = @($selectedNames | Where-Object { $_ -notin $availableDatabases })
        if ($missingDatabases.Count -gt 0) {
            throw "Database(s) no longer available on '$($pair.Source)': $($missingDatabases -join ', ')."
        }

        for ($databaseIndex = 0; $databaseIndex -lt $pairPlan.Databases.Count; $databaseIndex++) {
            if (-not (Wait-MigrationControl -ControlPath $fullControlPath -ProgressPath $fullProgressPath `
                    -Source $pair.Source -Target $pair.Target -HonorStop)) {
                $runStopped = $true
                break
            }
            $databasePlan = $pairPlan.Databases[$databaseIndex]
            $databaseName = [string]$databasePlan.Database
            Write-MigrationProgressEvent -ProgressPath $fullProgressPath -Source $pair.Source -Target $pair.Target `
                -Database $databaseName -Stage 'DatabaseSequence' -Status 'Started' `
                -Message "Validating and migrating database $($databaseIndex + 1) of $($pairPlan.Databases.Count)."

            $workerConfiguration = $configuration.Clone()
            $workerConfiguration.SourceTargets = @($pair)
            $workerConfiguration.IncludeDatabases = @($databaseName)
            $workerConfiguration.OverwriteExistingDatabases = @()
            $workerConfiguration.SkipExistingDatabases = @()
            foreach ($property in @(
                'MigrateLogins', 'MigrateAgentJobs', 'MigrateAgentOperators',
                'ConfigureLinkedServers', 'RepairOrphanUsers', 'UpdateStatistics'
            )) {
                $workerConfiguration[$property] = $false
            }
            $workerConfiguration.RepairOrphanUsers = [bool]$plan.Options.RepairOrphanUsers
            $workerConfiguration.UpdateStatistics = [bool]$plan.Options.UpdateStatistics
            if ($pair.MigrationMode -eq 'SchemaOnly') {
                $schemaResult = Invoke-DatabaseSchemaOnlyMigration -Pair $pair -Database $databaseName `
                    -Overwrite ([bool]$databasePlan.Overwrite) -ProgressPath $fullProgressPath `
                    -ControlPath $fullControlPath
                $migrationRows.Add($schemaResult)
                if ($schemaResult.Status -eq 'Failed') {
                    $runFailed = $true
                    $runFailureMessage = "Schema-only migration for '$databaseName' failed: $($schemaResult.Message) The sequence stopped; later databases and source/target pairs were not started."
                    Write-MigrationProgressEvent -ProgressPath $fullProgressPath -Source $pair.Source -Target $pair.Target `
                        -Database $databaseName -Stage 'DatabaseSequence' -Status 'Failed' -Message $runFailureMessage
                    break
                }
                if ($schemaResult.Status -eq 'Stopped') {
                    $runStopped = $true
                    break
                }
                Write-MigrationProgressEvent -ProgressPath $fullProgressPath -Source $pair.Source -Target $pair.Target `
                    -Database $databaseName -Stage 'DatabaseSequence' -Status 'Completed' `
                    -Message 'Schema-only processing completed; no table data was copied.'
                Write-MigrationProgressEvent -ProgressPath $fullProgressPath -Source $pair.Source -Target $pair.Target `
                    -Database $databaseName -Stage 'DatabaseOutcome' -Status $schemaResult.Status -Message $schemaResult.Message
                if (-not (Wait-MigrationControl -ControlPath $fullControlPath -ProgressPath $fullProgressPath `
                        -Source $pair.Source -Target $pair.Target -Database $databaseName -HonorStop)) {
                    $runStopped = $true
                    break
                }
                continue
            }
            if (Test-MigrationDatabaseExists -SqlInstance $pair.Target -Database $databaseName) {
                if ([bool]$databasePlan.Overwrite) {
                    $workerConfiguration.OverwriteExistingDatabases = @($databaseName)
                }
                else {
                    $workerConfiguration.SkipExistingDatabases = @($databaseName)
                }
            }

            $workerName = "pair-$pairIndex-database-$databaseIndex"
            $workerResult = Invoke-MigrationWorker -WorkerConfiguration $workerConfiguration -WorkerName $workerName
            $databaseRows = @($workerResult.Rows | Where-Object { $_.Database -ceq $databaseName })
            $databaseOutcome = @($databaseRows | Where-Object Stage -eq 'Database' | Select-Object -Last 1)
            $failedRows = @($workerResult.Rows | Where-Object Status -eq 'Failed')
            $validOutcome = $databaseOutcome.Count -eq 1 -and $databaseOutcome[0].Status -in @('Completed', 'Skipped')
            if ($validOutcome -and $databaseOutcome[0].Status -eq 'Completed') {
                $postCheck = @($databaseRows | Where-Object { $_.Stage -eq 'PostMigration' -and $_.Status -eq 'Completed' })
                $cleanup = @($workerResult.Rows | Where-Object { $_.Stage -eq 'BackupCleanup' -and $_.Status -eq 'Completed' })
                $validOutcome = $postCheck.Count -gt 0 -and $cleanup.Count -gt 0
            }
            if ($failedRows.Count -gt 0 -or -not $validOutcome) {
                $runFailed = $true
                $detail = if ($failedRows.Count -gt 0) {
                    [string]$failedRows[0].Message
                } else {
                    "Worker exit code $($workerResult.ExitCode); required successful database, post-check, or backup-cleanup report rows were missing."
                }
                $runFailureMessage = "Database '$databaseName' failed validation or migration: $detail The sequence stopped; later databases and source/target pairs were not started."
                Write-MigrationProgressEvent -ProgressPath $fullProgressPath -Source $pair.Source -Target $pair.Target `
                    -Database $databaseName -Stage 'DatabaseSequence' -Status 'Failed' -Message $runFailureMessage
                break
            }
            if ($workerResult.ExitCode -ne 0) {
                Write-MigrationProgressEvent -ProgressPath $fullProgressPath -Source $pair.Source -Target $pair.Target `
                    -Database $databaseName -Stage 'DatabaseSequence' -Status 'InProgress' `
                    -Message "Worker exited with code $($workerResult.ExitCode), but its report confirms database processing, post-checks, and cleanup completed; continuing."
            }
            Write-MigrationProgressEvent -ProgressPath $fullProgressPath -Source $pair.Source -Target $pair.Target `
                -Database $databaseName -Stage 'DatabaseSequence' -Status 'Completed' `
                -Message 'Database processing and required temporary backup cleanup completed before proceeding.'
            $databaseOutcomeStatus = [string]$databaseOutcome[0].Status
            Write-MigrationProgressEvent -ProgressPath $fullProgressPath -Source $pair.Source -Target $pair.Target `
                -Database $databaseName -Stage 'DatabaseOutcome' -Status $databaseOutcomeStatus `
                -Message ([string]$databaseOutcome[0].Message)
            if (-not (Wait-MigrationControl -ControlPath $fullControlPath -ProgressPath $fullProgressPath `
                    -Source $pair.Source -Target $pair.Target -Database $databaseName -HonorStop)) {
                $runStopped = $true
                break
            }
        }
        if ($runStopped) { break }
        if ($runFailed) {
            break
        }

        if (-not (Wait-MigrationControl -ControlPath $fullControlPath -ProgressPath $fullProgressPath `
                -Source $pair.Source -Target $pair.Target -HonorStop)) {
            $runStopped = $true
            break
        }
        $hasServerWork = Test-MigrationServerWorkEnabled -Options $plan.Options -MigrationMode $pair.MigrationMode
        if ($hasServerWork) {
            $serverConfiguration = $configuration.Clone()
            $serverConfiguration.SourceTargets = @($pair)
            $serverConfiguration.IncludeDatabases = @()
            $serverConfiguration.OverwriteExistingDatabases = @()
            $serverConfiguration.SkipExistingDatabases = @()
            $serverConfiguration.MigrateLogins = [bool]$plan.Options.MigrateLogins
            $serverConfiguration.MigrateAgentJobs = [bool]$plan.Options.MigrateAgentJobs
            $serverConfiguration.MigrateAgentOperators = [bool]$plan.Options.MigrateAgentOperators
            $serverConfiguration.ConfigureLinkedServers = [bool](
                $plan.Options.ConfigureLinkedServers -and -not $plan.Options.SkipLinkedServers
            )
            $serverConfiguration.RepairOrphanUsers = $false
            $serverConfiguration.UpdateStatistics = $false
            $serverWorkerResult = Invoke-MigrationWorker -WorkerConfiguration $serverConfiguration `
                -WorkerName "pair-$pairIndex-server-objects"
            $serverRows = @($serverWorkerResult.Rows)
            $serverFailures = @($serverRows | Where-Object Status -eq 'Failed')
            $completedServerStages = @($serverRows | Where-Object {
                $_.Stage -in @('ServerObjects', 'LinkedServers') -and $_.Status -eq 'Completed'
            })
            if ($serverFailures.Count -gt 0 -or $completedServerStages.Count -eq 0) {
                $runFailed = $true
                $detail = if ($serverFailures.Count -gt 0) { [string]$serverFailures[0].Message } else { "Worker exit code $($serverWorkerResult.ExitCode); successful server-stage report rows were missing." }
                $runFailureMessage = "Server-object migration failed for '$($pair.Source)' -> '$($pair.Target)': $detail Later source/target pairs were not started."
                Write-MigrationProgressEvent -ProgressPath $fullProgressPath -Source $pair.Source -Target $pair.Target `
                    -Stage 'InstanceSequence' -Status 'Failed' -Message $runFailureMessage
                break
            }
        }
        Write-MigrationProgressEvent -ProgressPath $fullProgressPath -Source $pair.Source -Target $pair.Target `
            -Stage 'InstanceSequence' -Status 'Completed' `
            -Message 'All selected databases and server-object stages completed; the next source/target pair may start.'
    }

    if ($runFailed) {
        throw $runFailureMessage
    }
    $null = Write-MigrationReports -Rows @($migrationRows) -OutputPath $outputPath -Name 'Migration'
    if ($runStopped) {
        Write-MigrationProgressEvent -ProgressPath $fullProgressPath -Source '' -Target '' `
            -Stage 'Migration' -Status 'Stopped' -Message 'The plan stopped at a safe database boundary.'
    } else {
        Write-MigrationProgressEvent -ProgressPath $fullProgressPath -Source '' -Target '' `
            -Stage 'Migration' -Status 'Completed' `
            -Message 'The sequential migration plan completed; non-skipped databases passed enabled checks and temporary backup cleanup.'
    }
}
catch {
    $failureMessage = $_.Exception.Message
    $migrationRows.Add([pscustomobject]@{
        Source = ''
        Target = ''
        Database = '*'
        Stage = 'DatabaseSequence'
        Status = 'Failed'
        BackupPath = $null
        Message = $failureMessage
    })
    $null = Write-MigrationReports -Rows @($migrationRows) -OutputPath $outputPath -Name 'Migration'
    Write-MigrationProgressEvent -ProgressPath $fullProgressPath -Source '' -Target '' `
        -Stage 'Migration' -Status 'Failed' -Message $failureMessage
    throw
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction Stop
    }
}
