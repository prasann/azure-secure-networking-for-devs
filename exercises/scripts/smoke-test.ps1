#!/usr/bin/env pwsh
<#
.SYNOPSIS
    End-to-end smoke test for the "Azure Secure Networking for Developers" workshop.

.DESCRIPTION
    Runs every provisioning stage in the same order as run-all.ps1, but with three
    important differences:
      1. Preflight checks (Azure login, subscription, team name, PowerShell 7).
      2. Each stage runs as an isolated child process so a failure is captured and
         reported instead of silently continuing or killing the whole run.
      3. After provisioning it VALIDATES the resulting Azure state (resource groups,
         storage, web apps, VNets, private endpoints, DNS, peering, Bastion, firewall,
         routing, NSGs/ASGs) and prints a PASS/FAIL summary. Exit code is 0 only if
         every check passed.

    IMPORTANT: this creates real Azure resources (App Service, Bastion, Azure Firewall,
    etc.) and therefore incurs cost. Bastion and Firewall are billed per hour. Use
    -CleanupAfter to delete the three resource groups when the run finishes.

.PARAMETER TeamName
    Lower-case alphanumeric, 2-10 chars. Used in every resource name.

.PARAMETER SkipProvision
    Skip provisioning and only run the validation checks against an existing deployment.

.PARAMETER ContinueOnError
    Do not stop at the first failed stage; run every stage, then validate.

.PARAMETER CleanupAfter
    Delete the three resource groups (rg-<team>-dev-eu/us/hub) at the end.

.PARAMETER Force
    Skip the interactive confirmation prompt.

.EXAMPLE
    ./smoke-test.ps1 -TeamName myteam

.EXAMPLE
    ./smoke-test.ps1 -TeamName myteam -SkipProvision      # only re-validate

.EXAMPLE
    ./smoke-test.ps1 -TeamName myteam -CleanupAfter -Force
#>

param(
    [Parameter(Mandatory = $true)][string]$TeamName,
    [string]$EuLocation = "westeurope",
    [string]$UsLocation = "eastus2",
    [string]$HubLocation = "swedencentral",
    [string]$JumpboxAdminUsername = "jumpboxuser",
    [string]$JumpboxAdminPassword = "JumpboxPassword123!",
    [switch]$SkipProvision,
    [switch]$ContinueOnError,
    [switch]$CleanupAfter,
    [switch]$Force
)

$Environment = "dev"
$script:Results = @()
$StartTime = Get-Date

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor Cyan
}

function Add-Result([string]$Name, [bool]$Ok, [string]$Detail = "") {
    $status = if ($Ok) { "PASS" } else { "FAIL" }
    $color = if ($Ok) { "Green" } else { "Red" }
    Write-Host ("  [{0}] {1}{2}" -f $status, $Name, $(if ($Detail) { " - $Detail" } else { "" })) -ForegroundColor $color
    $script:Results += [pscustomobject]@{ Check = $Name; Status = $status; Detail = $Detail }
}

# Run an az command and return parsed JSON, or $null on any failure/empty output.
function Get-Json {
    param([string[]]$AzArgs)
    $raw = az @AzArgs -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $null }
}

# Retry a boolean scriptblock until it is true or the timeout elapses (eventual consistency).
function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutSec = 180, [int]$IntervalSec = 15)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Seconds $IntervalSec
    }
    return [bool](& $Condition)
}

function Invoke-Stage {
    param([string]$Title, [string]$ScriptPath, [string[]]$ScriptArgs)

    Write-Section "STAGE: $Title"
    if (-not (Test-Path $ScriptPath)) {
        Add-Result "Stage: $Title" $false "script not found: $ScriptPath"
        if (-not $ContinueOnError) { throw "Stage script missing: $ScriptPath" }
        return
    }

    $stageStart = Get-Date
    & $script:PwshExe -NoLogo -NoProfile -File $ScriptPath @ScriptArgs
    $code = $LASTEXITCODE
    $seconds = [int]((Get-Date) - $stageStart).TotalSeconds
    $ok = ($code -eq 0)
    Add-Result "Stage: $Title" $ok "exit=$code, ${seconds}s"

    if (-not $ok -and -not $ContinueOnError) {
        throw "Stage '$Title' failed (exit $code). Re-run with -ContinueOnError to push through."
    }
}

# ---------------------------------------------------------------------------
# Resolve tooling and derived resource names
# ---------------------------------------------------------------------------

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
$script:PwshExe = if ($pwshCmd) { $pwshCmd.Source } else { "pwsh" }

$rg = @{
    eu  = "rg-$TeamName-$Environment-eu"
    us  = "rg-$TeamName-$Environment-us"
    hub = "rg-$TeamName-$Environment-hub"
}
$st = @{
    eu  = "st${TeamName}${Environment}eu"
    us  = "st${TeamName}${Environment}us"
    hub = "st${TeamName}${Environment}hub"
}
$app = @{
    eu = "app-$TeamName-$Environment-eu"
    us = "app-$TeamName-$Environment-us"
}
$vnet = @{
    eu  = "vnet-$TeamName-$Environment-eu"
    us  = "vnet-$TeamName-$Environment-us"
    hub = "vnet-$TeamName-$Environment-hub"
}
$snetDefault = @{
    eu  = "snet-default-$TeamName-$Environment-eu"
    us  = "snet-default-$TeamName-$Environment-us"
    hub = "snet-default-$TeamName-$Environment-hub"
}
$snetApps = @{
    eu = "snet-apps-$TeamName-$Environment-eu"
    us = "snet-apps-$TeamName-$Environment-us"
}
$firewallName = "afw-$TeamName-$Environment-$HubLocation"
$bastionName = "bas-$TeamName-$Environment"
$routeTable = @{
    eu  = "rt-$TeamName-$Environment-eu"
    us  = "rt-$TeamName-$Environment-us"
    hub = "rt-$TeamName-$Environment-hub"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

Write-Section "PREFLIGHT"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warning "PowerShell 7+ is recommended (Azure Cloud Shell uses it). Detected $($PSVersionTable.PSVersion)."
}

if ($TeamName.Length -lt 2 -or $TeamName.Length -gt 10 -or $TeamName -cnotmatch '^[a-z0-9]+$') {
    Write-Error "Invalid TeamName '$TeamName'. Must be 2-10 lower-case alphanumeric characters."
    exit 2
}
Add-Result "Team name valid" $true $TeamName

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI (az) not found. Run this in Azure Cloud Shell or install the Azure CLI."
    exit 2
}

$account = Get-Json @('account', 'show')
if ($null -eq $account) {
    Write-Error "Not logged in to Azure (az account show failed). Run 'az login' and 'az account set --subscription <id>'."
    exit 2
}
Add-Result "Azure login / subscription" $true "$($account.name) ($($account.id))"

# Make config available to every child process.
$env:TEAM_NAME = $TeamName
$env:EU_LOCATION = $EuLocation
$env:US_LOCATION = $UsLocation
$env:HUB_LOCATION = $HubLocation

Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Team name : $TeamName"
Write-Host "  Hub       : $HubLocation"
Write-Host "  EU        : $EuLocation"
Write-Host "  US        : $UsLocation"
Write-Host "  Subscription: $($account.name)"

if (-not $SkipProvision -and -not $Force) {
    Write-Host ""
    Write-Warning "This will CREATE real, billable Azure resources (App Service, Bastion, Azure Firewall, etc.)."
    $answer = Read-Host "Type 'yes' to proceed"
    if ($answer -ne 'yes') {
        Write-Host "Aborted by user." -ForegroundColor Yellow
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Provisioning stages (same order as run-all.ps1)
# ---------------------------------------------------------------------------

if ($SkipProvision) {
    Write-Host "`n-SkipProvision set: skipping provisioning, running validation only.`n" -ForegroundColor Yellow
}
else {
    try {
        Invoke-Stage "0. Prerequisites" ".\0-prerequisites.ps1" @(
            '-TeamName', $TeamName, '-EuLocation', $EuLocation, '-UsLocation', $UsLocation,
            '-HubLocation', $HubLocation, '-JumpboxAdminUsername', $JumpboxAdminUsername,
            '-JumpboxAdminPassword', $JumpboxAdminPassword)

        Invoke-Stage "1. Virtual networks" ".\1-vnets.ps1" @(
            '-TeamName', $TeamName, '-EuLocation', $EuLocation, '-UsLocation', $UsLocation)

        Invoke-Stage "2. Private network" ".\2-private-network.ps1" @(
            '-TeamName', $TeamName, '-EuLocation', $EuLocation, '-UsLocation', $UsLocation,
            '-HubLocation', $HubLocation)

        Invoke-Stage "3. VNet peerings" ".\3-vnet-peerings.ps1" @('-TeamName', $TeamName)

        Invoke-Stage "4. Bastion + jumpbox" ".\4-bastion-jumpbox.ps1" @(
            '-TeamName', $TeamName, '-Location', $HubLocation)

        Invoke-Stage "5. Firewall + routing" ".\5-firewall.ps1" @(
            '-TeamName', $TeamName, '-HubLocation', $HubLocation)

        Invoke-Stage "6. ASGs + NSGs" ".\6-asgs-nsgs.ps1" @(
            '-TeamName', $TeamName, '-EuLocation', $EuLocation, '-UsLocation', $UsLocation,
            '-HubLocation', $HubLocation)
    }
    catch {
        Write-Host ""
        Write-Warning $_.Exception.Message
        Write-Warning "Provisioning stopped early. Validation below will show how far it got."
    }
}

# ---------------------------------------------------------------------------
# Validation of the resulting Azure state
# ---------------------------------------------------------------------------

Write-Section "VALIDATION"

# Resource groups
foreach ($k in 'eu', 'us', 'hub') {
    $exists = $null -ne (Get-Json @('group', 'show', '--name', $rg[$k]))
    Add-Result "Resource group $($rg[$k])" $exists
}

# Storage accounts + hardening
foreach ($k in 'eu', 'us', 'hub') {
    $sa = Get-Json @('storage', 'account', 'show', '--name', $st[$k], '--resource-group', $rg[$k])
    if ($null -eq $sa) {
        Add-Result "Storage account $($st[$k])" $false "not found"
        continue
    }
    Add-Result "Storage account $($st[$k])" $true "publicAccess=$($sa.publicNetworkAccess); sharedKey=$($sa.allowSharedKeyAccess); tls=$($sa.minimumTlsVersion)"
    Add-Result "  -> public access disabled ($($st[$k]))" ($sa.publicNetworkAccess -eq 'Disabled')
    Add-Result "  -> shared key disabled ($($st[$k]))" ($sa.allowSharedKeyAccess -eq $false)
    Add-Result "  -> TLS1_2 minimum ($($st[$k]))" ($sa.minimumTlsVersion -eq 'TLS1_2')
}

# Web apps
foreach ($k in 'eu', 'us') {
    $wa = Get-Json @('webapp', 'show', '--name', $app[$k], '--resource-group', $rg[$k])
    if ($null -eq $wa) {
        Add-Result "Web app $($app[$k])" $false "not found (check the app-/asp- naming fix)"
        continue
    }
    Add-Result "Web app $($app[$k])" $true "state=$($wa.state); httpsOnly=$($wa.httpsOnly); publicAccess=$($wa.publicNetworkAccess)"
    Add-Result "  -> HTTPS only ($($app[$k]))" ($wa.httpsOnly -eq $true)
    Add-Result "  -> public access disabled ($($app[$k]))" ($wa.publicNetworkAccess -eq 'Disabled')
}

# VNets with expected address space
$expectedPrefix = @{ hub = "10.0.0.0/22"; eu = "10.0.4.0/22"; us = "10.0.8.0/22" }
foreach ($k in 'hub', 'eu', 'us') {
    $vn = Get-Json @('network', 'vnet', 'show', '--name', $vnet[$k], '--resource-group', $rg[$k])
    if ($null -eq $vn) {
        Add-Result "VNet $($vnet[$k])" $false "not found"
        continue
    }
    $prefixes = @($vn.addressSpace.addressPrefixes)
    Add-Result "VNet $($vnet[$k])" ($prefixes -contains $expectedPrefix[$k]) "prefixes=$($prefixes -join ',')"
}

# Key subnets
$subnetChecks = @(
    @{ rg = $rg.hub; vnet = $vnet.hub; name = $snetDefault.hub },
    @{ rg = $rg.hub; vnet = $vnet.hub; name = "AzureBastionSubnet" },
    @{ rg = $rg.hub; vnet = $vnet.hub; name = "AzureFirewallSubnet" },
    @{ rg = $rg.eu; vnet = $vnet.eu; name = $snetDefault.eu },
    @{ rg = $rg.eu; vnet = $vnet.eu; name = $snetApps.eu },
    @{ rg = $rg.us; vnet = $vnet.us; name = $snetDefault.us },
    @{ rg = $rg.us; vnet = $vnet.us; name = $snetApps.us }
)
foreach ($s in $subnetChecks) {
    $sn = Get-Json @('network', 'vnet', 'subnet', 'show', '--name', $s.name, '--vnet-name', $s.vnet, '--resource-group', $s.rg)
    Add-Result "Subnet $($s.name)" ($null -ne $sn)
}

# Private endpoints (2 app + 3 storage) reaching Succeeded
$peExpected = @(
    @{ rg = $rg.eu; name = "pep-$($app.eu)" },
    @{ rg = $rg.us; name = "pep-$($app.us)" },
    @{ rg = $rg.eu; name = "pep-$($st.eu)" },
    @{ rg = $rg.us; name = "pep-$($st.us)" },
    @{ rg = $rg.hub; name = "pep-$($st.hub)" }
)
foreach ($pe in $peExpected) {
    $ok = Wait-Until -TimeoutSec 120 -IntervalSec 15 -Condition {
        $p = Get-Json @('network', 'private-endpoint', 'show', '--name', $pe.name, '--resource-group', $pe.rg)
        $null -ne $p -and $p.provisioningState -eq 'Succeeded'
    }
    Add-Result "Private endpoint $($pe.name)" $ok
}

# Private DNS zones + links
foreach ($zone in 'privatelink.azurewebsites.net', 'privatelink.blob.core.windows.net') {
    $z = Get-Json @('network', 'private-dns', 'zone', 'show', '--name', $zone, '--resource-group', $rg.hub)
    if ($null -eq $z) {
        Add-Result "Private DNS zone $zone" $false "not found"
        continue
    }
    $links = Get-Json @('network', 'private-dns', 'link', 'vnet', 'list', '--zone-name', $zone, '--resource-group', $rg.hub)
    $linkCount = @($links).Count
    Add-Result "Private DNS zone $zone" ($linkCount -ge 3) "vnet links=$linkCount (expected 3)"
}

# VNet peerings connected (hub<->eu, hub<->us, eu<->us)
$peerings = Get-Json @('network', 'vnet', 'peering', 'list', '--resource-group', $rg.hub, '--vnet-name', $vnet.hub)
$hubPeerCount = @($peerings).Count
$hubPeerConnected = ($hubPeerCount -ge 2) -and (@($peerings | Where-Object { $_.peeringState -ne 'Connected' }).Count -eq 0)
Add-Result "Hub peerings connected" $hubPeerConnected "count=$hubPeerCount"

$euPeerings = Get-Json @('network', 'vnet', 'peering', 'list', '--resource-group', $rg.eu, '--vnet-name', $vnet.eu)
Add-Result "EU peerings connected" (@($euPeerings).Count -ge 2 -and (@($euPeerings | Where-Object { $_.peeringState -ne 'Connected' }).Count -eq 0)) "count=$(@($euPeerings).Count)"

# Bastion
Add-Result "Azure Bastion $bastionName" ($null -ne (Get-Json @('network', 'bastion', 'show', '--name', $bastionName, '--resource-group', $rg.hub)))

# Firewall + private IP
$fw = Get-Json @('network', 'firewall', 'show', '--name', $firewallName, '--resource-group', $rg.hub)
Add-Result "Azure Firewall $firewallName" ($null -ne $fw) $(if ($fw) { "tier=$($fw.sku.tier)" } else { "not found" })
$fwPrivateIp = az network firewall ip-config list --resource-group $rg.hub --firewall-name $firewallName --query "[0].privateIpAddress" -o tsv 2>$null
Add-Result "Firewall private IP resolved" (-not [string]::IsNullOrWhiteSpace($fwPrivateIp)) "ip=$fwPrivateIp"

# Route tables with 0.0.0.0/0 -> firewall
foreach ($k in 'hub', 'eu', 'us') {
    $routes = Get-Json @('network', 'route-table', 'route', 'list', '--resource-group', $rg[$k], '--route-table-name', $routeTable[$k])
    $default = @($routes | Where-Object { $_.addressPrefix -eq '0.0.0.0/0' -and $_.nextHopType -eq 'VirtualAppliance' })
    $ok = $default.Count -ge 1 -and (-not [string]::IsNullOrWhiteSpace($fwPrivateIp)) -and ($default[0].nextHopIpAddress -eq $fwPrivateIp)
    Add-Result "Route table $($routeTable[$k]) -> firewall" $ok $(if ($default.Count) { "nextHop=$($default[0].nextHopIpAddress)" } else { "no default route" })
}

# NSGs + rules on the default (storage) subnets
foreach ($k in 'eu', 'us') {
    $nsgName = "nsg-$($snetDefault[$k])"
    $rules = Get-Json @('network', 'nsg', 'rule', 'list', '--nsg-name', $nsgName, '--resource-group', $rg[$k])
    if ($null -eq $rules) {
        Add-Result "NSG $nsgName" $false "not found"
        continue
    }
    $names = @($rules | ForEach-Object { $_.name })
    $hasAllow = $names -contains 'AllowAppServiceToStorageInbound'
    $hasDeny = $names -contains 'DenyAllToStorageInbound'
    Add-Result "NSG $nsgName rules" ($hasAllow -and $hasDeny) "allow=$hasAllow deny=$hasDeny"
}

# ASGs
foreach ($k in 'eu', 'us') {
    $asgName = "asg-storage-$TeamName-$Environment-$k"
    Add-Result "ASG $asgName" ($null -ne (Get-Json @('network', 'asg', 'show', '--name', $asgName, '--resource-group', $rg[$k])))
}

# ---------------------------------------------------------------------------
# Optional cleanup
# ---------------------------------------------------------------------------

if ($CleanupAfter) {
    Write-Section "CLEANUP"
    foreach ($k in 'eu', 'us', 'hub') {
        Write-Host "Deleting resource group $($rg[$k]) (async)..." -ForegroundColor Yellow
        az group delete --name $rg[$k] --yes --no-wait 2>$null | Out-Null
    }
    Write-Host "Cleanup requested. Deletions run in the background; verify in the portal." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Section "SUMMARY"

$passed = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$totalSeconds = [int]((Get-Date) - $StartTime).TotalSeconds

$script:Results | Format-Table -AutoSize Check, Status, Detail | Out-Host

Write-Host ""
Write-Host ("Total: {0}   Passed: {1}   Failed: {2}   Duration: {3}s" -f $script:Results.Count, $passed, $failed, $totalSeconds) -ForegroundColor Cyan

if ($failed -gt 0) {
    Write-Host "`nRESULT: FAIL - $failed check(s) failed. See the table above." -ForegroundColor Red
    exit 1
}
else {
    Write-Host "`nRESULT: PASS - the workshop provisioned and validated cleanly." -ForegroundColor Green
    exit 0
}
