Set-StrictMode -Version Latest

function Invoke-ServerObjectMigration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Pair,

        [Parameter()]
        [bool] $MigrateLogins = $true,

        [Parameter()]
        [bool] $MigrateAgentJobs = $true,

        [Parameter()]
        [bool] $MigrateAgentOperators = $true
    )

    if ($MigrateLogins) {
        Copy-DbaLogin -Source $Pair.Source -Destination $Pair.Target -ExcludeLogin 'sa' -Force -EnableException
    }
    if ($MigrateAgentJobs) {
        Copy-DbaAgentJob -Source $Pair.Source -Destination $Pair.Target -DisableOnDestination -Force -EnableException
    }
    if ($MigrateAgentOperators) {
        Copy-DbaAgentOperator -Source $Pair.Source -Destination $Pair.Target -Force -EnableException
    }
}

function Invoke-LinkedServerConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Pair,
        [Parameter(Mandatory)][string] $CsvPath
    )

    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        throw "Linked server configuration CSV not found: $CsvPath"
    }
    $rows = @(Import-Csv -LiteralPath $CsvPath)
    foreach ($requiredColumn in @('LinkedServer', 'Provider', 'Product', 'DataSource', 'SecurityMode')) {
        if ($rows.Count -gt 0 -and $requiredColumn -notin $rows[0].PSObject.Properties.Name) {
            throw "Linked server CSV is missing required column '$requiredColumn'."
        }
    }

    foreach ($row in $rows) {
        if ([string]::IsNullOrWhiteSpace($row.LinkedServer) -or [string]::IsNullOrWhiteSpace($row.Provider) -or
            [string]::IsNullOrWhiteSpace($row.Product) -or [string]::IsNullOrWhiteSpace($row.DataSource)) {
            throw 'Each linked server CSV row must provide LinkedServer, Provider, Product, and DataSource values.'
        }
        $parameters = @{
            SqlInstance = $Pair.Target
            LinkedServer = $row.LinkedServer
            Provider = $row.Provider
            ServerProduct = $row.Product
            DataSource = $row.DataSource
            SecurityContext = $row.SecurityMode
            EnableException = $true
        }
        if ($row.SecurityMode -notin @('NoConnection', 'WithoutSecurityContext', 'CurrentSecurityContext', 'SpecifiedSecurityContext')) {
            throw "Linked server '$($row.LinkedServer)' has an unsupported SecurityMode '$($row.SecurityMode)'."
        }
        if ($row.PSObject.Properties.Name -contains 'Catalog' -and $row.Catalog) {
            $parameters.Catalog = $row.Catalog
        }
        if ($row.PSObject.Properties.Name -contains 'RemoteUser' -and $row.RemoteUser) {
            if (-not ($row.PSObject.Properties.Name -contains 'PasswordEnvironmentVariable') -or -not $row.PasswordEnvironmentVariable) {
                throw "Linked server '$($row.LinkedServer)' specifies RemoteUser but no PasswordEnvironmentVariable."
            }
            $password = [Environment]::GetEnvironmentVariable($row.PasswordEnvironmentVariable)
            if ([string]::IsNullOrEmpty($password)) {
                throw "Environment variable '$($row.PasswordEnvironmentVariable)' is not set for linked server '$($row.LinkedServer)'."
            }
            if ($row.SecurityMode -ne 'SpecifiedSecurityContext') {
                throw "Linked server '$($row.LinkedServer)' must use SecurityMode 'SpecifiedSecurityContext' when RemoteUser is set."
            }
            $parameters.SecurityContextRemoteUser = $row.RemoteUser
            $parameters.SecurityContextRemoteUserPassword = ConvertTo-SecureString -String $password -AsPlainText -Force
        }
        elseif ($row.SecurityMode -eq 'SpecifiedSecurityContext') {
            throw "Linked server '$($row.LinkedServer)' requires RemoteUser and PasswordEnvironmentVariable for SpecifiedSecurityContext."
        }
        $existingLinkedServer = @(Get-DbaLinkedServer -SqlInstance $Pair.Target -LinkedServer $row.LinkedServer -EnableException)
        if ($existingLinkedServer.Count -gt 0) {
            Write-Verbose "Linked server '$($row.LinkedServer)' already exists on '$($Pair.Target)'; leaving it unchanged."
            continue
        }
        New-DbaLinkedServer @parameters
    }
}

function Invoke-DatabasePostMigration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SqlInstance,
        [Parameter(Mandatory)][string] $Database,
        [Parameter()][bool] $UpdateStatistics = $true,
        [Parameter()][bool] $RepairOrphanUsers = $true
    )

    if ($RepairOrphanUsers) {
        Repair-DbaDbOrphanUser -SqlInstance $SqlInstance -Database $Database -EnableException
    }
    if ($UpdateStatistics) {
        Invoke-DbaQuery -SqlInstance $SqlInstance -Database $Database -Query 'EXEC sys.sp_updatestats;' -EnableException
    }
}

Export-ModuleMember -Function Invoke-ServerObjectMigration, Invoke-LinkedServerConfiguration, Invoke-DatabasePostMigration
