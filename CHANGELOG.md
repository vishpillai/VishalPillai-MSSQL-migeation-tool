# Changelog

Notable changes to the SQL Server migration tool are documented here. Versions
follow semantic versioning.

## 1.1.0 - 2026-10-07

Portable web mode and launcher improvements.

- Added a portable local browser mode that stores auth and logs under the app
  folder instead of `%ProgramData%`.
- Added `Start-PortableDbMigrationWeb.ps1` to launch the browser app without
  machine-level HTTPS setup or admin rights.
- Added local loopback-only handling for portable mode and automatic selection
  of a free local port.
- Kept the secure production HTTPS workflow intact for server-hosted use.
- Expanded tests and functional validation for portable web storage and startup
  behavior.

## 1.0.0 - 2026-10-06

Initial published application release.

- Added PowerShell and dbatools workflows for database discovery, validation,
  backup, restore, and post-migration checks.
- Added a secure HTTPS browser interface with sequential migration plans,
  per-database overwrite decisions, pause/resume/stop controls, and live
  progress events.
- Added full-data and schema-only migration modes.
- Added isolated striped backups, capacity preflight, migration state, and
  HTML/CSV reports.
- Added source-side `COPY_ONLY` backup behavior and documented its backup
  history, CPU, and I/O effects.
- Added automated tests and operational documentation.
