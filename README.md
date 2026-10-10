# dbatools SQL Server migration framework

**Version:** 1.0.0 — see [CHANGELOG.md](CHANGELOG.md) for release history.

A modular PowerShell 7 framework for migrating user databases from SQL Server 2012, 2016, and 2019 to SQL Server 2022. It supports multiple source/target pairs, parallel database backup/restore, resumable execution, discovery and validation, server-level objects, linked servers, post-migration repair/statistics, and CSV/HTML reports.

## Requirements

- PowerShell 7.2 or later.
- dbatools (`Install-Module dbatools -Scope CurrentUser`), required for SQL Server discovery, migration, and related operations.
- Pester 5 for tests (`Install-Module Pester -Scope CurrentUser -Force`).
- The browser UI uses built-in HTML, CSS, and JavaScript; it does not require Node.js, npm, a frontend framework, or CDN access.
- Network connectivity from the PowerShell host to SQL Server instances and required backup shares. Migration operations are local/on-prem and do not require internet access; only optional patch-catalog refresh and package download use the internet.
- Backup paths accessible to the SQL Server service accounts on both source and target. Provide an isolated path for each source/target pair.
- Permissions to read source databases, create/restore target databases, copy server objects, repair users, and update statistics.

Authentication uses the current Windows security context/dbatools connection defaults. No passwords are stored in the JSON configuration. Remote linked-server credentials, when needed, are read from the environment variable named by `PasswordEnvironmentVariable` in the CSV.

## Validation and troubleshooting

The project includes a unit-test suite and a PowerShell parser validation path for the migration scripts. Run the tests from the project directory:

```powershell
Invoke-Pester .\tests
```

The GUI script is Windows-only and must run under PowerShell 7. Validate the environment before launching it:

```powershell
$PSVersionTable.PSVersion
Get-Module -ListAvailable dbatools
```

If `dbatools` is not available, install it first:

```powershell
Install-Module dbatools -Scope CurrentUser -Force
```

The GUI and CLI both expect SQL connectivity, appropriate permissions, and valid backup paths. If a migration run fails, review the state file and generated reports in the configured output folder before retrying.

## Configure

Edit `config/migration.config.json`:

- `SourceTargets`: one entry per source/target pair; source major versions 11, 13, and 15 are accepted, and targets must be major version 16.
- `BackupPath`: a shared path visible to SQL Server services. Use separate folders per pair to avoid backup-name collisions.
- `ExcludeDatabases`: optional additional database names. `master`, `model`, `msdb`, and `tempdb` are always excluded.
- `ThrottleLimit`: number of databases backed up/restored concurrently.
- `BackupFileCount`: number of striped backup files per database; defaults to 4 (valid range 1–32).
- `RestoreSpaceBufferPercent`: extra free-space buffer required beyond current data/log file allocation before a restore is allowed; defaults to 20%.
- `AllowTargetReplace`: defaults to `false`; command-line replacement must be explicitly enabled. The GUI instead asks Yes/No for each selected database already on the target; answering No skips that database without changing the target.
- `OutputPath`: destination for generated HTML and CSV reports.
- `LinkedServersCsv`: linked-server definition CSV path.

Configure `config/LinkedServers.csv` with one linked server per row. Required columns are `LinkedServer`, `Provider`, `Product`, `DataSource`, and `SecurityMode`. `SecurityMode` must be `NoConnection`, `WithoutSecurityContext`, `CurrentSecurityContext`, or `SpecifiedSecurityContext`. `Catalog`, `RemoteUser`, and `PasswordEnvironmentVariable` are optional. For a remote login, select `SpecifiedSecurityContext`, set `RemoteUser` and the name of an environment variable containing the password; do not put the password itself in the CSV.

## Run

Run the script from the project directory (or provide absolute paths):

```powershell
.\Invoke-DbMigration.ps1 -Mode Discover
.\Invoke-DbMigration.ps1 -Mode Validate
.\Invoke-DbMigration.ps1 -Mode Migrate
```

For an interactive Windows desktop interface, run:

```powershell
.\Invoke-DbMigrationGui.ps1
```

For a network-accessible browser interface, see [Network browser interface](#network-browser-interface). It uses HTTPS and a dedicated application login; enter up to three source/target pairs in the browser.

The GUI starts with the first source/target pair from the configuration. Enter or edit the instances and backup path, discover databases, then check the databases and server-level objects to migrate. It runs the same migration script and writes its normal reports and state file. During migration, a live progress panel reports per-database backup, restore, capacity, post-migration, and final outcome events, plus server-object copy results and errors; the detailed log remains available alongside the summary. If a selected database already exists on the target, the GUI asks whether to replace it; Yes authorizes replacement of that database, while No records it as skipped and leaves the target unchanged. The GUI requires Windows, PowerShell 7, and dbatools.

## Network browser interface and portable mode

The browser UI is hosted by `Invoke-DbMigrationWeb.ps1` on Windows PowerShell 7.2 or later. It supports entering up to three source/target/shared-backup-path pairs, selecting full-data or schema-only mode per pair, discovery, per-database overwrite approval, server-level migration options, and live stage/outcome/error monitoring. Source, target, backup path, and pair mode can be remembered in that browser's local storage. Those browser settings do not alter `config/migration.config.json`.

The web UI includes an interactive patch advisor for configured SQL instances. Refresh the SQL build catalog, select a KB from the update dropdown, and assess each server's product build, service-pack branch, installed KB, patch compatibility, and support lifecycle before downloading or applying. Download uses dbatools `Get-DbaKbUpdate`/`Save-DbaKbUpdate` to retrieve the selected package from Microsoft; it is not installed until Apply is confirmed. Alternatively, stage packages yourself and use the same local repository path. The repository must be accessible to the app host and target Windows server, and the app identity needs remote-administration permissions. SQL services can restart during patching. A Windows host restart is optional and off by default. Clustered SQL Server instances are deliberately rejected; patch them with a cluster-aware process.

## Installable Windows app

The verified and supported distribution path is the Windows app bundle created by `Install-DbMigrationWeb.ps1`. This has been smoke-tested and validated through the automated Pester suite and installs a local app folder, desktop shortcut, and Start menu shortcut without requiring a manual PowerShell launch each time.

Status: the project has passed 53 automated tests covering configuration, install/uninstall behavior, portable app storage, patch catalog and eligibility safeguards, and migration logic. A WiX-based MSI/EXE packaging prototype is still experimental and is not the currently supported production artifact.

Install for the current user:

```powershell
.\Install-DbMigrationWeb.ps1 -CurrentUser
```

Install machine-wide (requires elevation):

```powershell
.\Install-DbMigrationWeb.ps1
```

Use a custom install folder:

```powershell
.\Install-DbMigrationWeb.ps1 -InstallPath 'C:\Tools\DbMigrationTool'
```

To uninstall later:

```powershell
.\Uninstall-DbMigrationWeb.ps1
```

This installer creates a runnable Windows app bundle with shortcuts and is the current supported deployment path. A native MSI/EXE package is still a separate WiX packaging experiment and should not be treated as the production distribution yet.

For a local portable run without machine-level HTTPS registration, use `Start-PortableDbMigrationWeb.ps1`:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-PortableDbMigrationWeb.ps1
```

This launches the app on a loopback address such as `http://localhost:9080/` or the next free local port and stores auth and logs in the project folder under `portable\auth` and `portable\logs`. The default portable login is `migration-admin` / `MigrationAdmin123!`.

The web migration plan runs source/target pairs in order and databases within each pair one at a time. Full-data mode runs the regular preflight, backup/restore, restore-access check, enabled post-migration actions, and temporary backup cleanup for each database. Source database contents and settings are not modified: the source is read for discovery and a `COPY_ONLY` backup; restores, schema changes, user repair, statistics updates, and server-object copies are applied only to the target. SQL Server records native backup history in the source `msdb`, and backup compression/checksum work can consume source CPU and I/O. The monitor polls SQL Server request progress during backup and restore; this telemetry requires permission to read `sys.dm_exec_requests` (`VIEW SERVER STATE`, or `VIEW SERVER PERFORMANCE STATE` on SQL Server 2022). If that permission is unavailable, the UI reports that percentage telemetry is unavailable and continues showing elapsed-stage heartbeats.

Schema-only mode uses SMO scripting/transfer with data copying disabled, creates a new target database using the source collation and recovery model, and verifies the destination is online with zero user-table rows. It does not copy server-level objects such as linked servers, logins, or Agent jobs, and does not require the shared backup path. If a schema-only target already exists, it is left unchanged unless overwrite is explicitly approved for that database; an approved overwrite drops and recreates that target database, permanently removing its existing data. Review the per-database overwrite list carefully. The web UI defaults to skipping linked-server configuration for the entire run; it must be explicitly unchecked before the separate configure-linked-servers option can be enabled. The next database starts only after its mode-specific checks complete. A reported stage failure stops the sequence. Other server-level objects run after the databases for full-data pairs and before the next pair. Pause takes effect at a safe stage boundary. Stop lets the active database or server-object stage finish safely, then prevents later work from starting. This sequential mode overrides `ThrottleLimit` for browser migration throughput; the command-line workflow is unchanged.

The app requires a DNS name and a currently valid certificate with that name in its DNS SAN, installed in `LocalMachine\My`. Register its HTTPS binding and URL reservation from an elevated PowerShell session:

```powershell
.\Register-DbMigrationWebHttps.ps1 `
  -HostName 'db-migration.contoso.com' `
  -Port 8443 `
  -CertificateThumbprint 'CERTIFICATE_THUMBPRINT' `
  -RunAsAccount 'CONTOSO\svc-db-migration'
```

Create the dedicated application login while running as the same Windows account that will host the app:

```powershell
.\Initialize-DbMigrationWebAuth.ps1 `
  -Username 'migration-operator' `
  -RunAsAccount 'CONTOSO\svc-db-migration'
```

The password is prompted securely and stored as a salted PBKDF2-SHA256 hash in `%ProgramData%\DbMigrationWeb\auth.json`, with access restricted to the host account, SYSTEM, and local administrators. Start the host as that Windows account:

```powershell
.\Invoke-DbMigrationWeb.ps1 `
  -HostName 'db-migration.contoso.com' `
  -Port 8443
```

Open `https://db-migration.contoso.com:8443/` from an authorized client. Restrict inbound firewall access to the intended client network. The browser login controls access to the migration UI; SQL connections and file/report access run under the Windows identity hosting the web app, not the browser user's Windows identity. Run the host under a dedicated least-privilege account with only the required SQL and file permissions. All users of this dedicated application login can operate every configured migration pair. The app uses an HTTPS-only, HttpOnly/SameSite session cookie, enforces same-origin POST requests, limits login attempts, and does not provide unauthenticated endpoints for migration actions.

Do not stop the web host while a migration is running. It does not offer a cancellation control because terminating a backup or restore mid-operation can leave work requiring investigation. Review the normal migration reports and state file when the run completes.

Modes:

- `Discover`: inventories eligible user databases on each source and writes HTML/CSV reports with database size, source login/linked-server/Agent-job counts, compatibility and recovery settings, data/log file locations, source volume capacity/free space, and target default data/log volume capacity/free space.
- `Validate`: checks connectivity, configured source/target SQL Server versions, and visibility of each backup path from both SQL Server services.
- `Migrate`: runs validation first, then backs up and restores eligible databases in parallel; copies logins except `sa`, copies SQL Agent jobs disabled on the target, and copies operators; creates configured linked servers; repairs orphan users; and runs `sp_updatestats` when enabled.

When using the GUI, the selected database list and object checkboxes limit those migration actions for that run. Existing command-line runs retain their configured behavior.

`MigrationState.json` is created in the project directory by default. A database is skipped on rerun only when the state says `Completed` and the target database is still online and accessible. If the target is missing, the tool reuses a recorded backup when available or takes a new one. Failed work is recorded and is eligible for retry. Override the location with `-StatePath`; override reports destination with `-OutputPath`.

Database migration uses full, copy-only, checksummed, compressed backups, verifies each backup, and stripes it across `BackupFileCount` files. Each source/target migration run writes to a uniquely named folder, with a separate child folder per database so parallel workers cannot read or lock each other's backup stripes. Restore is given only that database's explicit stripe-file list. The run folder is deleted only after database transfer and all enabled migration stages for the pair succeed. If any stage fails, the folder is retained for retry and investigation. On a later successful retry, retained run folders referenced by the selected database state are cleaned up. This cleanup means successful temporary backups are not retained for disaster recovery; configure a separate durable backup/retention process if required.

Review the target and backup-path configuration carefully before running migration mode.

Before starting each database transfer, migration compares the source data/log file allocations (plus `RestoreSpaceBufferPercent`) with free space on the target's default data and log volumes. Capacity checks are estimates, not guarantees: concurrent storage use and file growth can reduce available space after preflight. A target database is only recorded as completed after it is visible, online, and accessible. Existing target databases are not replaced by command-line runs unless `AllowTargetReplace` is explicitly enabled.

For production, retain migration reports, state files, and logs according to your organization's retention policy; protect them because they contain server names, database names, paths, and operational details. Test backup restoration and application behavior in a representative non-production environment before production cutover. This framework provides operational safeguards but does not by itself certify compliance with any regulatory or industry standard.

## Tests

From the project directory:

```powershell
Invoke-Pester .\tests
```

The tests cover configuration validation, backup stripe settings and per-run folders, state persistence/resume data, migration state key separation, database exclusions and selection, inaccessible-target handling, discovery/capacity reporting, server-object selection, and post-migration actions. SQL Server integration tests require a separately configured test environment and are not run by this unit test suite.
