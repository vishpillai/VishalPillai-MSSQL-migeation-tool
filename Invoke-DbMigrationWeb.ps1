[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$')][string] $HostName,
    [Parameter()][ValidateRange(1, 65535)][int] $Port = 8443,
    [Parameter()][string] $ConfigPath = (Join-Path $PSScriptRoot 'config\migration.config.json'),
    [Parameter()][string] $StatePath = (Join-Path $PSScriptRoot 'MigrationState.json'),
    [Parameter()][switch] $PortableMode,
    [Parameter()][string] $AppRoot = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [Version]'7.2') {
    throw 'PowerShell 7.2 or later is required.'
}
Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.WebAuth.psm1') -Force
$storage = Resolve-MigrationWebStoragePaths -AppRoot $AppRoot -PortableMode:$PortableMode
$fullConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$fullAuthPath = $storage.AuthPath
$fullStatePath = [System.IO.Path]::GetFullPath($StatePath)
foreach ($path in @($fullConfigPath, $fullAuthPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file not found: $path"
    }
}

Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.Discovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.WebAuth.psm1') -Force
Import-Module dbatools -ErrorAction Stop
$script:WebConfiguration = Import-MigrationConfiguration -Path $fullConfigPath
$script:AuthRecord = Get-Content -LiteralPath $fullAuthPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
foreach ($property in @('Salt', 'PasswordHash', 'Iterations', 'Username')) {
    if (-not $script:AuthRecord.Contains($property)) {
        throw "Authentication record is missing '$property'. Re-run Initialize-DbMigrationWebAuth.ps1."
    }
}

if (-not ('DbMigration.Web.ProcessOutputLine' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Threading;

namespace DbMigration.Web
{
    public sealed class ProcessOutputLine
    {
        public string Status { get; }
        public string Message { get; }

        public ProcessOutputLine(string status, string message)
        {
            Status = status;
            Message = message;
        }
    }

    public sealed class ProcessOutputHandler
    {
        private readonly ConcurrentQueue<ProcessOutputLine> queue;
        private int droppedLines;

        public ProcessOutputHandler(ConcurrentQueue<ProcessOutputLine> queue)
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
                Enqueue(new ProcessOutputLine("InProgress", eventArgs.Data));
        }

        private void OnErrorDataReceived(object sender, DataReceivedEventArgs eventArgs)
        {
            if (eventArgs.Data != null)
                Enqueue(new ProcessOutputLine("Failed", eventArgs.Data));
        }

        private void Enqueue(ProcessOutputLine line)
        {
            queue.Enqueue(line);
            while (queue.Count > 1000)
            {
                ProcessOutputLine discarded;
                if (!queue.TryDequeue(out discarded))
                    break;
                Interlocked.Increment(ref droppedLines);
            }
        }

        public int ConsumeDroppedLines()
        {
            return Interlocked.Exchange(ref droppedLines, 0);
        }
    }
}
'@
}

$script:HostName = $HostName.ToLowerInvariant()
$script:Port = $Port
$script:PortableMode = [bool]$PortableMode
$script:UseSecureTransport = -not $script:PortableMode
$script:Origin = if ($script:PortableMode) { "http://$($script:HostName):$Port" } elseif ($Port -eq 443) { "https://$($script:HostName)" } else { "https://$($script:HostName):$Port" }
$script:Listener = [System.Net.HttpListener]::new()
$script:Listener.Prefixes.Add("$($script:Origin)/")
$script:Sessions = @{}
$script:LoginAttempts = @{}
$script:DiscoveryByPair = @{}
$script:MigrationProcess = $null
$script:PatchProcess = $null
$script:PatchRunId = $null
$script:PatchAction = $null
$script:PatchKB = $null
$script:PatchCatalog = @()
$script:PatchCatalogUpdatedAt = $null
$script:RuntimeConfigPath = $null
$script:ProgressPath = $null
$script:ControlPath = $null
$script:EventBuffer = [System.Collections.Generic.List[object]]::new()
$script:ProcessOutputQueue = [System.Collections.Concurrent.ConcurrentQueue[DbMigration.Web.ProcessOutputLine]]::new()
$script:ProcessOutputHandler = $null
$script:NextEventId = 1
$script:RunId = $null
$script:HostLogDirectory = if ($script:PortableMode) { $storage.LogDirectory } else { Join-Path $env:LOCALAPPDATA 'DbMigrationWeb\Logs' }
$script:HostLogPath = Join-Path $script:HostLogDirectory "WebHost-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').log"
$null = New-Item -ItemType Directory -Path $script:HostLogDirectory -Force -ErrorAction Stop

function Write-WebHostLog {
    param(
        [Parameter(Mandatory)][string] $Level,
        [Parameter(Mandatory)][string] $Message
    )

    $line = '[{0}] [{1}] {2}{3}' -f [DateTime]::UtcNow.ToString('o'), $Level, $Message, [Environment]::NewLine
    try {
        [System.IO.File]::AppendAllText($script:HostLogPath, $line, [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        [Console]::Error.WriteLine("Could not write web-host log '$($script:HostLogPath)': $($_.Exception.Message)")
        [Console]::Error.WriteLine($line)
    }
    [Console]::WriteLine($line.TrimEnd())
}

function Get-WebMigrationControlAction {
    if (-not $script:ControlPath -or -not (Test-Path -LiteralPath $script:ControlPath -PathType Leaf)) {
        return 'Run'
    }
    $control = Get-Content -LiteralPath $script:ControlPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if (-not $control.Contains('Action') -or $control.Action -notin @('Run', 'Pause', 'Resume', 'Stop')) {
        throw "Migration control file has an invalid action: $($script:ControlPath)"
    }
    [string]$control.Action
}

function Set-WebMigrationControlAction {
    param([Parameter(Mandatory)][ValidateSet('Pause', 'Resume', 'Stop')][string] $Action)

    if (-not ($script:MigrationProcess -and -not $script:MigrationProcess.HasExited)) {
        throw [System.InvalidOperationException]::new('There is no active migration run to control.')
    }
    $currentAction = Get-WebMigrationControlAction
    if ($currentAction -eq 'Stop') {
        throw [System.InvalidOperationException]::new('This migration is stopping and cannot be resumed.')
    }
    if ($Action -eq 'Resume' -and $currentAction -ne 'Pause') {
        throw [System.InvalidOperationException]::new('The migration is not paused.')
    }
    if ($Action -eq 'Pause' -and $currentAction -eq 'Pause') {
        return $currentAction
    }
    $temporaryPath = "$($script:ControlPath).tmp"
    $controlJson = ConvertTo-Json -InputObject @{ Action = $Action; UpdatedAt = [DateTime]::UtcNow.ToString('o') } -Compress
    [System.IO.File]::WriteAllText($temporaryPath, $controlJson, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($temporaryPath, $script:ControlPath, $true)
    Write-WebHostLog -Level Information -Message "Migration control changed to '$Action'."
    $Action
}

function Send-WebResponse {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerResponse] $Response,
        [Parameter(Mandatory)][int] $StatusCode,
        [Parameter(Mandatory)][string] $ContentType,
        [Parameter(Mandatory)][byte[]] $Body
    )

    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentEncoding = [Text.Encoding]::UTF8
    $Response.ContentLength64 = $Body.Length
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Response.Headers['X-Frame-Options'] = 'DENY'
    $Response.Headers['Referrer-Policy'] = 'no-referrer'
    if ($script:UseSecureTransport) {
        $Response.Headers['Strict-Transport-Security'] = 'max-age=31536000'
    }
    $Response.Headers['Content-Security-Policy'] = "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'"
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.OutputStream.Write($Body, 0, $Body.Length)
}

function Send-WebJson {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerResponse] $Response,
        [Parameter(Mandatory)][int] $StatusCode,
        [Parameter(Mandatory)] $Value
    )
    $json = ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    Send-WebResponse -Response $Response -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($json))
}

function Read-WebRequestJson {
    param([Parameter(Mandatory)][System.Net.HttpListenerRequest] $Request)
    if ($Request.ContentLength64 -gt 1048576) {
        throw [ArgumentException]::new('Request body exceeds the 1 MB limit.')
    }
    $reader = [System.IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
    try {
        $builder = [System.Text.StringBuilder]::new()
        $buffer = [char[]]::new(4096)
        while (($read = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($builder.Length + $read -gt 1048576) {
                throw [ArgumentException]::new('Request body exceeds the 1 MB limit.')
            }
            $null = $builder.Append($buffer, 0, $read)
        }
        $body = $builder.ToString()
    }
    finally {
        $reader.Dispose()
    }
    if ([string]::IsNullOrWhiteSpace($body)) {
        throw [ArgumentException]::new('A JSON request body is required.')
    }
    try {
        return ConvertFrom-Json -InputObject $body -AsHashtable -ErrorAction Stop
    }
    catch {
        throw [ArgumentException]::new("Request body must be valid JSON: $($_.Exception.Message)")
    }
}

function Get-WebSession {
    param([Parameter(Mandatory)][System.Net.HttpListenerRequest] $Request)
    $cookie = $Request.Cookies['DbMigrationSession']
    if (-not $cookie -or -not $script:Sessions.ContainsKey($cookie.Value)) {
        return $null
    }
    $session = $script:Sessions[$cookie.Value]
    if ($session.ExpiresUtc -le [DateTime]::UtcNow) {
        $script:Sessions.Remove($cookie.Value)
        return $null
    }
    $session.ExpiresUtc = [DateTime]::UtcNow.AddHours(8)
    return $session
}

function Set-WebSessionCookie {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerResponse] $Response,
        [Parameter()][string] $Token = ''
    )
    $secureSuffix = if ($script:UseSecureTransport) { '; Secure' } else { '' }
    if ($Token) {
        $Response.AppendHeader('Set-Cookie', "DbMigrationSession=$Token; Path=/; HttpOnly; SameSite=Strict$secureSuffix")
    }
    else {
        $Response.AppendHeader('Set-Cookie', "DbMigrationSession=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict$secureSuffix")
    }
}

function Read-WebProgressFiles {
    if (-not $script:ProgressPath -or -not (Test-Path -LiteralPath $script:ProgressPath -PathType Container)) {
        return
    }
    foreach ($eventFile in Get-ChildItem -LiteralPath $script:ProgressPath -Filter '*.json' -File | Sort-Object Name) {
        try {
            $migrationEvent = Get-Content -LiteralPath $eventFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $migrationEvent.Id = $script:NextEventId
            $script:NextEventId++
            $script:EventBuffer.Add($migrationEvent)
            Remove-Item -LiteralPath $eventFile.FullName -Force -ErrorAction Stop
        }
        catch {
            Write-Error "Could not process progress event '$($eventFile.Name)': $($_.Exception.Message)"
            throw
        }
    }
    while ($script:EventBuffer.Count -gt 5000) {
        $script:EventBuffer.RemoveAt(0)
    }
}

function Read-WebProcessOutput {
    $queuedOutput = $null
    while ($script:ProcessOutputQueue.TryDequeue([ref]$queuedOutput)) {
        $outputEvent = @{
            Id = $script:NextEventId
            Timestamp = [DateTime]::UtcNow.ToString('o')
            Source = ''
            Target = ''
            Database = ''
            Stage = 'ProcessOutput'
            Status = $queuedOutput.Status
            Message = $queuedOutput.Message
        }
        $script:NextEventId++
        $script:EventBuffer.Add($outputEvent)
        $queuedOutput = $null
    }
    if ($script:ProcessOutputHandler -and $script:ProcessOutputHandler.ConsumeDroppedLines() -gt 0) {
        $script:EventBuffer.Add(@{
            Id = $script:NextEventId
            Timestamp = [DateTime]::UtcNow.ToString('o')
            Source = ''
            Target = ''
            Database = ''
            Stage = 'ProcessOutput'
            Status = 'InProgress'
            Message = 'The process output buffer reached its limit; older console lines were discarded. Structured progress events are unaffected.'
        })
        $script:NextEventId++
    }
    while ($script:EventBuffer.Count -gt 5000) {
        $script:EventBuffer.RemoveAt(0)
    }
}

function Get-WebPair {
    param([Parameter(Mandatory)][int] $Index)
    if ($Index -lt 0 -or $Index -ge $script:WebConfiguration.SourceTargets.Count) {
        throw [ArgumentException]::new('The selected source/target pair is not configured.')
    }
    return $script:WebConfiguration.SourceTargets[$Index]
}

function Start-WebMigration {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Body)

    if ($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) {
        throw [System.InvalidOperationException]::new('A migration is already running.')
    }
    if (-not $Body.Contains('PairIndex') -or -not $Body.Contains('Databases')) {
        throw [ArgumentException]::new('PairIndex and Databases are required.')
    }
    if ($Body.PairIndex -is [bool] -or
        $Body.PairIndex -isnot [byte] -and $Body.PairIndex -isnot [int16] -and
        $Body.PairIndex -isnot [int32] -and $Body.PairIndex -isnot [int64]) {
        throw [ArgumentException]::new('PairIndex must be an integer.')
    }
    if ($Body.Databases -isnot [array]) {
        throw [ArgumentException]::new('Databases must be a JSON array.')
    }
    foreach ($option in @('MigrateLogins', 'MigrateAgentJobs', 'MigrateAgentOperators', 'ConfigureLinkedServers', 'RepairOrphanUsers', 'UpdateStatistics')) {
        if (-not $Body.Contains($option) -or $Body[$option] -isnot [bool]) {
            throw [ArgumentException]::new("'$option' must be provided as a JSON boolean.")
        }
    }
    $pairIndex = [int]$Body.PairIndex
    $pair = Get-WebPair -Index $pairIndex
    if (-not $script:DiscoveryByPair.ContainsKey([string]$pairIndex)) {
        throw [ArgumentException]::new('Discover databases for this source/target pair before starting a migration.')
    }
    $availableDatabases = @($script:DiscoveryByPair[[string]$pairIndex] | ForEach-Object { [string]$_.Database })
    $selectedDatabases = @($Body.Databases | ForEach-Object { [string]$_ } | Select-Object -Unique)
    if (@($selectedDatabases | Where-Object { $_ -notin $availableDatabases }).Count -gt 0) {
        throw [ArgumentException]::new('One or more selected databases are not in the latest discovery results.')
    }
    if ($selectedDatabases.Count -eq 0 -and
        -not ($Body.MigrateLogins -or $Body.MigrateAgentJobs -or $Body.MigrateAgentOperators -or $Body.ConfigureLinkedServers)) {
        throw [ArgumentException]::new('Select at least one database or one server-level migration option.')
    }
    $requestedOverwrites = @()
    if ($Body.Contains('OverwriteDatabases')) {
        if ($Body.OverwriteDatabases -isnot [array]) {
            throw [ArgumentException]::new('OverwriteDatabases must be a JSON array.')
        }
        $requestedOverwrites = @($Body.OverwriteDatabases | ForEach-Object { [string]$_ } | Select-Object -Unique)
    }
    if (@($requestedOverwrites | Where-Object { $_ -notin $selectedDatabases }).Count -gt 0) {
        throw [ArgumentException]::new('Overwrite authorization may only be provided for selected databases.')
    }

    Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.Discovery.psm1') -Force
    $overwrites = [System.Collections.Generic.List[string]]::new()
    $skips = [System.Collections.Generic.List[string]]::new()
    foreach ($databaseName in $selectedDatabases) {
        if (Test-MigrationDatabaseExists -SqlInstance $pair.Target -Database $databaseName) {
            if ($databaseName -in $requestedOverwrites) {
                $overwrites.Add($databaseName)
            }
            else {
                $skips.Add($databaseName)
            }
        }
    }

    $runConfiguration = $script:WebConfiguration.Clone()
    foreach ($key in @($runConfiguration.Keys)) {
        if ($key -in @('MigrateLogins', 'MigrateAgentJobs', 'MigrateAgentOperators', 'ConfigureLinkedServers', 'RepairOrphanUsers', 'UpdateStatistics')) {
            $runConfiguration.Remove($key)
        }
    }
    $runConfiguration.SourceTargets = @(@{
        Source = [string]$pair.Source
        Target = [string]$pair.Target
        BackupPath = [string]$pair.BackupPath
    })
    $runConfiguration.IncludeDatabases = $selectedDatabases
    $runConfiguration.OverwriteExistingDatabases = @($overwrites)
    $runConfiguration.SkipExistingDatabases = @($skips)
    foreach ($option in @('MigrateLogins', 'MigrateAgentJobs', 'MigrateAgentOperators', 'ConfigureLinkedServers', 'RepairOrphanUsers', 'UpdateStatistics')) {
        $runConfiguration[$option] = $Body[$option]
    }
    $runConfiguration.AllowTargetReplace = $false
    foreach ($property in @('OutputPath', 'LinkedServersCsv')) {
        if (-not [System.IO.Path]::IsPathRooted([string]$runConfiguration[$property])) {
            $runConfiguration[$property] = Join-Path $PSScriptRoot $runConfiguration[$property]
        }
    }

    $runDirectory = Join-Path $env:LOCALAPPDATA 'DbMigrationWeb\Runs'
    $null = New-Item -ItemType Directory -Path $runDirectory -Force -ErrorAction Stop
    $script:RunId = [guid]::NewGuid().ToString('N')
    $script:RuntimeConfigPath = Join-Path $runDirectory "$($script:RunId).json"
    $script:ProgressPath = Join-Path $runDirectory "$($script:RunId)-progress"
    $null = New-Item -ItemType Directory -Path $script:ProgressPath -Force -ErrorAction Stop
    $runConfiguration | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:RuntimeConfigPath -Encoding utf8
    $script:EventBuffer.Clear()
    $script:ProcessOutputQueue = [System.Collections.Concurrent.ConcurrentQueue[DbMigration.Web.ProcessOutputLine]]::new()
    $script:NextEventId = 1

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'Invoke-DbMigration.ps1'),
        '-Mode', 'Migrate', '-ConfigPath', $script:RuntimeConfigPath,
        '-ProgressPath', $script:ProgressPath,
        '-StatePath', $fullStatePath
    )) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }
    $script:MigrationProcess = [System.Diagnostics.Process]::new()
    $script:MigrationProcess.StartInfo = $startInfo
    $script:ProcessOutputHandler = [DbMigration.Web.ProcessOutputHandler]::new($script:ProcessOutputQueue)
    $script:ProcessOutputHandler.Attach($script:MigrationProcess)
    if (-not $script:MigrationProcess.Start()) {
        throw 'Could not start the migration process.'
    }
    $script:MigrationProcess.BeginOutputReadLine()
    $script:MigrationProcess.BeginErrorReadLine()
    return @{
        RunId = $script:RunId
        Status = 'Running'
        Pair = @{ Source = $pair.Source; Target = $pair.Target }
        Databases = $selectedDatabases
        OverwriteDatabases = @($overwrites)
        SkippedExistingDatabases = @($skips)
    }
}

function Get-WebPairKey {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Pair)
    $identity = [string]::Join([char]0, @(
        ([string]$Pair.Source).Trim().ToLowerInvariant(),
        ([string]$Pair.Target).Trim().ToLowerInvariant(),
        ([string]$Pair.BackupPath).Trim().ToLowerInvariant()
    ))
    [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
        [System.Text.Encoding]::UTF8.GetBytes($identity)
    )).ToLowerInvariant()
}

function ConvertTo-WebPairs {
    param([Parameter(Mandatory)][object[]] $Pairs)
    if ($Pairs.Count -lt 1 -or $Pairs.Count -gt 3) {
        throw [ArgumentException]::new('Enter between one and three source/target pairs.')
    }
    $validatedPairs = [System.Collections.Generic.List[object]]::new()
    $endpointKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($pair in $Pairs) {
        if ($pair -isnot [System.Collections.IDictionary]) {
            throw [ArgumentException]::new('Each instance entry must contain source, target, and backup path values.')
        }
        foreach ($name in @('Source', 'Target', 'BackupPath')) {
            if (-not $pair.Contains($name) -or [string]::IsNullOrWhiteSpace([string]$pair[$name])) {
                throw [ArgumentException]::new("Each instance entry must include a non-empty '$name'.")
            }
        }
        if (-not [System.IO.Path]::IsPathRooted(([string]$pair.BackupPath).Trim())) {
            throw [ArgumentException]::new('Backup paths must be absolute local or UNC paths.')
        }
        $normalizedPair = @{
            Source = ([string]$pair.Source).Trim()
            Target = ([string]$pair.Target).Trim()
            BackupPath = [System.IO.Path]::GetFullPath(([string]$pair.BackupPath).Trim())
            MigrationMode = if ($pair.Contains('MigrationMode')) { [string]$pair.MigrationMode } else { 'Full' }
        }
        if ($normalizedPair.MigrationMode -notin @('Full', 'SchemaOnly')) {
            throw [ArgumentException]::new("MigrationMode for '$($normalizedPair.Source)' must be 'Full' or 'SchemaOnly'.")
        }
        if ($pair.Contains('Databases')) {
            if ($pair.Databases -isnot [array]) {
                throw [ArgumentException]::new('Database selections must be provided as an array for each source/target pair.')
            }
            $normalizedPair.Databases = $pair.Databases
        }
        $endpointKey = [string]::Join([char]0, @(
            $normalizedPair.Source.ToLowerInvariant(),
            $normalizedPair.Target.ToLowerInvariant()
        ))
        if (-not $endpointKeys.Add($endpointKey)) {
            throw [ArgumentException]::new('Duplicate source/target instance pairs are not allowed.')
        }
        $validatedPairs.Add($normalizedPair)
    }
    return $validatedPairs.ToArray()
}

function Start-WebMigrationPlan {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Body)

    if (($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) -or
        ($script:PatchProcess -and -not $script:PatchProcess.HasExited)) {
        throw [System.InvalidOperationException]::new('Another migration or SQL Server patch operation is already running.')
    }
    if (-not $Body.Contains('Pairs') -or $Body.Pairs -isnot [array] -or
        -not $Body.Contains('Options') -or $Body.Options -isnot [System.Collections.IDictionary]) {
        throw [ArgumentException]::new('Pairs and Options are required.')
    }
    $pairs = @(ConvertTo-WebPairs -Pairs $Body.Pairs)
    $optionNames = @(
        'MigrateLogins', 'MigrateAgentJobs', 'MigrateAgentOperators',
        'ConfigureLinkedServers', 'SkipLinkedServers', 'RepairOrphanUsers', 'UpdateStatistics'
    )
    foreach ($optionName in $optionNames) {
        if (-not $Body.Options.Contains($optionName) -or $Body.Options[$optionName] -isnot [bool]) {
            throw [ArgumentException]::new("'$optionName' must be provided as a JSON boolean.")
        }
    }
    $planPairs = [System.Collections.Generic.List[object]]::new()
    foreach ($pair in $pairs) {
        $serverWork = Test-MigrationServerWorkEnabled -Options $Body.Options -MigrationMode $pair.MigrationMode
        $pairKey = Get-WebPairKey -Pair $pair
        if (-not $script:DiscoveryByPair.ContainsKey($pairKey)) {
            throw [ArgumentException]::new("Run discovery for '$($pair.Source)' -> '$($pair.Target)' before starting migration.")
        }
        $discovery = $script:DiscoveryByPair[$pairKey]
        if ($discovery.Pair.Source -cne $pair.Source -or $discovery.Pair.Target -cne $pair.Target -or
            $discovery.Pair.BackupPath -cne $pair.BackupPath) {
            throw [ArgumentException]::new('A source, target, or backup path changed after discovery. Run discovery again.')
        }
        if (-not $pair.Contains('Databases') -or $pair.Databases -isnot [array]) {
            throw [ArgumentException]::new('Each pair must include a database selection array.')
        }
        $knownDatabases = @($discovery.Databases | ForEach-Object { [string]$_.Database })
        $selectedNames = @($pair.Databases | ForEach-Object { [string]$_.Database })
        if (@($selectedNames | Where-Object { $_ -notin $knownDatabases }).Count -gt 0) {
            throw [ArgumentException]::new("A selected database was not in the latest discovery for '$($pair.Source)'.")
        }
        if (@($pair.Databases | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Database) }).Count -gt 0) {
            throw [ArgumentException]::new('Database names must not be empty.')
        }
        if (@($selectedNames | Select-Object -Unique).Count -ne $selectedNames.Count) {
            throw [ArgumentException]::new("Duplicate database entries were selected for '$($pair.Source)'.")
        }
        foreach ($database in $pair.Databases) {
            if ($database -isnot [System.Collections.IDictionary] -or
                -not $database.Contains('Overwrite') -or $database.Overwrite -isnot [bool] -or
                -not $database.Contains('Database')) {
                throw [ArgumentException]::new('Database selections must include a boolean Overwrite decision.')
            }
            $knownDatabase = @($discovery.Databases | Where-Object { $_.Database -ceq $database.Database }) | Select-Object -First 1
            if ([bool]$database.Overwrite -and -not [bool]$knownDatabase.TargetExists) {
                throw [ArgumentException]::new("Overwrite was approved for '$($database.Database)', but discovery did not show an existing target.")
            }
        }
        if ($selectedNames.Count -eq 0 -and -not $serverWork) {
            continue
        }
        $planPairs.Add(@{
            Source = $pair.Source
            Target = $pair.Target
            BackupPath = $pair.BackupPath
            MigrationMode = $pair.MigrationMode
            Databases = @($pair.Databases | ForEach-Object {
                @{ Database = [string]$_.Database; Overwrite = [bool]$_.Overwrite }
            })
        })
    }
    if ($planPairs.Count -eq 0) {
        throw [ArgumentException]::new('Select at least one database or server-level action for a configured pair.')
    }

    $configuration = $script:WebConfiguration.Clone()
    foreach ($property in @('OutputPath', 'LinkedServersCsv')) {
        if (-not [System.IO.Path]::IsPathRooted([string]$configuration[$property])) {
            $configuration[$property] = Join-Path $PSScriptRoot $configuration[$property]
        }
    }
    $plan = @{ Configuration = $configuration; Pairs = $planPairs.ToArray(); Options = $Body.Options }
    foreach ($pair in $planPairs) {
        $configuredPair = @($configuration.SourceTargets | Where-Object {
            $_.Source -ieq $pair.Source -and $_.Target -ieq $pair.Target
        }) | Select-Object -First 1
        if ($configuredPair) {
            $configuredPair.MigrationMode = $pair.MigrationMode
        }
    }
    $runDirectory = Join-Path $env:LOCALAPPDATA 'DbMigrationWeb\Runs'
    $null = New-Item -ItemType Directory -Path $runDirectory -Force -ErrorAction Stop
    $script:RunId = [guid]::NewGuid().ToString('N')
    $script:RuntimeConfigPath = Join-Path $runDirectory "$($script:RunId)-plan.json"
    $script:ProgressPath = Join-Path $runDirectory "$($script:RunId)-progress"
    $script:ControlPath = Join-Path $runDirectory "$($script:RunId)-control.json"
    $null = New-Item -ItemType Directory -Path $script:ProgressPath -Force -ErrorAction Stop
    [System.IO.File]::WriteAllText($script:ControlPath, '{"Action":"Run"}', [System.Text.UTF8Encoding]::new($false))
    $plan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:RuntimeConfigPath -Encoding utf8
    $script:EventBuffer.Clear()
    $script:ProcessOutputQueue = [System.Collections.Concurrent.ConcurrentQueue[DbMigration.Web.ProcessOutputLine]]::new()
    $script:NextEventId = 1

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'Invoke-DbMigrationWebPlan.ps1'),
        '-PlanPath', $script:RuntimeConfigPath,
        '-ProgressPath', $script:ProgressPath,
        '-StatePath', $fullStatePath,
        '-ControlPath', $script:ControlPath
    )) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }
    $script:MigrationProcess = [System.Diagnostics.Process]::new()
    $script:MigrationProcess.StartInfo = $startInfo
    $script:ProcessOutputHandler = [DbMigration.Web.ProcessOutputHandler]::new($script:ProcessOutputQueue)
    $script:ProcessOutputHandler.Attach($script:MigrationProcess)
    if (-not $script:MigrationProcess.Start()) {
        throw 'Could not start the migration plan process.'
    }
    $script:MigrationProcess.BeginOutputReadLine()
    $script:MigrationProcess.BeginErrorReadLine()
    return @{
        RunId = $script:RunId
        Status = 'Running'
        Sequential = $true
        Pairs = @($planPairs | ForEach-Object {
            @{ Source = $_.Source; Target = $_.Target; DatabaseCount = $_.Databases.Count }
        })
    }
}

function ConvertTo-WebPatchTargets {
    param([Parameter(Mandatory)][object[]] $Selections)

    if ($Selections.Count -eq 0) {
        throw [ArgumentException]::new('Select at least one configured SQL Server instance.')
    }
    $targets = [System.Collections.Generic.List[object]]::new()
    $selectedInstances = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($selection in $Selections) {
        if ($selection -isnot [System.Collections.IDictionary] -or
            -not $selection.Contains('PairIndex') -or -not $selection.Contains('Role')) {
            throw [ArgumentException]::new('Each target selection must include PairIndex and Role.')
        }
        if ($selection.PairIndex -is [bool] -or $selection.PairIndex -isnot [byte] -and
            $selection.PairIndex -isnot [int16] -and $selection.PairIndex -isnot [int32] -and
            $selection.PairIndex -isnot [int64]) {
            throw [ArgumentException]::new('PairIndex must be an integer.')
        }
        $role = [string]$selection.Role
        if ($role -notin @('Source', 'Target')) {
            throw [ArgumentException]::new("Role must be 'Source' or 'Target'.")
        }
        $pair = Get-WebPair -Index ([int]$selection.PairIndex)
        $sqlInstance = [string]$pair[$role]
        if (-not $selectedInstances.Add($sqlInstance)) {
            throw [ArgumentException]::new("SQL instance '$sqlInstance' was selected more than once.")
        }
        $targets.Add(@{ SqlInstance = $sqlInstance; Role = $role; PairIndex = [int]$selection.PairIndex })
    }
    $targets.ToArray()
}

function Get-WebPatchCatalogRecord {
    param([Parameter(Mandatory)][string] $KB)
    $record = @($script:PatchCatalog | Where-Object { [string]$_.KB -eq $KB } | Select-Object -First 1)
    if (-not $record) {
        throw [ArgumentException]::new("KB$KB is not in the current patch catalog. Refresh the catalog and choose a listed update.")
    }
    $record[0]
}

function Start-WebSqlServerPatch {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Body,
        [Parameter(Mandatory)][ValidateSet('Download', 'Apply')][string] $Action
    )

    if (($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) -or
        ($script:PatchProcess -and -not $script:PatchProcess.HasExited)) {
        throw [System.InvalidOperationException]::new('Another migration or SQL Server patch operation is already running.')
    }
    foreach ($property in @('KB', 'UpdatePath')) {
        if (-not $Body.Contains($property)) {
            throw [ArgumentException]::new("$property is required.")
        }
    }
    $kb = [string]$Body.KB
    if ($kb -notmatch '^\d{5,10}$') {
        throw [ArgumentException]::new('KB must be a numeric Microsoft Knowledge Base identifier.')
    }
    $patch = Get-WebPatchCatalogRecord -KB $kb
    $updatePath = [string]$Body.UpdatePath
    if ([string]::IsNullOrWhiteSpace($updatePath)) {
        throw [ArgumentException]::new('UpdatePath is required.')
    }

    $targets = @()
    $restart = $false
    if ($Action -eq 'Apply') {
        foreach ($property in @('Targets', 'Restart')) {
            if (-not $Body.Contains($property)) {
                throw [ArgumentException]::new("$property is required.")
            }
        }
        if ($Body.Targets -isnot [array] -or $Body.Restart -isnot [bool]) {
            throw [ArgumentException]::new('Targets must be an array and Restart must be a JSON boolean.')
        }
        $targets = @(ConvertTo-WebPatchTargets -Selections @($Body.Targets))
        $restart = [bool]$Body.Restart
        if (-not (Test-Path -LiteralPath $updatePath -PathType Container)) {
            throw [ArgumentException]::new('The update repository folder does not exist on the app host.')
        }
        foreach ($target in $targets) {
            $assessment = Get-MigrationSqlServerPatchAssessment -SqlInstance $target.SqlInstance -KB $kb
            if ($assessment.Status -ne 'Eligible') {
                throw [ArgumentException]::new("Cannot apply KB$kb to '$($target.SqlInstance)': $($assessment.Status) - $($assessment.Reason)")
            }
        }
    }

    $runDirectory = Join-Path $env:LOCALAPPDATA 'DbMigrationWeb\Runs'
    $null = New-Item -ItemType Directory -Path $runDirectory -Force -ErrorAction Stop
    $script:PatchRunId = [guid]::NewGuid().ToString('N')
    $script:PatchAction = $Action
    $script:PatchKB = $kb
    $planPath = Join-Path $runDirectory "$($script:PatchRunId)-patch.json"
    $plan = @{
        Action = $Action
        Targets = $targets
        KB = $kb
        UpdatePath = [System.IO.Path]::GetFullPath($updatePath)
        Restart = $restart
    }
    $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath -Encoding utf8

    $script:ProcessOutputQueue = [System.Collections.Concurrent.ConcurrentQueue[DbMigration.Web.ProcessOutputLine]]::new()
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'Invoke-DbMigrationPatch.ps1'),
        '-PlanPath', $planPath
    )) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }
    $script:PatchProcess = [System.Diagnostics.Process]::new()
    $script:PatchProcess.StartInfo = $startInfo
    $script:ProcessOutputHandler = [DbMigration.Web.ProcessOutputHandler]::new($script:ProcessOutputQueue)
    $script:ProcessOutputHandler.Attach($script:PatchProcess)
    if (-not $script:PatchProcess.Start()) {
        throw 'Could not start the SQL Server patch process.'
    }
    $script:PatchProcess.BeginOutputReadLine()
    $script:PatchProcess.BeginErrorReadLine()

    return @{
        RunId = $script:PatchRunId
        Status = 'Running'
        Action = $Action
        TargetCount = $targets.Count
        KB = $patch.KB
        Title = $patch.Title
    }
}

$script:Listener.Start()
Write-Output "Database migration browser UI: $($script:Origin)/"
Write-Output "Web host log: $($script:HostLogPath)"
Write-Output 'Use Ctrl+C to stop the web host. Do not stop the host while a migration is running.'
Write-WebHostLog -Level Information -Message "Web host started at $($script:Origin)."
try {
    while ($script:Listener.IsListening) {
        $context = $script:Listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        try {
            $hostHeader = $request.UserHostName
            if (-not [string]::Equals($hostHeader, "$($script:HostName):$($script:Port)", [StringComparison]::OrdinalIgnoreCase) -and
                -not [string]::Equals($hostHeader, $script:HostName, [StringComparison]::OrdinalIgnoreCase)) {
                Send-WebJson -Response $response -StatusCode 400 -Value @{ error = 'Invalid host header.' }
                continue
            }

            if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -in @('/', '/index.html')) {
                $indexPath = Join-Path $PSScriptRoot 'web\index.html'
                $bytes = [System.IO.File]::ReadAllBytes($indexPath)
                Send-WebResponse -Response $response -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body $bytes
                continue
            }
            if (-not $script:UseSecureTransport -and -not $request.IsSecureConnection) {
                $localAddress = [string]$request.LocalEndPoint.Address
                $requestIsAllowed = $request.Url.Scheme -eq 'http' -and (
                    $localAddress -eq '127.0.0.1' -or
                    $localAddress -eq '::1' -or
                    $localAddress.StartsWith('127.') -or
                    $localAddress.StartsWith('::1')
                )
                if (-not $requestIsAllowed) {
                    Send-WebJson -Response $response -StatusCode 400 -Value @{ error = 'In portable mode, only local HTTP is supported.' }
                    continue
                }
            }
            elseif (-not $request.IsSecureConnection) {
                Send-WebJson -Response $response -StatusCode 400 -Value @{ error = 'HTTPS is required.' }
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -eq '/api/session') {
                $session = Get-WebSession -Request $request
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    authenticated = [bool]$session
                    username = if ($session) { $session.Username } else { '' }
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Headers['Origin'] -ne $script:Origin) {
                Send-WebJson -Response $response -StatusCode 403 -Value @{ error = 'Request origin is not allowed.' }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/login') {
                $address = [string]$request.RemoteEndPoint.Address
                $attempts = @($script:LoginAttempts[$address] | Where-Object { $_ -gt [DateTime]::UtcNow.AddMinutes(-10) })
                if ($attempts.Count -ge 5) {
                    $script:LoginAttempts[$address] = $attempts
                    Send-WebJson -Response $response -StatusCode 429 -Value @{ error = 'Too many login attempts. Try again in 10 minutes.' }
                    continue
                }
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('Username') -or -not $body.Contains('Password')) {
                    throw [ArgumentException]::new('Username and Password are required.')
                }
                $valid = Test-MigrationWebPassword -Record $script:AuthRecord -Username ([string]$body.Username) -Password ([string]$body.Password)
                $body.Password = ''
                if (-not $valid) {
                    $attempts += [DateTime]::UtcNow
                    $script:LoginAttempts[$address] = $attempts
                    Start-Sleep -Milliseconds 350
                    Send-WebJson -Response $response -StatusCode 401 -Value @{ error = 'Invalid username or password.' }
                    continue
                }
                $script:LoginAttempts.Remove($address)
                if ($script:Sessions.Count -ge 256) {
                    Send-WebJson -Response $response -StatusCode 429 -Value @{ error = 'The maximum number of active sessions has been reached.' }
                    continue
                }
                $tokenBytes = [byte[]]::new(32)
                [Security.Cryptography.RandomNumberGenerator]::Fill($tokenBytes)
                $token = [Convert]::ToBase64String($tokenBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
                $script:Sessions[$token] = @{ Username = [string]$script:AuthRecord.Username; ExpiresUtc = [DateTime]::UtcNow.AddHours(8) }
                Set-WebSessionCookie -Response $response -Token $token
                Send-WebJson -Response $response -StatusCode 200 -Value @{ authenticated = $true; username = [string]$script:AuthRecord.Username }
                continue
            }

            $session = Get-WebSession -Request $request
            if (-not $session) {
                Send-WebJson -Response $response -StatusCode 401 -Value @{ error = 'Authentication required.' }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/logout') {
                $cookie = $request.Cookies['DbMigrationSession']
                if ($cookie) { $script:Sessions.Remove($cookie.Value) }
                Set-WebSessionCookie -Response $response
                Send-WebJson -Response $response -StatusCode 200 -Value @{ authenticated = $false }
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -eq '/api/defaults') {
                $pairs = [System.Collections.Generic.List[object]]::new()
                $endpointKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($configuredPair in $script:WebConfiguration.SourceTargets) {
                    $endpointKey = [string]::Join([char]0, @(
                        ([string]$configuredPair.Source).Trim().ToLowerInvariant(),
                        ([string]$configuredPair.Target).Trim().ToLowerInvariant()
                    ))
                    if ($endpointKeys.Add($endpointKey)) {
                        $pairs.Add(@{
                            Source = [string]$configuredPair.Source
                            Target = [string]$configuredPair.Target
                            BackupPath = [string]$configuredPair.BackupPath
                        })
                    }
                    if ($pairs.Count -ge 3) { break }
                }
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    pairs = $pairs.ToArray()
                    maxPairs = 3
                    options = @{
                        MigrateLogins = [bool]$script:WebConfiguration.MigrateLogins
                        MigrateAgentJobs = [bool]$script:WebConfiguration.MigrateAgentJobs
                        MigrateAgentOperators = [bool]$script:WebConfiguration.MigrateAgentOperators
                        ConfigureLinkedServers = [bool]$script:WebConfiguration.ConfigureLinkedServers
                        RepairOrphanUsers = [bool]$script:WebConfiguration.RepairOrphanUsers
                        UpdateStatistics = [bool]$script:WebConfiguration.UpdateStatistics
                    }
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/patch/catalog') {
                if (($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) -or
                    ($script:PatchProcess -and -not $script:PatchProcess.HasExited)) {
                    throw [System.InvalidOperationException]::new('Patch catalog refresh is unavailable while a migration or patch operation is running.')
                }
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('Refresh') -or $body.Refresh -isnot [bool]) {
                    throw [ArgumentException]::new('Refresh must be provided as a JSON boolean.')
                }
                $script:PatchCatalog = @(Get-MigrationSqlServerPatchCatalog -Refresh:$body.Refresh)
                $script:PatchCatalogUpdatedAt = [DateTime]::UtcNow.ToString('o')
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    patches = $script:PatchCatalog
                    updatedAt = $script:PatchCatalogUpdatedAt
                    onlineRefresh = [bool]$body.Refresh
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/patch/assess') {
                if (($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) -or
                    ($script:PatchProcess -and -not $script:PatchProcess.HasExited)) {
                    throw [System.InvalidOperationException]::new('Patch assessment is unavailable while a migration or patch operation is running.')
                }
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('KB') -or -not $body.Contains('Targets') -or $body.Targets -isnot [array]) {
                    throw [ArgumentException]::new('KB and Targets are required.')
                }
                $kb = [string]$body.KB
                $patch = Get-WebPatchCatalogRecord -KB $kb
                $targets = @(ConvertTo-WebPatchTargets -Selections @($body.Targets))
                $results = @($targets | ForEach-Object {
                    $assessment = Get-MigrationSqlServerPatchAssessment -SqlInstance $_.SqlInstance -KB $kb
                    $assessment | Add-Member -NotePropertyName Role -NotePropertyValue $_.Role -Force
                    $assessment | Add-Member -NotePropertyName PairIndex -NotePropertyValue $_.PairIndex -Force
                    $assessment
                })
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    patch = $patch
                    results = $results
                    eligibleCount = @($results | Where-Object Status -eq 'Eligible').Count
                    alreadyInstalledCount = @($results | Where-Object Status -eq 'AlreadyInstalled').Count
                    blockedCount = @($results | Where-Object Status -ne 'Eligible' -and Status -ne 'AlreadyInstalled').Count
                    assessedAt = [DateTime]::UtcNow.ToString('o')
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/discover') {
                if (($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) -or
                    ($script:PatchProcess -and -not $script:PatchProcess.HasExited)) {
                    throw [System.InvalidOperationException]::new('Discovery is unavailable while a migration or SQL Server patch is running.')
                }
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('Pair')) {
                    throw [ArgumentException]::new('Pair is required.')
                }
                $pair = @(ConvertTo-WebPairs -Pairs @($body.Pair))[0]
                Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.Discovery.psm1') -Force
                $discoveryConfiguration = @{
                    SourceTargets = @($pair)
                    ExcludeDatabases = @($script:WebConfiguration.ExcludeDatabases)
                    RestoreSpaceBufferPercent = [double]$script:WebConfiguration.RestoreSpaceBufferPercent
                }
                $results = @(Get-MigrationDiscovery -Configuration $discoveryConfiguration)
                foreach ($result in $results) {
                    $result | Add-Member -NotePropertyName TargetExists -NotePropertyValue (
                        Test-MigrationDatabaseExists -SqlInstance $pair.Target -Database ([string]$result.Database)
                    ) -Force
                }
                $pairKey = Get-WebPairKey -Pair $pair
                $script:DiscoveryByPair[$pairKey] = @{
                    Pair = $pair
                    Databases = @($results | ForEach-Object {
                        @{
                            Database = [string]$_.Database
                            TargetExists = [bool]$_.TargetExists
                            Overwrite = $false
                        }
                    })
                }
                Send-WebJson -Response $response -StatusCode 200 -Value @{ databases = $results }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/custom-sql') {
                if ($script:PatchProcess -and -not $script:PatchProcess.HasExited) {
                    throw [System.InvalidOperationException]::new('Custom SQL execution is unavailable while SQL Server patching is running.')
                }
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('PairIndex') -or -not $body.Contains('ServerRole') -or -not $body.Contains('Query')) {
                    throw [ArgumentException]::new('PairIndex, ServerRole, and Query are required.')
                }
                $pairIndex = [int]$body.PairIndex
                $pair = Get-WebPair -Index $pairIndex
                $role = [string]$body.ServerRole
                if ($role -notin @('Source', 'Target')) {
                    throw [ArgumentException]::new("ServerRole must be 'Source' or 'Target'.")
                }
                $sqlInstance = if ($role -eq 'Source') { [string]$pair.Source } else { [string]$pair.Target }
                $database = if ($body.Contains('Database') -and -not [string]::IsNullOrWhiteSpace([string]$body.Database)) {
                    [string]$body.Database
                }
                else {
                    'master'
                }
                $query = [string]$body.Query
                $startedAt = [DateTime]::UtcNow
                $rows = @(Invoke-MigrationCustomSql -SqlInstance $sqlInstance -Database $database -Query $query)
                $elapsedMilliseconds = [int](([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
                $columns = @()
                if ($rows.Count -gt 0) {
                    $columns = @($rows[0].PSObject.Properties.Name)
                }
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    instance = $sqlInstance
                    serverRole = $role
                    database = $database
                    rowCount = $rows.Count
                    columns = $columns
                    rows = @($rows)
                    elapsedMilliseconds = $elapsedMilliseconds
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/patch/download') {
                $body = Read-WebRequestJson -Request $request
                try {
                    $result = Start-WebSqlServerPatch -Body $body -Action Download
                    Send-WebJson -Response $response -StatusCode 202 -Value $result
                }
                catch [System.InvalidOperationException] {
                    Send-WebJson -Response $response -StatusCode 409 -Value @{ error = $_.Exception.Message }
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/patch') {
                $body = Read-WebRequestJson -Request $request
                try {
                    $result = Start-WebSqlServerPatch -Body $body -Action Apply
                    Send-WebJson -Response $response -StatusCode 202 -Value $result
                }
                catch [System.InvalidOperationException] {
                    Send-WebJson -Response $response -StatusCode 409 -Value @{ error = $_.Exception.Message }
                }
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -eq '/api/patch/status') {
                $running = [bool]($script:PatchProcess -and -not $script:PatchProcess.HasExited)
                $exitCode = if ($script:PatchProcess -and $script:PatchProcess.HasExited) { $script:PatchProcess.ExitCode } else { $null }
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    runId = $script:PatchRunId
                    running = $running
                    exitCode = $exitCode
                    action = $script:PatchAction
                    KB = $script:PatchKB
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/migrate') {
                $body = Read-WebRequestJson -Request $request
                try {
                    $result = Start-WebMigrationPlan -Body $body
                    Send-WebJson -Response $response -StatusCode 202 -Value $result
                }
                catch [System.InvalidOperationException] {
                    Send-WebJson -Response $response -StatusCode 409 -Value @{ error = $_.Exception.Message }
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/control') {
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('Action') -or $body.Action -notin @('Pause', 'Resume', 'Stop')) {
                    Send-WebJson -Response $response -StatusCode 400 -Value @{ error = 'Action must be Pause, Resume, or Stop.' }
                    continue
                }
                try {
                    $action = Set-WebMigrationControlAction -Action ([string]$body.Action)
                    Send-WebJson -Response $response -StatusCode 200 -Value @{ action = $action }
                }
                catch [System.InvalidOperationException] {
                    Send-WebJson -Response $response -StatusCode 409 -Value @{ error = $_.Exception.Message }
                }
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -eq '/api/status') {
                $running = [bool]($script:MigrationProcess -and -not $script:MigrationProcess.HasExited)
                $exitCode = if ($script:MigrationProcess -and $script:MigrationProcess.HasExited) { $script:MigrationProcess.ExitCode } else { $null }
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    runId = $script:RunId
                    running = $running
                    exitCode = $exitCode
                    controlAction = Get-WebMigrationControlAction
                }
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -eq '/api/events') {
                Read-WebProgressFiles
                Read-WebProcessOutput
                $after = 0
                if ($request.QueryString['after']) { $after = [int]$request.QueryString['after'] }
                $events = @($script:EventBuffer | Where-Object { [int]$_.Id -gt $after })
                Send-WebJson -Response $response -StatusCode 200 -Value @{ events = $events; latestId = $script:NextEventId - 1 }
                continue
            }
            Send-WebJson -Response $response -StatusCode 404 -Value @{ error = 'Not found.' }
        }
        catch {
            Write-WebHostLog -Level Error -Message "Web request failed for $($request.HttpMethod) $($request.Url.AbsolutePath): $($_.Exception.ToString())"
            if (-not $response.OutputStream.CanWrite) {
                continue
            }
            $statusCode = if ($_.Exception -is [ArgumentException] -or $_.Exception -is [FormatException]) {
                400
            }
            elseif ($_.Exception -is [System.InvalidOperationException]) {
                409
            }
            else {
                500
            }
            try {
                Send-WebJson -Response $response -StatusCode $statusCode -Value @{ error = $_.Exception.Message }
            }
            catch {
                Write-WebHostLog -Level Error -Message "Could not send web error response: $($_.Exception.ToString())"
            }
        }
        finally {
            $response.Close()
        }
    }
}
catch {
    Write-WebHostLog -Level Critical -Message "Web host listener stopped unexpectedly: $($_.Exception.ToString())"
    throw
}
finally {
    Write-WebHostLog -Level Information -Message 'Web host is shutting down.'
    $script:Listener.Stop()
    $script:Listener.Close()
    if (-not ($script:MigrationProcess -and -not $script:MigrationProcess.HasExited)) {
        foreach ($path in @($script:RuntimeConfigPath, $script:ProgressPath)) {
            if ($path -and (Test-Path -LiteralPath $path)) {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            }
        }
    }
}
