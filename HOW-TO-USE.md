# How to use the SQL migration tool

This guide explains how to run the migration framework in the recommended order and how to verify each step before starting a production migration.

## 1. Prerequisites

Before running the tool, make sure you have:

- Windows operating system
- PowerShell 7.2 or later
- dbatools installed for SQL Server discovery and migration
- Pester installed if you want to run the unit tests
- No separate browser UI packages or Node.js installation are required
- Network access from the migration host to the source and target SQL Server instances
- SQL permissions to:
  - read the source databases
  - create or restore databases on the target
  - copy server-level objects such as logins, jobs, and operators
  - repair orphaned users and update statistics if enabled
- Backup paths visible to the SQL Server service accounts and writable by the migration process

Install the required modules when needed:

```powershell
Install-Module dbatools -Scope CurrentUser -Force
Install-Module Pester -Scope CurrentUser -Force
```

## 2. Review the configuration

Open the main configuration file:

```powershell
notepad .\config\migration.config.json
```

Key settings:

- `SourceTargets`: one source/target pair per migration target
- `OutputPath`: folder for generated HTML and CSV reports
- `LinkedServersCsv`: CSV file for linked server definitions
- `ExcludeDatabases`: optional database exclusions
- `ThrottleLimit`: concurrency level for backup/restore operations
- `BackupFileCount`: number of striped files created for each database backup (default 4)
- `RestoreSpaceBufferPercent`: additional target disk headroom required beyond allocated database data/log size; defaults to 20%
- `AllowTargetReplace`: keep `false` for normal operation; the GUI asks individually before replacing any selected target database
- `UpdateStatistics`: enable `sp_updatestats` after migration when needed

Each `SourceTargets` entry should include:

- `Source`: source SQL Server instance name or network address
- `Target`: target SQL Server instance name or network address
- `BackupPath`: network or shared backup directory used by the migration process

Full-data migrations do not change source database contents or settings. The source is read for discovery and a native `COPY_ONLY` backup; restores, user repair, statistics updates, and server-object copies are applied only to the target. SQL Server records native backup history in the source `msdb`. Backup compression and checksumming can consume source CPU and I/O. During browser migrations, live backup/restore percentage, request CPU time, and elapsed time are read from `sys.dm_exec_requests`; this requires `VIEW SERVER STATE` (or `VIEW SERVER PERFORMANCE STATE` on SQL Server 2022). Without that permission, the app reports the telemetry error and continues with elapsed-stage heartbeats.

## 3. Validate the environment

Before running any migration, validate the project and environment:

```powershell
Invoke-Pester .\tests
```

Also check that PowerShell and dbatools are present:

```powershell
$PSVersionTable.PSVersion
Get-Module -ListAvailable dbatools
```

## 4. Run the command-line workflow

From the project directory, run the migration workflow in order:

```powershell
.\Invoke-DbMigration.ps1 -Mode Discover
.\Invoke-DbMigration.ps1 -Mode Validate
.\Invoke-DbMigration.ps1 -Mode Migrate
```

What each mode does:

- `Discover`: identifies eligible user databases and writes reports
- `Validate`: checks connectivity, version compatibility, and backup-share visibility from source and target SQL Server services
- `Migrate`: performs the backup/restore workflow, post-migration tasks, and report generation

The migration preflight compares allocated source data/log file sizes plus the configured buffer to free space on the target's default data/log volumes. It is an estimate, so check for concurrent storage use and expected growth as well. A database is not marked complete until it is confirmed visible, online, and accessible on the target. The GUI reports live database-stage and server-object events in its progress panel and log, including failures. For each selected database already on the target, the GUI asks whether to overwrite it; choosing No skips that database and leaves the existing target untouched. Command-line replacement still requires explicit `AllowTargetReplace` approval.

Each source/target run writes checksummed, compressed, verified full-copy-only backups, striped across `BackupFileCount` files, into a unique per-run folder with a separate child directory for each database. Restore is given only the selected database's stripe files to prevent parallel restores from scanning or locking other databases' files. The run folder is removed only when every enabled migration stage succeeds. If any step fails, the folder is retained for troubleshooting/retry; after a successful retry, retained run folders referenced by the selected database state are removed. This is temporary migration staging, not a backup-retention strategy—keep separate durable backups if recovery policy requires them.

## 5. Supported install path and current status

The verified and supported installation method is the Windows app bundle created by `Install-DbMigrationWeb.ps1`. It creates a stable app folder, desktop shortcut, and Start menu entry and has been validated by the automated test suite (53 passing tests). The app bundle is the supported install path for end users.

A WiX-based MSI/EXE packaging prototype is still under development and remains a separate engineering task. It is not the current recommended distribution path for production use.

## 6. Run the GUI

The GUI is intended for interactive execution on a Windows desktop session:

```powershell
.\Invoke-DbMigrationGui.ps1
```

The GUI allows you to:

- enter the source and target SQL instances
- select a backup directory
- discover databases
- choose specific databases to migrate
- enable or disable server-level migration actions
- start the migration with a confirmation prompt

Copied SQL Agent jobs are disabled on the target to prevent them from running before they are reviewed and explicitly enabled by an administrator.

Important: the GUI intentionally uses the first configured source/target pair from the config and runs the same migration logic as the command-line script.

## 7. Run the browser interface

There are two supported browser modes:

- Server-hosted HTTPS mode for network deployment on a Windows migration server.
- Portable local mode for a single workstation or USB-style deployment without admin privileges.

### Portable local mode

For a local, portable run without machine-level HTTPS registration, use the launcher script:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-PortableDbMigrationWeb.ps1
```

This starts the app on a loopback address such as `http://localhost:9080/` or the next available free local port. It stores auth and logs under the project folder (`portable\auth\auth.json` and `portable\logs`). The default portable credentials are:

- Username: `migration-admin`
- Password: `MigrationAdmin123!`

The launcher automatically creates the authentication file on first run if it is missing.

### Server-hosted HTTPS mode

The browser interface can be used by authorized users on the network while the PowerShell host runs on a Windows migration server. Source, target, and shared backup paths are entered in the browser. Run the following HTTPS setup once with administrative rights, using a DNS name covered by a valid certificate installed in `LocalMachine\My`:

```powershell
.\Register-DbMigrationWebHttps.ps1 `
  -HostName 'db-migration.contoso.com' `
  -Port 8443 `
  -CertificateThumbprint 'CERTIFICATE_THUMBPRINT' `
  -RunAsAccount 'CONTOSO\svc-db-migration'
```

Run credential initialization and the web host as the same dedicated Windows account:

```powershell
.\Initialize-DbMigrationWebAuth.ps1 `
  -Username 'migration-operator' `
  -RunAsAccount 'CONTOSO\svc-db-migration'

.\Invoke-DbMigrationWeb.ps1 `
  -HostName 'db-migration.contoso.com' `
  -Port 8443
```

The setup prompts for the app password (at least 14 characters) and stores only a salted PBKDF2 hash. Open `https://db-migration.contoso.com:8443/` from an authorized client. Restrict the server firewall to intended client systems. SQL Server, backup-share, reports, and migration state operations use the Windows identity running the host; browser users do not delegate their own Windows credentials. Use a least-privilege host identity. Anyone with the dedicated app login can operate all source/target pairs in the configuration.

The browser UI has fields for source SQL instance, target SQL instance, and shared backup directory (use the UNC path visible to both SQL Server service accounts). Add up to three pairs. Select **Remember source, target, and shared backup paths in this browser** to save those connection settings in that browser's local storage; uncheck it to remove the saved settings. This does not write endpoint changes to `config/migration.config.json`.

Discover each pair, select its databases, and review overwrite approvals. The browser workflow runs the pairs sequentially, and each pair's selected databases one at a time. For each database, it runs validation and capacity preflight, performs the backup and restore, verifies target access, runs selected post-migration checks, and deletes that database's temporary backup folder before starting the next database. Server-level objects run after that pair's databases and before the next pair. A failed validation, migration, post-migration action, backup cleanup, or server-object stage stops the sequence; it does not advance to the next database or pair. The command-line and desktop GUI workflows retain their configured concurrency behavior.

### Patch selected SQL instances

The local web app provides an interactive SQL Server patch advisor for configured source/target instances. Migration and local package installation do not require internet access. Refreshing Microsoft/dbatools build metadata and downloading a selected KB require internet access from the app host; updates are not downloaded automatically.

Expand **Patch selected SQL instances**, select endpoints, and choose **Refresh patch catalog**. Select a listed KB, then choose **Assess eligibility** to review installed build/KB, product and service-pack matching, already-installed or superseded status, and support lifecycle for each instance. Only rows marked eligible can be applied. Enter a repository folder accessible to both the app host and target Windows server, then choose **Download selected KB** or stage the matching Microsoft package there yourself. Downloading does not install the package.

Choose **Apply eligible instances** to patch only the currently assessed eligible rows. Selected instances run sequentially and stop at the first failure. SQL Server services may restart as part of patch installation. Restarting the Windows host is a separate option and is off by default. This workflow rejects clustered SQL Server instances; use a cluster-aware patch procedure for those systems. For remote targets, the app identity needs the remote administration permissions required by dbatools and PowerShell remoting. Do not run a patch during a migration, and schedule a maintenance window before starting.

The browser UI shows discovery metadata, a full-data/schema-only mode for every pair, per-database overwrite checkboxes and confirmations, migration options, live run and per-step percentages, and Pause, Resume, and Stop controls. A selected existing target without explicit overwrite approval is skipped. Schema-only mode scripts database objects without copying table data and does not copy linked servers or other server-level objects. An approved schema-only overwrite drops and recreates the existing target database, deleting its data; review each overwrite decision before starting. Linked-server configuration is skipped by default for the entire run; to honor an explicit skip request, leave “Skip linked servers for this run” checked. Pause takes effect at the next safe stage boundary; Resume continues the run. Stop allows the active database or server-object stage to finish safely before preventing later work. Do not stop the web host while the plan is running.

## 8. Review migration results

After a run completes, check:

- the generated CSV and HTML reports in the configured output folder
- `MigrationState.json` in the project directory or the custom state path
- the log output for warnings or failed database records

The GUI discovery list shows each database's size, and its summary shows source login, linked-server, and Agent-job counts. The discovery report also includes these counts, compatibility level, recovery model and state, data/log file locations and file sizes, source volumes' capacity/free space, and the target server's default data/log paths and corresponding volume capacity/free space. Use the target free-space fields to review capacity before restoring; the report does not guarantee future free space or estimate compression and growth.

The state file is designed to support resumable execution. A database is skipped only when the recorded status is `Completed` and the target database is still online and accessible. If the target copy is missing, the tool attempts to reuse the recorded backup or creates a new backup. Failed work remains eligible for retry.

## 9. Recommended safety checklist

Before each migration:

- confirm the source and target SQL Server instances are correct
- confirm the backup share is writable and accessible by SQL Server service accounts
- review capacity preflight against expected growth, restore staging, and storage use by other applications
- confirm the target database names are expected and safe to replace
- verify `-WithReplace` behavior is acceptable for the target environment
- confirm linked server data is correct in the CSV file
- review any selected server-level object migration options
- validate orphan-user repair and statistics updates are appropriate for the target workload

## 10. Example

Example discovery and validation flow:

```powershell
.\Invoke-DbMigration.ps1 -Mode Discover
.\Invoke-DbMigration.ps1 -Mode Validate
```

Example migrate flow:

```powershell
.\Invoke-DbMigration.ps1 -Mode Migrate -ConfigPath .\config\migration.config.json -StatePath .\MigrationState.json -OutputPath .\reports
```

## 11. Troubleshooting

If a migration fails, check the following:

- is PowerShell 7 installed?
- is dbatools installed and importable?
- can the host reach the source and target SQL instances?
- do the service accounts have permission to write to the backup directory?
- does the target instance have permission to restore the databases?
- are the configured database exclusions correct?
- does the output folder exist and have write permissions?

When needed, fix the configuration and rerun the migration; the framework records progress and supports resume behavior for completed or partially completed work.
