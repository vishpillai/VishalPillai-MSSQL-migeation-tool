[CmdletBinding()]
param(
    [Parameter()]
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config\migration.config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'The migration GUI requires Windows.'
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        throw 'PowerShell 7 is required. Install it, then run this script again.'
    }

    $scriptPath = $PSCommandPath.Replace('"', '\"')
    $configPathArgument = $ConfigPath.Replace('"', '\"')
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh.Source
    $startInfo.Arguments = "-NoProfile -File `"$scriptPath`" -ConfigPath `"$configPathArgument`""
    $startInfo.UseShellExecute = $false
    $null = [System.Diagnostics.Process]::Start($startInfo)
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('DbMigration.Gui.ProcessOutputHandler' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Collections.Concurrent;
using System.Diagnostics;

namespace DbMigration.Gui
{
    public sealed class ProcessOutputHandler
    {
        private readonly ConcurrentQueue<string> queue;

        public ProcessOutputHandler(ConcurrentQueue<string> queue)
        {
            this.queue = queue;
        }

        public void Attach(Process process)
        {
            process.OutputDataReceived += OnOutputDataReceived;
            process.ErrorDataReceived += OnErrorDataReceived;
        }

        private void OnOutputDataReceived(object sender, DataReceivedEventArgs eventArgs)
        {
            if (eventArgs.Data != null)
            {
                queue.Enqueue(eventArgs.Data);
            }
        }

        private void OnErrorDataReceived(object sender, DataReceivedEventArgs eventArgs)
        {
            if (eventArgs.Data != null)
            {
                queue.Enqueue("ERROR: " + eventArgs.Data);
            }
        }
    }
}
'@
}

$moduleDirectory = Join-Path $PSScriptRoot 'src'
Import-Module (Join-Path $moduleDirectory 'DbMigration.Core.psm1') -Force
Import-Module (Join-Path $moduleDirectory 'DbMigration.Discovery.psm1') -Force
$script:logQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:migrationProcess = $null
$script:runtimeConfigPath = $null
$script:progressDirectory = $null
$script:runLogPath = $null
$script:migrationStartedAt = $null
$script:lastMigrationOutputAt = $null
$script:lastHeartbeatAt = $null
$script:lastProgressSummary = 'Migration is starting.'
$script:migrationErrorPopupShown = $false
$script:databaseDetails = @()
$script:selectedDatabaseNames = @()
$script:databaseOutcomes = @{}

$configuration = Import-MigrationConfiguration -Path $ConfigPath
$sourceTarget = $configuration.SourceTargets[0]
foreach ($property in @('OutputPath', 'LinkedServersCsv')) {
    if (-not [System.IO.Path]::IsPathRooted($configuration[$property])) {
        $configuration[$property] = Join-Path $PSScriptRoot $configuration[$property]
    }
}
if (-not [System.IO.Path]::IsPathRooted($sourceTarget.BackupPath)) {
    $sourceTarget.BackupPath = Join-Path $PSScriptRoot $sourceTarget.BackupPath
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Database Migration'
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new(920, 820)
$form.MinimumSize = [System.Drawing.Size]::new(820, 820)

function Add-Label {
    param([string] $Text, [int] $X, [int] $Y, [int] $Width = 120)
    $label = [System.Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.Location = [System.Drawing.Point]::new($X, $Y)
    $label.Size = [System.Drawing.Size]::new($Width, 24)
    $form.Controls.Add($label)
    $label
}

function Add-TextBox {
    param([string] $Text, [int] $X, [int] $Y, [int] $Width = 560)
    $textBox = [System.Windows.Forms.TextBox]::new()
    $textBox.Text = $Text
    $textBox.Location = [System.Drawing.Point]::new($X, $Y)
    $textBox.Size = [System.Drawing.Size]::new($Width, 24)
    $textBox.Anchor = 'Top,Left,Right'
    $form.Controls.Add($textBox)
    $textBox
}

function Add-CheckBox {
    param([string] $Text, [int] $X, [int] $Y, [bool] $Checked = $true, [int] $Width = 260)
    $checkBox = [System.Windows.Forms.CheckBox]::new()
    $checkBox.Text = $Text
    $checkBox.Checked = $Checked
    $checkBox.Location = [System.Drawing.Point]::new($X, $Y)
    $checkBox.Size = [System.Drawing.Size]::new($Width, 24)
    $form.Controls.Add($checkBox)
    $checkBox
}

function Show-MigrationErrorPopup {
    param([Parameter(Mandatory)][string] $OutputLine)

    if ($script:migrationErrorPopupShown) {
        return
    }
    $message = [regex]::Replace($OutputLine, "`e\[[0-?]*[ -/]*[@-~]", '').Trim()
    $message = $message -replace '^ERROR:\s*', ''
    if ([string]::IsNullOrWhiteSpace($message)) {
        return
    }

    $script:migrationErrorPopupShown = $true
    [System.Windows.Forms.MessageBox]::Show($form, $message, 'Migration error', 'OK', 'Error') | Out-Null
}

function Update-MigrationProgressDisplay {
    $completed = @($script:databaseOutcomes.Values | Where-Object { $_ -eq 'Completed' }).Count
    $skipped = @($script:databaseOutcomes.Values | Where-Object { $_ -eq 'Skipped' }).Count
    $failed = @($script:databaseOutcomes.Values | Where-Object { $_ -eq 'Failed' }).Count
    $resolved = $completed + $skipped + $failed
    $total = $script:selectedDatabaseNames.Count

    if ($total -gt 0) {
        $databaseProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        $databaseProgressBar.Maximum = $total
        $databaseProgressBar.Value = [Math]::Min($resolved, $total)
        $pending = $total - $resolved
        $databaseProgressLabel.Text = "Databases: $resolved/$total resolved  |  $completed completed  |  $skipped skipped  |  $failed failed  |  $pending pending"
    }
    else {
        $databaseProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $databaseProgressLabel.Text = 'Database progress: server-level migration'
    }
}

function Read-MigrationProgressEvents {
    if (-not $script:progressDirectory -or -not (Test-Path -LiteralPath $script:progressDirectory -PathType Container)) {
        return
    }

    foreach ($eventFile in Get-ChildItem -LiteralPath $script:progressDirectory -Filter '*.json' -File | Sort-Object Name) {
        try {
            $migrationEvent = Get-Content -LiteralPath $eventFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $time = ([DateTime]::Parse([string]$migrationEvent.Timestamp)).ToLocalTime().ToString('HH:mm:ss')
            $databaseName = if ($migrationEvent.Database -and $migrationEvent.Database -ne '*') { [string]$migrationEvent.Database } else { '' }
            $subject = if ($databaseName) { "$databaseName / " } else { '' }
            $message = if ([string]::IsNullOrWhiteSpace([string]$migrationEvent.Message)) { '' } else { ": $($migrationEvent.Message)" }
            $displayLine = "[$time] [$($migrationEvent.Status)] $subject$($migrationEvent.Stage)$message"
            $logBox.AppendText("$displayLine`r`n")
            Add-Content -LiteralPath $script:runLogPath -Value $displayLine -Encoding utf8 -ErrorAction Stop
            $script:lastMigrationOutputAt = [DateTime]::Now

            if ($migrationEvent.Stage -eq 'DatabaseOutcome' -and $databaseName) {
                $script:databaseOutcomes[$databaseName] = [string]$migrationEvent.Status
                Update-MigrationProgressDisplay
            }
            if ($migrationEvent.Status -in @('Started', 'InProgress')) {
                $script:lastProgressSummary = "$subject$($migrationEvent.Stage)"
            }
            if ($migrationEvent.Status -eq 'Failed') {
                $statusLabel.ForeColor = [System.Drawing.Color]::Firebrick
                $statusLabel.Text = "Issue: $subject$($migrationEvent.Stage) failed."
                Show-MigrationErrorPopup -OutputLine "$subject$($migrationEvent.Stage): $($migrationEvent.Message)"
            }
            elseif ($migrationEvent.Stage -ne 'DatabaseOutcome' -and $migrationEvent.Status -in @('Started', 'InProgress')) {
                $statusLabel.ForeColor = [System.Drawing.SystemColors]::ControlText
                $statusLabel.Text = "Running: $subject$($migrationEvent.Stage) ($($migrationEvent.Status.ToLowerInvariant()))."
            }

            Remove-Item -LiteralPath $eventFile.FullName -Force -ErrorAction Stop
        }
        catch {
            $errorLine = "ERROR: Could not process migration progress event '$($eventFile.Name)': $($_.Exception.Message)"
            $logBox.AppendText("$errorLine`r`n")
            Add-Content -LiteralPath $script:runLogPath -Value $errorLine -Encoding utf8 -ErrorAction Stop
            Show-MigrationErrorPopup -OutputLine $errorLine
        }
    }
}

Add-Label 'Source SQL instance' 16 18
$sourceBox = Add-TextBox ([string]$sourceTarget.Source) 148 16 720
Add-Label 'Target SQL instance' 16 52
$targetBox = Add-TextBox ([string]$sourceTarget.Target) 148 50 720
Add-Label 'Backup directory' 16 86
$backupBox = Add-TextBox ([string]$sourceTarget.BackupPath) 148 84 650
$browseBackupButton = [System.Windows.Forms.Button]::new()
$browseBackupButton.Text = 'Browse...'
$browseBackupButton.Location = [System.Drawing.Point]::new(808, 83)
$browseBackupButton.Size = [System.Drawing.Size]::new(80, 26)
$browseBackupButton.Anchor = 'Top,Right'
$form.Controls.Add($browseBackupButton)

$discoverButton = [System.Windows.Forms.Button]::new()
$discoverButton.Text = 'Discover databases'
$discoverButton.Location = [System.Drawing.Point]::new(16, 120)
$discoverButton.Size = [System.Drawing.Size]::new(150, 30)
$form.Controls.Add($discoverButton)

$databaseLabel = Add-Label 'Select databases to migrate' 180 124 400
$selectAllButton = [System.Windows.Forms.Button]::new()
$selectAllButton.Text = 'Select all'
$selectAllButton.Location = [System.Drawing.Point]::new(690, 120)
$selectAllButton.Size = [System.Drawing.Size]::new(90, 30)
$selectAllButton.Anchor = 'Top,Right'
$form.Controls.Add($selectAllButton)
$selectNoneButton = [System.Windows.Forms.Button]::new()
$selectNoneButton.Text = 'Select none'
$selectNoneButton.Location = [System.Drawing.Point]::new(790, 120)
$selectNoneButton.Size = [System.Drawing.Size]::new(98, 30)
$selectNoneButton.Anchor = 'Top,Right'
$form.Controls.Add($selectNoneButton)

$databaseList = [System.Windows.Forms.CheckedListBox]::new()
$databaseList.Location = [System.Drawing.Point]::new(16, 158)
$databaseList.Size = [System.Drawing.Size]::new(872, 190)
$databaseList.Anchor = 'Top,Left,Right'
$databaseList.CheckOnClick = $true
$form.Controls.Add($databaseList)

$optionsGroup = [System.Windows.Forms.GroupBox]::new()
$optionsGroup.Text = 'Additional migration objects and actions'
$optionsGroup.Location = [System.Drawing.Point]::new(16, 360)
$optionsGroup.Size = [System.Drawing.Size]::new(872, 124)
$optionsGroup.Anchor = 'Top,Left,Right'
$form.Controls.Add($optionsGroup)

$loginCheck = Add-CheckBox 'SQL logins (excluding sa)' 14 24 ([bool]$configuration.MigrateLogins) 265
$jobCheck = Add-CheckBox 'SQL Agent jobs' 300 24 ([bool]$configuration.MigrateAgentJobs) 220
$operatorCheck = Add-CheckBox 'SQL Agent operators' 535 24 ([bool]$configuration.MigrateAgentOperators) 250
$linkedCheck = Add-CheckBox 'Configure linked servers from CSV' 14 56 ([bool]$configuration.ConfigureLinkedServers) 300
$repairCheck = Add-CheckBox 'Repair orphaned users' 330 56 ([bool]$configuration.RepairOrphanUsers) 250
$statisticsCheck = Add-CheckBox 'Update database statistics' 575 56 ([bool]$configuration.UpdateStatistics) 260
foreach ($checkBox in @($loginCheck, $jobCheck, $operatorCheck, $linkedCheck, $repairCheck, $statisticsCheck)) {
    $optionsGroup.Controls.Add($checkBox)
    $checkBox.Location = [System.Drawing.Point]::new($checkBox.Location.X, $checkBox.Location.Y)
}

Add-Label 'Linked servers CSV' 16 496 120
$linkedCsvBox = Add-TextBox ([string]$configuration.LinkedServersCsv) 148 494 740
Add-Label 'Report folder' 16 530 120
$outputBox = Add-TextBox ([string]$configuration.OutputPath) 148 528 740
Add-Label 'Migration state' 16 564 120
$stateBox = Add-TextBox (Join-Path $PSScriptRoot 'MigrationState.json') 148 562 740

$startButton = [System.Windows.Forms.Button]::new()
$startButton.Text = 'Start migration'
$startButton.Location = [System.Drawing.Point]::new(16, 598)
$startButton.Size = [System.Drawing.Size]::new(150, 34)
$form.Controls.Add($startButton)
$statusLabel = Add-Label 'Ready' 180 603 690
$statusLabel.Anchor = 'Top,Left,Right'

$databaseProgressLabel = Add-Label 'Databases: waiting to start' 16 636 872
$databaseProgressLabel.Anchor = 'Top,Left,Right'
$databaseProgressBar = [System.Windows.Forms.ProgressBar]::new()
$databaseProgressBar.Location = [System.Drawing.Point]::new(16, 660)
$databaseProgressBar.Size = [System.Drawing.Size]::new(872, 16)
$databaseProgressBar.Anchor = 'Top,Left,Right'
$databaseProgressBar.Minimum = 0
$databaseProgressBar.Maximum = 1
$databaseProgressBar.Value = 0
$form.Controls.Add($databaseProgressBar)

$logBox = [System.Windows.Forms.TextBox]::new()
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.MaxLength = 100000
$logBox.ScrollBars = 'Vertical'
$logBox.Location = [System.Drawing.Point]::new(16, 686)
$logBox.Size = [System.Drawing.Size]::new(872, 90)
$logBox.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($logBox)

$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = 300

$browseBackupButton.Add_Click({
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.SelectedPath = $backupBox.Text
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $backupBox.Text = $dialog.SelectedPath
    }
    $dialog.Dispose()
})

$discoverButton.Add_Click({
    try {
        if ([string]::IsNullOrWhiteSpace($sourceBox.Text)) {
            throw 'Enter a source SQL instance first.'
        }
        $discoverButton.Enabled = $false
        $statusLabel.Text = "Connecting to $($sourceBox.Text)..."
        $form.Refresh()
        Import-Module dbatools -ErrorAction Stop
        $discoveryConfiguration = @{
            SourceTargets = @(@{
                Source = $sourceBox.Text.Trim()
                Target = $targetBox.Text.Trim()
            })
            ExcludeDatabases = @($configuration.ExcludeDatabases)
        }
        $script:databaseDetails = @(Get-MigrationDiscovery -Configuration $discoveryConfiguration)
        $databaseList.Items.Clear()
        foreach ($database in $script:databaseDetails) {
            [void]$databaseList.Items.Add("$($database.Database) ($($database.SizeGB) GB)", $true)
        }
        $serverObjectCounts = if ($script:databaseDetails.Count -gt 0) {
            $script:databaseDetails[0]
        }
        else {
            Get-MigrationServerObjectCounts -SqlInstance $sourceBox.Text.Trim()
        }
        $report = Write-MigrationReports -Rows $script:databaseDetails -OutputPath ([System.IO.Path]::GetFullPath($outputBox.Text.Trim())) -Name 'Discovery'
        $statusLabel.Text = "Found $($script:databaseDetails.Count) eligible database(s)."
        $logBox.Clear()
        $logBox.AppendText("Discovery: $($sourceBox.Text.Trim())`r`n")
        $logBox.AppendText("Logins: $($serverObjectCounts.SourceLoginCount ?? $serverObjectCounts.LoginCount); Linked servers: $($serverObjectCounts.SourceLinkedServerCount ?? $serverObjectCounts.LinkedServerCount); Agent jobs: $($serverObjectCounts.SourceAgentJobCount ?? $serverObjectCounts.AgentJobCount)`r`n")
        foreach ($database in $script:databaseDetails) {
            $logBox.AppendText("$($database.Database): $($database.SizeGB) GB`r`n")
        }
        $logBox.AppendText("Details: $($report.CsvPath)`r`n")
        $logBox.AppendText("Details: $($report.CsvPath)`r`n")
    }
    catch {
        $statusLabel.Text = 'Discovery failed.'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Discovery failed', 'OK', 'Error') | Out-Null
    }
    finally {
        $discoverButton.Enabled = $true
    }
})

$selectAllButton.Add_Click({
    for ($index = 0; $index -lt $databaseList.Items.Count; $index++) {
        $databaseList.SetItemChecked($index, $true)
    }
})
$selectNoneButton.Add_Click({
    for ($index = 0; $index -lt $databaseList.Items.Count; $index++) {
        $databaseList.SetItemChecked($index, $false)
    }
})

$startButton.Add_Click({
    try {
        $selectedDatabases = @($databaseList.CheckedIndices | ForEach-Object { [string]$script:databaseDetails[$_].Database })
        $migrateServerObjects = $loginCheck.Checked -or $jobCheck.Checked -or $operatorCheck.Checked
        $migrateLinkedServers = $linkedCheck.Checked
        if ($selectedDatabases.Count -eq 0 -and -not $migrateServerObjects -and -not $migrateLinkedServers) {
            throw 'Select at least one database or one server-level migration option.'
        }
        foreach ($field in @(
            @{ Name = 'Source SQL instance'; Value = $sourceBox.Text },
            @{ Name = 'Target SQL instance'; Value = $targetBox.Text },
            @{ Name = 'Backup directory'; Value = $backupBox.Text },
            @{ Name = 'Report folder'; Value = $outputBox.Text },
            @{ Name = 'Migration state path'; Value = $stateBox.Text }
        )) {
            if ([string]::IsNullOrWhiteSpace($field.Value)) {
                throw "$($field.Name) must not be empty."
            }
        }
        if ($migrateLinkedServers -and -not (Test-Path -LiteralPath $linkedCsvBox.Text -PathType Leaf)) {
            throw "Linked servers CSV not found: $($linkedCsvBox.Text)"
        }

        $databaseSummary = if ($selectedDatabases.Count -gt 0) { $selectedDatabases -join ', ' } else { '(none)' }
        $confirmation = "This run will migrate the selected objects to '$($targetBox.Text.Trim())'.`r`n`r`nDatabases: $databaseSummary`r`n`r`nYou will be asked separately whether to replace each selected database that already exists on the target. Continue?"
        $answer = [System.Windows.Forms.MessageBox]::Show($confirmation, 'Confirm migration', 'YesNo', 'Warning')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }

        $overwriteDatabases = [System.Collections.Generic.List[string]]::new()
        $skipExistingDatabases = [System.Collections.Generic.List[string]]::new()
        if ($selectedDatabases.Count -gt 0) {
            Import-Module dbatools -ErrorAction Stop
            foreach ($database in $selectedDatabases) {
                if (-not (Test-MigrationDatabaseExists -SqlInstance $targetBox.Text.Trim() -Database $database)) {
                    continue
                }
                $overwriteAnswer = [System.Windows.Forms.MessageBox]::Show(
                    $form,
                    "Database '$database' already exists on '$($targetBox.Text.Trim())'.`r`n`r`nYes: replace the target database.`r`nNo: skip this database and leave the target unchanged.",
                    'Overwrite existing database?',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning,
                    [System.Windows.Forms.MessageBoxDefaultButton]::Button2
                )
                if ($overwriteAnswer -eq [System.Windows.Forms.DialogResult]::Yes) {
                    $overwriteDatabases.Add($database)
                }
                else {
                    $skipExistingDatabases.Add($database)
                }
            }
        }

        $runConfiguration = Import-MigrationConfiguration -Path $ConfigPath
        $runConfiguration.SourceTargets = @(@{
            Source = $sourceBox.Text.Trim()
            Target = $targetBox.Text.Trim()
            BackupPath = $backupBox.Text.Trim()
        })
        $runConfiguration.IncludeDatabases = $selectedDatabases
        $runConfiguration.OverwriteExistingDatabases = @($overwriteDatabases)
        $runConfiguration.SkipExistingDatabases = @($skipExistingDatabases)
        $runConfiguration.OutputPath = [System.IO.Path]::GetFullPath($outputBox.Text.Trim())
        $runConfiguration.LinkedServersCsv = [System.IO.Path]::GetFullPath($linkedCsvBox.Text.Trim())
        $runConfiguration.MigrateLogins = [bool]$loginCheck.Checked
        $runConfiguration.MigrateAgentJobs = [bool]$jobCheck.Checked
        $runConfiguration.MigrateAgentOperators = [bool]$operatorCheck.Checked
        $runConfiguration.ConfigureLinkedServers = [bool]$linkedCheck.Checked
        $runConfiguration.RepairOrphanUsers = [bool]$repairCheck.Checked
        $runConfiguration.UpdateStatistics = [bool]$statisticsCheck.Checked
        $runConfiguration.AllowTargetReplace = $false

        $script:runtimeConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) "dbmigration-$([guid]::NewGuid().ToString('N')).json"
        $runConfiguration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:runtimeConfigPath -Encoding utf8

        $script:progressDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "dbmigration-progress-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $script:progressDirectory -Force -ErrorAction Stop
        $script:selectedDatabaseNames = @($selectedDatabases)
        $script:databaseOutcomes = @{}
        Update-MigrationProgressDisplay

        $pwshPath = Join-Path $PSHOME 'pwsh.exe'
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $pwshPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $PSScriptRoot 'Invoke-DbMigration.ps1'),
            '-Mode', 'Migrate', '-ConfigPath', $script:runtimeConfigPath,
            '-ProgressPath', $script:progressDirectory,
            '-StatePath', [System.IO.Path]::GetFullPath($stateBox.Text.Trim()),
            '-OutputPath', [System.IO.Path]::GetFullPath($outputBox.Text.Trim())
        )) {
            [void]$startInfo.ArgumentList.Add([string]$argument)
        }

        $logDirectory = Join-Path $env:LOCALAPPDATA 'DbMigration\logs'
        $null = New-Item -ItemType Directory -Path $logDirectory -Force
        $runLogSuffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:runLogPath = Join-Path $logDirectory "Migration-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$runLogSuffix.log"
        $script:migrationStartedAt = [DateTime]::Now
        $script:lastMigrationOutputAt = $script:migrationStartedAt
        $script:lastHeartbeatAt = $script:migrationStartedAt
        $script:migrationErrorPopupShown = $false
        $script:lastProgressSummary = 'Migration is starting.'
        $statusLabel.ForeColor = [System.Drawing.SystemColors]::ControlText
        $statusLabel.Text = 'Migration is starting...'
        @(
            "Started: $($script:migrationStartedAt.ToString('o'))"
            "Source: $($sourceBox.Text.Trim())"
            "Target: $($targetBox.Text.Trim())"
            "Databases: $databaseSummary"
            "Reports: $($runConfiguration.OutputPath)"
            "State: $([System.IO.Path]::GetFullPath($stateBox.Text.Trim()))"
        ) | Set-Content -LiteralPath $script:runLogPath -Encoding utf8

        $script:logQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $script:migrationProcess = [System.Diagnostics.Process]::new()
        $script:migrationProcess.StartInfo = $startInfo
        $script:processOutputHandler = [DbMigration.Gui.ProcessOutputHandler]::new($script:logQueue)
        $script:processOutputHandler.Attach($script:migrationProcess)
        if (-not $script:migrationProcess.Start()) {
            throw 'Could not start the migration process.'
        }
        $script:migrationProcess.BeginOutputReadLine()
        $script:migrationProcess.BeginErrorReadLine()
        $startButton.Enabled = $false
        $discoverButton.Enabled = $false
        $statusLabel.Text = 'Migration is running...'
        $logBox.Clear()
        $logBox.AppendText("Migration started. Database selection: $databaseSummary`r`nDetailed log: $($script:runLogPath)`r`n")
        $timer.Start()
    }
    catch {
        $statusLabel.Text = 'Could not start migration.'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Migration could not start', 'OK', 'Error') | Out-Null
    }
})

$timer.Add_Tick({
    Read-MigrationProgressEvents
    $line = $null
    while ($script:logQueue.TryDequeue([ref]$line)) {
        $logBox.AppendText("$line`r`n")
        Add-Content -LiteralPath $script:runLogPath -Value $line -Encoding utf8
        $script:lastMigrationOutputAt = [DateTime]::Now
        if ($line.StartsWith('ERROR:')) {
            Show-MigrationErrorPopup -OutputLine $line
        }
        $line = $null
    }
    if ($null -ne $script:migrationProcess -and -not $script:migrationProcess.HasExited) {
        $now = [DateTime]::Now
        if (($now - $script:lastHeartbeatAt).TotalSeconds -ge 15) {
            $elapsed = $now - $script:migrationStartedAt
            if (($now - $script:lastMigrationOutputAt).TotalSeconds -ge 15) {
                $statusLabel.Text = "Still running ($([int]$elapsed.TotalMinutes)m elapsed); current stage: $($script:lastProgressSummary)."
            }
            else {
                $statusLabel.Text = "Running ($([int]$elapsed.TotalMinutes)m): $($script:lastProgressSummary)."
            }
            $script:lastHeartbeatAt = $now
        }
    }
    if ($null -ne $script:migrationProcess -and $script:migrationProcess.HasExited) {
        $timer.Stop()
        $script:migrationProcess.WaitForExit()
        while ($script:logQueue.TryDequeue([ref]$line)) {
            $logBox.AppendText("$line`r`n")
            Add-Content -LiteralPath $script:runLogPath -Value $line -Encoding utf8
            if ($line.StartsWith('ERROR:')) {
                Show-MigrationErrorPopup -OutputLine $line
            }
            $line = $null
        }
        Read-MigrationProgressEvents
        $exitCode = $script:migrationProcess.ExitCode
        Add-Content -LiteralPath $script:runLogPath -Value "Finished: $([DateTime]::Now.ToString('o')); exit code: $exitCode" -Encoding utf8
        $script:migrationProcess.Dispose()
        $script:migrationProcess = $null
        $script:processOutputHandler = $null
        if ($script:runtimeConfigPath -and (Test-Path -LiteralPath $script:runtimeConfigPath)) {
            Remove-Item -LiteralPath $script:runtimeConfigPath -Force
            $script:runtimeConfigPath = $null
        }
        if ($script:progressDirectory -and (Test-Path -LiteralPath $script:progressDirectory -PathType Container)) {
            Remove-Item -LiteralPath $script:progressDirectory -Recurse -Force -ErrorAction Stop
            $script:progressDirectory = $null
        }
        $startButton.Enabled = $true
        $discoverButton.Enabled = $true
        if ($exitCode -eq 0) {
            $statusLabel.ForeColor = [System.Drawing.SystemColors]::ControlText
            $statusLabel.Text = "Migration completed. Reports: $($outputBox.Text); log: $($script:runLogPath)"
        }
        else {
            $statusLabel.ForeColor = [System.Drawing.Color]::Firebrick
            $statusLabel.Text = "Migration failed with exit code $exitCode. Log: $($script:runLogPath)"
            if (-not $script:migrationErrorPopupShown) {
                $script:migrationErrorPopupShown = $true
                [System.Windows.Forms.MessageBox]::Show(
                    $form,
                    "Migration failed with exit code $exitCode. Review the detailed log:`r`n$($script:runLogPath)",
                    'Migration failed',
                    'OK',
                    'Error'
                ) | Out-Null
            }
        }
    }
})

$form.Add_FormClosing({
    if ($null -ne $script:migrationProcess -and -not $script:migrationProcess.HasExited) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            'The migration process is still running. Closing this window will not stop it. Close the GUI?',
            'Migration running', 'YesNo', 'Warning'
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            $_.Cancel = $true
        }
    }
})

[void]$form.ShowDialog()
$timer.Dispose()
$form.Dispose()
