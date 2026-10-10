BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.Core.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.WebAuth.psm1') -Force
}

Describe 'Migration web authentication' {
    It 'verifies the configured username and password using a salted PBKDF2 record' {
        $password = ConvertTo-SecureString 'test-password-1234' -AsPlainText -Force
        $record = New-MigrationWebPasswordRecord -Username 'migration-admin' -Password $password

        Test-MigrationWebPassword -Record $record -Username 'migration-admin' -Password 'test-password-1234' |
            Should -BeTrue
        Test-MigrationWebPassword -Record $record -Username 'migration-admin' -Password 'incorrect-password' |
            Should -BeFalse
        Test-MigrationWebPassword -Record $record -Username 'other-user' -Password 'test-password-1234' |
            Should -BeFalse
        $record.PasswordHash | Should -Not -Be 'test-password-1234'
        $record.Iterations | Should -BeGreaterThan 100000
    }

    It 'rejects application passwords shorter than 14 characters' {
        $password = ConvertTo-SecureString 'too-short' -AsPlainText -Force
        { New-MigrationWebPasswordRecord -Username 'migration-admin' -Password $password } |
            Should -Throw '*at least 14 characters*'
    }
}

Describe 'Portable web storage paths' {
    It 'stores portable auth files under the app folder instead of ProgramData' {
        $storage = Resolve-MigrationWebStoragePaths -AppRoot $TestDrive -PortableMode

        $storage.IsPortable | Should -BeTrue
        $storage.AuthPath | Should -Be (Join-Path $TestDrive 'portable\auth\auth.json')
        $storage.LogDirectory | Should -Be (Join-Path $TestDrive 'portable\logs')
    }
}

Describe 'Migration configuration' {
    It 'loads a valid configuration and defaults exclusions and statistics' {
        $path = Join-Path $TestDrive 'migration.json'
        @'
{
  "SourceTargets": [{"Source":"source","Target":"target","BackupPath":"C:\\backups"}],
  "OutputPath": "reports",
  "ThrottleLimit": 2,
  "LinkedServersCsv": "linked.csv"
}
'@ | Set-Content -LiteralPath $path

        $config = Import-MigrationConfiguration -Path $path

        $config.SourceTargets.Count | Should -Be 1
        $config.SourceTargets[0].MigrationMode | Should -Be 'Full'
        $config.RestoreSpaceBufferPercent | Should -Be 20
        $config.BackupFileCount | Should -Be 4
        $config.UpdateStatistics | Should -BeTrue
        $config.ExcludeDatabases.Count | Should -Be 0
        $config.MigrateLogins | Should -BeTrue
        $config.ConfigureLinkedServers | Should -BeTrue
        $config.RepairOrphanUsers | Should -BeTrue
        $config.OverwriteExistingDatabases.Count | Should -Be 0
        $config.SkipExistingDatabases.Count | Should -Be 0
    }

    It 'accepts an explicit schema-only migration mode' {
        $path = Join-Path $TestDrive 'schema-only.json'
        @'
{
  "SourceTargets": [{"Source":"source","Target":"target","BackupPath":"C:\\backups","MigrationMode":"SchemaOnly"}],
  "OutputPath": "reports",
  "ThrottleLimit": 2,
  "LinkedServersCsv": "linked.csv"
}
'@ | Set-Content -LiteralPath $path

        (Import-MigrationConfiguration -Path $path).SourceTargets[0].MigrationMode | Should -Be 'SchemaOnly'
    }

    It 'rejects unknown migration modes' {
        $path = Join-Path $TestDrive 'invalid-mode.json'
        @'
{
  "SourceTargets": [{"Source":"source","Target":"target","BackupPath":"C:\\backups","MigrationMode":"SchemaAndData"}],
  "OutputPath": "reports",
  "ThrottleLimit": 2,
  "LinkedServersCsv": "linked.csv"
}
'@ | Set-Content -LiteralPath $path

        { Import-MigrationConfiguration -Path $path } | Should -Throw '*MigrationMode*'
    }

    It 'rejects missing source/target values' {
        $path = Join-Path $TestDrive 'invalid.json'
        @'
{
  "SourceTargets": [{"Source":"source","Target":"","BackupPath":"C:\\backups"}],
  "OutputPath": "reports",
  "ThrottleLimit": 2,
  "LinkedServersCsv": "linked.csv"
}
'@ | Set-Content -LiteralPath $path

        { Import-MigrationConfiguration -Path $path } | Should -Throw
    }

    It 'rejects invalid restore buffers and replacement settings' {
        $path = Join-Path $TestDrive 'invalid-safety.json'
        @'
{
  "SourceTargets": [{"Source":"source","Target":"target","BackupPath":"C:\\backups"}],
  "OutputPath": "reports",
  "ThrottleLimit": 2,
  "LinkedServersCsv": "linked.csv",
  "RestoreSpaceBufferPercent": 120,
  "AllowTargetReplace": "yes"
}
'@ | Set-Content -LiteralPath $path

        { Import-MigrationConfiguration -Path $path } | Should -Throw '*RestoreSpaceBufferPercent*'
    }

    It 'defaults to refusing target replacement' {
        $path = Join-Path $TestDrive 'safe-default.json'
        @'
{
  "SourceTargets": [{"Source":"source","Target":"target","BackupPath":"C:\\backups"}],
  "OutputPath": "reports",
  "ThrottleLimit": 2,
  "LinkedServersCsv": "linked.csv"
}
'@ | Set-Content -LiteralPath $path

        (Import-MigrationConfiguration -Path $path).AllowTargetReplace | Should -BeFalse
    }

    It 'requires an explicit per-database decision before replacing an existing target' {
        $config = @{
            AllowTargetReplace = $false
            OverwriteExistingDatabases = @('approved')
            SkipExistingDatabases = @('declined')
        }

        Get-MigrationTargetDatabaseDecision -Database declined -TargetExists $true -Configuration $config |
            Should -Be 'SkipRequested'
        Get-MigrationTargetDatabaseDecision -Database approved -TargetExists $true -Configuration $config |
            Should -Be 'Overwrite'
        Get-MigrationTargetDatabaseDecision -Database unchanged -TargetExists $true -Configuration $config |
            Should -Be 'Blocked'
        Get-MigrationTargetDatabaseDecision -Database completed -TargetExists $true -StateStatus Completed -Configuration $config |
            Should -Be 'SkipCompleted'
        Get-MigrationTargetDatabaseDecision -Database completed -TargetExists $true -StateStatus Completed `
            -Configuration (@{ AllowTargetReplace = $false; OverwriteExistingDatabases = @('completed'); SkipExistingDatabases = @() }) |
            Should -Be 'Overwrite'
        Get-MigrationTargetDatabaseDecision -Database newdb -TargetExists $false -Configuration $config |
            Should -Be 'Migrate'
    }

    It 'does not count linked-server work when linked servers are skipped' {
        $options = @{
            MigrateLogins = $false
            MigrateAgentJobs = $false
            MigrateAgentOperators = $false
            ConfigureLinkedServers = $true
            SkipLinkedServers = $true
        }

        Test-MigrationServerWorkEnabled -Options $options | Should -BeFalse
        Test-MigrationServerWorkEnabled -Options $options -MigrationMode SchemaOnly | Should -BeFalse

        $options.SkipLinkedServers = $false
        Test-MigrationServerWorkEnabled -Options $options | Should -BeTrue
    }

    It 'rejects backup stripe counts outside the supported range' {
        $path = Join-Path $TestDrive 'invalid-backup-file-count.json'
        @'
{
  "SourceTargets": [{"Source":"source","Target":"target","BackupPath":"C:\\backups"}],
  "OutputPath": "reports",
  "ThrottleLimit": 2,
  "LinkedServersCsv": "linked.csv",
  "BackupFileCount": 33
}
'@ | Set-Content -LiteralPath $path

        { Import-MigrationConfiguration -Path $path } | Should -Throw '*BackupFileCount*'
    }
}

Describe 'Schema-only configuration validation' {
    BeforeAll {
        Import-Module dbatools -ErrorAction Stop
        Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.Discovery.psm1') -Force
    }

    It 'does not probe a shared backup path' {
        $script:connectInvocation = 0
        Mock Connect-DbaInstance -ModuleName DbMigration.Discovery {
            $script:connectInvocation++
            $majorVersion = if ($script:connectInvocation -eq 1) { 13 } else { 16 }
            [pscustomobject]@{ VersionMajor = $majorVersion }
        }
        Mock Test-DbaPath -ModuleName DbMigration.Discovery {
            throw 'Schema-only migration should not inspect a backup path.'
        }
        $configuration = @{
            SourceTargets = @(@{
                Source = 'source'
                Target = 'target'
                BackupPath = '\\unused\share'
                MigrationMode = 'SchemaOnly'
            })
        }

        $results = @(Test-MigrationConfiguration -Configuration $configuration)

        @($results | Where-Object Status -eq 'Failed').Count | Should -Be 0
        @($results | Where-Object { $_.Role -eq 'BackupPath' -and $_.Status -eq 'Skipped' }).Count | Should -Be 1
        Should -Invoke Test-DbaPath -ModuleName DbMigration.Discovery -Exactly 0
    }
}

Describe 'Migration state' {
    It 'records progress and reads it back for resume' {
        $path = Join-Path $TestDrive 'MigrationState.json'
        $output = @(Set-MigrationState -Path $path -Source source -Target target -Database appdb -Status BackupCompleted -BackupPath 'C:\backups\appdb.bak')

        $state = Get-MigrationState -Path $path
        $key = Get-MigrationStateKey -Source source -Target target -Database appdb

        $output.Count | Should -Be 0
        $state.Databases[$key].Status | Should -Be 'BackupCompleted'
        $state.Databases[$key].BackupPath | Should -Be 'C:\backups\appdb.bak'
    }

    It 'creates distinct keys for different migration endpoints' {
        $first = Get-MigrationStateKey -Source source-a -Target target -Database appdb
        $second = Get-MigrationStateKey -Source source-b -Target target -Database appdb

        $first | Should -Not -Be $second
    }

    It 'creates collision-resistant backup names for database names that contain path characters' {
        $first = Get-MigrationBackupPath -Directory 'C:\backups' -Source source -Target target -Database 'finance/archive'
        $second = Get-MigrationBackupPath -Directory 'C:\backups' -Source source -Target target -Database 'finance:archive'

        (Split-Path -Leaf $first) | Should -Not -Match '[\\/:*?"<>|]'
        $first | Should -Not -Be $second
    }

    It 'creates a unique sanitized per-source run backup directory' {
        $first = Get-MigrationRunBackupDirectory -RootDirectory '\\backup\sql' -Source 'source/one' -Target 'target' -RunId ([guid]::NewGuid())
        $second = Get-MigrationRunBackupDirectory -RootDirectory '\\backup\sql' -Source 'source/one' -Target 'target' -RunId ([guid]::NewGuid())

        $first | Should -Match '^\\\\backup\\sql\\migration-source_one-to-target-'
        $first | Should -Not -Be $second
    }

    It 'creates isolated database backup directories within the run folder' {
        $runDirectory = '\\backup\sql\migration-source-to-target-0123456789abcdef0123456789abcdef'
        $first = Get-MigrationDatabaseBackupDirectory -RunDirectory $runDirectory -Source source -Target target -Database first
        $second = Get-MigrationDatabaseBackupDirectory -RunDirectory $runDirectory -Source source -Target target -Database second
        $repeat = Get-MigrationDatabaseBackupDirectory -RunDirectory $runDirectory -Source source -Target target -Database first

        (Split-Path -Parent $first) | Should -Be $runDirectory
        $first | Should -Not -Be $second
        $repeat | Should -Be $first
    }

    It 'deletes only a matching per-run backup directory' {
        $root = Join-Path $TestDrive 'backups'
        $null = New-Item -ItemType Directory -Path $root
        $runDirectory = Get-MigrationRunBackupDirectory -RootDirectory $root -Source source -Target target -RunId ([guid]::NewGuid())
        $null = New-Item -ItemType Directory -Path $runDirectory
        'stripe' | Set-Content -LiteralPath (Join-Path $runDirectory 'appdb-1-of-4.bak')
        $unrelatedDirectory = Join-Path $root 'keep'
        $null = New-Item -ItemType Directory -Path $unrelatedDirectory

        Remove-MigrationRunBackupDirectory -RootDirectory $root -Directory $runDirectory -Source source -Target target | Should -BeTrue
        Test-Path -LiteralPath $runDirectory | Should -BeFalse
        Test-Path -LiteralPath $unrelatedDirectory | Should -BeTrue
        { Remove-MigrationRunBackupDirectory -RootDirectory $root -Directory $root -Source source -Target target } | Should -Throw '*Refusing to remove backup path*'
    }
}

Describe 'Migration progress events' {
    It 'writes atomic structured events for live monitoring' {
        $progressPath = Join-Path $TestDrive 'progress'
        Write-MigrationProgressEvent -ProgressPath $progressPath -Source source -Target target `
            -Database appdb -Stage Restore -Status Started -Message 'Restore started.'

        $eventFiles = @(Get-ChildItem -LiteralPath $progressPath -Filter '*.json' -File)
        $eventFiles.Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $progressPath -Filter '*.tmp' -File).Count | Should -Be 0
        $event = Get-Content -LiteralPath $eventFiles[0].FullName -Raw | ConvertFrom-Json
        $event.Source | Should -Be 'source'
        $event.Target | Should -Be 'target'
        $event.Database | Should -Be 'appdb'
        $event.Stage | Should -Be 'Restore'
        $event.Status | Should -Be 'Started'
        $event.Message | Should -Be 'Restore started.'
        $event.PercentComplete | Should -Be 0
        $planProgressPath = Join-Path $TestDrive 'plan-progress'
        Write-MigrationProgressEvent -ProgressPath $planProgressPath -Source '' -Target '' `
            -Stage Migration -Status Completed -Message 'Sequential migration run completed.'
        $planEventPath = (Get-ChildItem -LiteralPath $planProgressPath -Filter '*.json' -File).FullName
        $planEvent = Get-Content -LiteralPath $planEventPath -Raw | ConvertFrom-Json
        $planEvent.Source | Should -Be ''
        $planEvent.Target | Should -Be ''
        $planEvent.Stage | Should -Be 'Migration'
        $planEvent.PercentComplete | Should -Be 100
        { Write-MigrationProgressEvent -ProgressPath $progressPath -Source source -Target target -Stage Restore -Status Invalid } |
            Should -Throw
    }

    It 'honors a stop request at a safe checkpoint' {
        $controlPath = Join-Path $TestDrive 'control.json'
        $progressPath = Join-Path $TestDrive 'control-progress'
        Set-Content -LiteralPath $controlPath -Value '{"Action":"Stop"}'

        (Wait-MigrationControl -ControlPath $controlPath -ProgressPath $progressPath `
            -Source source -Target target -HonorStop) | Should -BeFalse
        $event = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $progressPath -Filter '*.json').FullName -Raw |
            ConvertFrom-Json
        $event.Status | Should -Be 'Stopped'
    }

    It 'waits while paused and resumes at the next checkpoint' {
        $controlPath = Join-Path $TestDrive 'pause-control.json'
        $progressPath = Join-Path $TestDrive 'pause-progress'
        Set-Content -LiteralPath $controlPath -Value '{"Action":"Pause"}'
        $modulePath = Join-Path $PSScriptRoot '..\src\DbMigration.Core.psm1'
        $job = Start-Job -ArgumentList $modulePath, $controlPath, $progressPath -ScriptBlock {
            param($module, $control, $progress)
            Import-Module $module -Force
            Wait-MigrationControl -ControlPath $control -ProgressPath $progress -Source source -Target target
        }
        try {
            $pauseDeadline = [DateTime]::UtcNow.AddSeconds(10)
            $pausedEventFound = $false
            while (-not $pausedEventFound -and [DateTime]::UtcNow -lt $pauseDeadline) {
                $pausedEventFound = @(
                    Get-ChildItem -LiteralPath $progressPath -Filter '*.json' -File -ErrorAction SilentlyContinue |
                        ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).Status } |
                        Where-Object { $_ -eq 'Paused' }
                ).Count -gt 0
                if (-not $pausedEventFound) {
                    Start-Sleep -Milliseconds 50
                }
            }
            $pausedEventFound | Should -BeTrue -Because 'the job must reach the pause checkpoint before it is resumed'
            Set-Content -LiteralPath $controlPath -Value '{"Action":"Resume"}'
            (Receive-Job -Job $job -Wait -AutoRemoveJob) | Should -BeTrue
            $statuses = @(Get-ChildItem -LiteralPath $progressPath -Filter '*.json' |
                ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).Status })
            $statuses | Should -Contain 'Paused'
            $statuses | Should -Contain 'InProgress'
        }
        finally {
            if ($job.State -in @('Running', 'NotStarted')) { Stop-Job -Job $job -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Migration reports' {
    It 'writes valid CSV content when there are no rows to report' {
        $outputPath = Join-Path $TestDrive 'reports'

        $report = Write-MigrationReports -Rows @() -OutputPath $outputPath -Name 'Validation'

        $report.CsvPath | Should -Exist
        $report.HtmlPath | Should -Exist
        $csvContent = Get-Content -LiteralPath $report.CsvPath -Raw
        $csvContent | Should -Match 'Message'
        $csvContent | Should -Match 'No records'
    }

    It 'creates management-friendly HTML with styled status summaries' {
        $outputPath = Join-Path $TestDrive 'management-reports'
        $rows = @(
            [pscustomobject]@{ Source = 'source'; Target = 'target'; Database = 'AppDb'; Stage = 'Restore'; Status = 'Failed'; Message = 'Restore failed.' },
            [pscustomobject]@{ Source = 'source'; Target = 'target'; Database = 'AppDb'; Stage = 'Validate'; Status = 'Completed'; Message = 'Validation passed.' }
        )

        $report = Write-MigrationReports -Rows $rows -OutputPath $outputPath -Name 'Migration'
        $html = Get-Content -LiteralPath $report.HtmlPath -Raw

        $html | Should -Match '<style>'
        $html | Should -Match 'summary-card'
        $html | Should -Match 'status-fail'
        $html | Should -Match 'status-pass'
    }
}

Describe 'Application installation' {
    It 'installs the app bundle in a stable location and cleans up correctly' {
        $installRoot = Join-Path $TestDrive 'DbMigrationTool'

        & (Join-Path $PSScriptRoot '..\Install-DbMigrationWeb.ps1') -CurrentUser -InstallPath $installRoot -NoDesktopShortcut -NoStartMenuShortcut

        Test-Path -LiteralPath (Join-Path $installRoot 'Start-PortableDbMigrationWeb.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $installRoot 'Start-DbMigrationWeb.cmd') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $installRoot 'appinfo.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $installRoot 'portable\auth') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $installRoot 'portable\logs') | Should -BeTrue

        & (Join-Path $PSScriptRoot '..\Uninstall-DbMigrationWeb.ps1') -InstallPath $installRoot

        Test-Path -LiteralPath $installRoot | Should -BeFalse
    }
}

Describe 'Database filtering' {
    It 'excludes system databases and configured exclusions' {
        Mock Get-DbaDatabase -ModuleName DbMigration.Core {
            @(
                [pscustomobject]@{ Name = 'master'; IsSystemObject = $true }
                [pscustomobject]@{ Name = 'tempdb'; IsSystemObject = $true }
                [pscustomobject]@{ Name = 'keep'; IsSystemObject = $false }
                [pscustomobject]@{ Name = 'exclude-me'; IsSystemObject = $false }
            )
        }
        $config = @{ ExcludeDatabases = @('exclude-me') }

        $databases = @(Get-MigrationDatabase -SqlInstance source -Configuration $config)

        $databases.Name | Should -Be @('keep')
    }

    It 'returns only explicitly selected databases when an include list is configured' {
        Mock Get-DbaDatabase -ModuleName DbMigration.Core {
            @(
                [pscustomobject]@{ Name = 'keep'; IsSystemObject = $false }
                [pscustomobject]@{ Name = 'also-keep'; IsSystemObject = $false }
            )
        }
        $config = @{ ExcludeDatabases = @(); IncludeDatabases = @('also-keep') }

        $databases = @(Get-MigrationDatabase -SqlInstance source -Configuration $config)

        $databases.Name | Should -Be @('also-keep')
    }

    It 'checks whether a database exists on the specified SQL instance' {
        Mock Get-DbaDatabase -ModuleName DbMigration.Core {
            @(
                [pscustomobject]@{ Name = 'present'; Status = 'Normal'; IsAccessible = $true; IsSystemObject = $false }
                [pscustomobject]@{ Name = 'other'; Status = 'Normal'; IsAccessible = $true; IsSystemObject = $false }
            )
        }

        Test-MigrationDatabaseExists -SqlInstance target -Database present | Should -BeTrue
        Test-MigrationDatabaseExists -SqlInstance target -Database missing | Should -BeFalse
    }

    It 'does not treat an inaccessible target database as missing' {
        Mock Get-DbaDatabase -ModuleName DbMigration.Core {
            @([pscustomobject]@{ Name = 'present'; Status = 'Offline'; IsAccessible = $false })
        }

        { Test-MigrationDatabaseExists -SqlInstance target -Database present } | Should -Throw '*not online and accessible*'
    }
}

Describe 'Database discovery details' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.Discovery.psm1') -Force
        Mock Get-DbaDatabase -ModuleName DbMigration.Core {
            @([pscustomobject]@{
                Name = 'appdb'
                IsSystemObject = $false
                Status = 'Normal'
                IsAccessible = $true
                SizeMB = 2048
                Compatibility = 'Version150'
                RecoveryModel = 'Full'
            })
        }
        Mock Connect-DbaInstance -ModuleName DbMigration.Discovery {
            [pscustomobject]@{ ComputerName = if ($SqlInstance -eq 'source') { 'source-host' } else { 'target-host' } }
        }
        Mock Get-DbaDiskSpace -ModuleName DbMigration.Discovery {
            @(
                [pscustomobject]@{ Name = 'D:\'; SizeInGB = 500; FreeInGB = 100; PercentFree = 20 }
                [pscustomobject]@{ Name = 'L:\'; SizeInGB = 300; FreeInGB = 50; PercentFree = 16.67 }
            )
        }
        Mock Get-DbaDefaultPath -ModuleName DbMigration.Discovery {
            [pscustomobject]@{ Data = 'D:\Data'; Log = 'L:\Logs' }
        }
        Mock Get-DbaLogin -ModuleName DbMigration.Discovery {
            @([pscustomobject]@{ Name = 'login1' }, [pscustomobject]@{ Name = 'login2' })
        }
        Mock Get-DbaLinkedServer -ModuleName DbMigration.Discovery {
            @([pscustomobject]@{ Name = 'linked1' })
        }
        Mock Get-DbaAgentJob -ModuleName DbMigration.Discovery {
            @([pscustomobject]@{ Name = 'job1' }, [pscustomobject]@{ Name = 'job2' }, [pscustomobject]@{ Name = 'job3' })
        }
        Mock Get-DbaDbFile -ModuleName DbMigration.Discovery {
            @(
                [pscustomobject]@{ TypeDescription = 'ROWS'; LogicalName = 'appdb'; PhysicalName = 'D:\Data\appdb.mdf'; Size = [pscustomobject]@{ Byte = 2GB } }
                [pscustomobject]@{ TypeDescription = 'LOG'; LogicalName = 'appdb_log'; PhysicalName = 'L:\Logs\appdb.ldf'; Size = [pscustomobject]@{ Byte = 1GB } }
            )
        }
    }

    It 'reports database size, file locations, compatibility, and source and target volume space' {
        $configuration = @{
            SourceTargets = @(@{ Source = 'source'; Target = 'target' })
            ExcludeDatabases = @()
        }

        $result = @(Get-MigrationDiscovery -Configuration $configuration)[0]

        $result.Database | Should -Be 'appdb'
        $result.SizeMB | Should -Be 2048
        $result.SizeGB | Should -Be 2
        $result.SourceLoginCount | Should -Be 2
        $result.SourceLinkedServerCount | Should -Be 1
        $result.SourceAgentJobCount | Should -Be 3
        $result.CompatibilityLevel | Should -Be 'Version150'
        $result.CompatibilityLevelNumber | Should -Be 150
        $result.DataFileLocations | Should -Match 'D:\\Data\\appdb\.mdf'
        $result.LogFileLocations | Should -Match 'L:\\Logs\\appdb\.ldf'
        $result.SourceVolumeSpace | Should -Match '500 GB total, 100 GB free'
        $result.TargetDataFreeGB | Should -Be 100
        $result.TargetLogFreeGB | Should -Be 50
    }

    It 'fails capacity preflight when the target volumes cannot fit the database files with buffer' {
        Mock Get-DbaDbFile -ModuleName DbMigration.Discovery {
            @(
                [pscustomobject]@{ TypeDescription = 'ROWS'; Size = [pscustomobject]@{ Byte = 200GB } }
                [pscustomobject]@{ TypeDescription = 'LOG'; Size = [pscustomobject]@{ Byte = 60GB } }
            )
        }

        $result = Test-MigrationRestoreCapacity -Source source -Target target -Database large -BufferPercent 20

        $result.Status | Should -Be 'Failed'
        $result.DataRequiredWithBufferGB | Should -Be 240
        $result.LogRequiredWithBufferGB | Should -Be 72
    }
}

Describe 'Database backup stripes' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.Transfer.psm1') -Force
    }

    It 'exports the tracked operation helper and supports the built-in job in a parallel runspace' {
        $moduleDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..\src')).Path

        $result = 'probe' | ForEach-Object -Parallel {
            Import-Module (Join-Path $using:moduleDirectory 'DbMigration.Core.psm1') -Force
            Import-Module (Join-Path $using:moduleDirectory 'DbMigration.Transfer.psm1') -Force
            $helper = (Get-Command Invoke-MigrationTrackedDatabaseOperation -ErrorAction Stop).Name
            $job = Start-Job -ScriptBlock { 'background-job-ok' }
            Wait-Job -Job $job -Timeout 10 | Out-Null
            $jobResult = Receive-Job -Job $job -ErrorAction Stop
            Remove-Job -Job $job -Force -ErrorAction Stop
            "$helper|$jobResult"
        } -ThrottleLimit 1

        $result | Should -Be 'Invoke-MigrationTrackedDatabaseOperation|background-job-ok'
    }

    It 'returns exactly the requested database stripe files in stripe order' {
        $directory = Join-Path $TestDrive 'isolated-stripes'
        $null = New-Item -ItemType Directory -Path $directory
        foreach ($stripe in @(4, 2, 1, 3)) {
            Set-Content -LiteralPath (Join-Path $directory "appdb_202610061200-$stripe-of-4.bak") -Value 'stripe'
        }

        $files = @(Get-MigrationBackupStripeFiles -Directory $directory -Database appdb -FileCount 4)

        $files.Count | Should -Be 4
        @($files | ForEach-Object Name) | Should -Be @(
            'appdb_202610061200-1-of-4.bak',
            'appdb_202610061200-2-of-4.bak',
            'appdb_202610061200-3-of-4.bak',
            'appdb_202610061200-4-of-4.bak'
        )
    }

    It 'rejects shared folders containing another database backup' {
        $directory = Join-Path $TestDrive 'mixed-stripes'
        $null = New-Item -ItemType Directory -Path $directory
        foreach ($database in @('appdb', 'otherdb')) {
            for ($stripe = 1; $stripe -le 4; $stripe++) {
                Set-Content -LiteralPath (Join-Path $directory "${database}_202610061200-$stripe-of-4.bak") -Value 'stripe'
            }
        }

        @(Get-MigrationBackupStripeFiles -Directory $directory -Database appdb -FileCount 4).Count |
            Should -Be 0
    }
}

Describe 'Server object migration' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.PostMigration.psm1') -Force
    }

    It 'copies logins without sa, agent jobs, and operators' {
        Mock Copy-DbaLogin -ModuleName DbMigration.PostMigration
        Mock Copy-DbaAgentJob -ModuleName DbMigration.PostMigration
        Mock Copy-DbaAgentOperator -ModuleName DbMigration.PostMigration

        Invoke-ServerObjectMigration -Pair @{ Source = 'source'; Target = 'target' }

        Should -Invoke Copy-DbaLogin -ModuleName DbMigration.PostMigration -Exactly 1 -ParameterFilter {
            $ExcludeLogin -contains 'sa' -and $Source.FullName -eq 'source' -and $Destination.FullName -contains 'target'
        }
        Should -Invoke Copy-DbaAgentJob -ModuleName DbMigration.PostMigration -Exactly 1 -ParameterFilter {
            $DisableOnDestination -and $Source.FullName -eq 'source' -and $Destination.FullName -contains 'target'
        }
        Should -Invoke Copy-DbaAgentOperator -ModuleName DbMigration.PostMigration -Exactly 1
    }

    It 'copies only the selected server object types' {
        Mock Copy-DbaLogin -ModuleName DbMigration.PostMigration
        Mock Copy-DbaAgentJob -ModuleName DbMigration.PostMigration
        Mock Copy-DbaAgentOperator -ModuleName DbMigration.PostMigration

        Invoke-ServerObjectMigration -Pair @{ Source = 'source'; Target = 'target' } -MigrateLogins $false -MigrateAgentJobs $true -MigrateAgentOperators $false

        Should -Invoke Copy-DbaLogin -ModuleName DbMigration.PostMigration -Exactly 0
        Should -Invoke Copy-DbaAgentJob -ModuleName DbMigration.PostMigration -Exactly 1 -ParameterFilter {
            $DisableOnDestination
        }
        Should -Invoke Copy-DbaAgentOperator -ModuleName DbMigration.PostMigration -Exactly 0
    }
}

Describe 'Linked server configuration' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.PostMigration.psm1') -Force
    }

    It 'maps CSV metadata to dbatools linked-server parameters' {
        $path = Join-Path $TestDrive 'linked.csv'
        'LinkedServer,Provider,Product,DataSource,Catalog,SecurityMode,RemoteUser,PasswordEnvironmentVariable' |
            Set-Content -LiteralPath $path
        'warehouse,MSOLEDBSQL,SQL Server,warehouse.example.com,Analytics,CurrentSecurityContext,,' |
            Add-Content -LiteralPath $path
        Mock New-DbaLinkedServer -ModuleName DbMigration.PostMigration
        Mock Get-DbaLinkedServer -ModuleName DbMigration.PostMigration { @() }

        Invoke-LinkedServerConfiguration -Pair @{ Target = 'target' } -CsvPath $path

        Should -Invoke New-DbaLinkedServer -ModuleName DbMigration.PostMigration -Exactly 1 -ParameterFilter {
            $SqlInstance.FullName -contains 'target' -and $LinkedServer -eq 'warehouse' -and
            $ServerProduct -eq 'SQL Server' -and $SecurityContext -eq 'CurrentSecurityContext'
        }
    }
}

Describe 'Post-migration repair and statistics' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.PostMigration.psm1') -Force
    }

    It 'repairs orphan users and updates database statistics' {
        Mock Repair-DbaDbOrphanUser -ModuleName DbMigration.PostMigration
        Mock Invoke-DbaQuery -ModuleName DbMigration.PostMigration

        Invoke-DatabasePostMigration -SqlInstance target -Database appdb -UpdateStatistics $true

        Should -Invoke Repair-DbaDbOrphanUser -ModuleName DbMigration.PostMigration -Exactly 1
        Should -Invoke Invoke-DbaQuery -ModuleName DbMigration.PostMigration -Exactly 1 -ParameterFilter {
            $Database -eq 'appdb' -and $Query -eq 'EXEC sys.sp_updatestats;'
        }
    }

    It 'can skip statistics updates while still repairing orphan users' {
        Mock Repair-DbaDbOrphanUser -ModuleName DbMigration.PostMigration
        Mock Invoke-DbaQuery -ModuleName DbMigration.PostMigration

        Invoke-DatabasePostMigration -SqlInstance target -Database appdb -UpdateStatistics $false

        Should -Invoke Repair-DbaDbOrphanUser -ModuleName DbMigration.PostMigration -Exactly 1
        Should -Invoke Invoke-DbaQuery -ModuleName DbMigration.PostMigration -Exactly 0
    }

    It 'can skip orphan-user repair and statistics updates' {
        Mock Repair-DbaDbOrphanUser -ModuleName DbMigration.PostMigration
        Mock Invoke-DbaQuery -ModuleName DbMigration.PostMigration

        Invoke-DatabasePostMigration -SqlInstance target -Database appdb -UpdateStatistics $false -RepairOrphanUsers $false

        Should -Invoke Repair-DbaDbOrphanUser -ModuleName DbMigration.PostMigration -Exactly 0
        Should -Invoke Invoke-DbaQuery -ModuleName DbMigration.PostMigration -Exactly 0
    }
}
