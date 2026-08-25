#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Verifies workshop progress and prints, per exercise, whether it is DONE or INCOMPLETE.

.DESCRIPTION
    Checks the Azure resources that each exercise of "Azure Secure Networking for
    Developers" is expected to produce and reports a tick list per exercise:

        Exercise 0 (Prerequisites)  -> DONE
        Exercise 1 Virtual networks -> DONE
        Exercise 2 Private network  -> INCOMPLETE (4/9)
        ...

    It is READ-ONLY (only 'az ... show/list' calls) and safe to run any number of
    times. Attendees can run it after finishing an exercise to self-check, e.g.
    "-Exercise 2" to check just exercise 2. Instructors can run it with no filter to
    see the whole picture.

.PARAMETER TeamName
    Lower-case alphanumeric, 2-10 chars. Same value used to provision the resources.

.PARAMETER Exercise
    One or more exercise numbers (0-7) to check. Omit to check all.

.PARAMETER Strict
    Exit with code 1 unless exercises 0-6 are all complete (exercise 7 is a bonus and
    is never required). Useful for CI / automated verification. Default exit is 0.

.EXAMPLE
    ./verify-progress.ps1 -TeamName myteam

.EXAMPLE
    ./verify-progress.ps1 -TeamName myteam -Exercise 4

.EXAMPLE
    ./verify-progress.ps1 -TeamName myteam -Strict
#>

param(
    [Parameter(Mandatory = $true)][string]$TeamName,
    [string]$EuLocation = "westeurope",
    [string]$UsLocation = "eastus2",
    [string]$HubLocation = "swedencentral",
    [int[]]$Exercise,
    [switch]$Strict
)

$Environment = "dev"

# ---------------------------------------------------------------------------
# Derived resource names (must match set-resource-names.ps1 and the subscripts)
# ---------------------------------------------------------------------------
$rg = @{ eu = "rg-$TeamName-$Environment-eu"; us = "rg-$TeamName-$Environment-us"; hub = "rg-$TeamName-$Environment-hub" }
$st = @{ eu = "st${TeamName}${Environment}eu"; us = "st${TeamName}${Environment}us"; hub = "st${TeamName}${Environment}hub" }
$asp = @{ eu = "asp-$TeamName-$Environment-eu"; us = "asp-$TeamName-$Environment-us" }
$app = @{ eu = "app-$TeamName-$Environment-eu"; us = "app-$TeamName-$Environment-us" }
$vnet = @{ eu = "vnet-$TeamName-$Environment-eu"; us = "vnet-$TeamName-$Environment-us"; hub = "vnet-$TeamName-$Environment-hub" }
$snetDefault = @{ eu = "snet-default-$TeamName-$Environment-eu"; us = "snet-default-$TeamName-$Environment-us"; hub = "snet-default-$TeamName-$Environment-hub" }
$snetApps = @{ eu = "snet-apps-$TeamName-$Environment-eu"; us = "snet-apps-$TeamName-$Environment-us" }
$routeTable = @{ eu = "rt-$TeamName-$Environment-eu"; us = "rt-$TeamName-$Environment-us"; hub = "rt-$TeamName-$Environment-hub" }
$firewallName = "afw-$TeamName-$Environment-$HubLocation"
$bastionName = "bas-$TeamName-$Environment"
$bastionPip = "pip-bastion-$TeamName-$Environment"
$jumpboxVm = "vm${TeamName}hub"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-Json {
    param([string[]]$AzArgs)
    $raw = az @AzArgs -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $null }
}

function New-Check([string]$Name, [bool]$Ok, [string]$Detail = "") {
    [pscustomobject]@{ Name = $Name; Ok = [bool]$Ok; Detail = $Detail }
}

function Test-ResourceExists([string[]]$AzArgs) { return ($null -ne (Get-Json $AzArgs)) }

# ---------------------------------------------------------------------------
# Per-exercise checks (each returns a list of check objects)
# ---------------------------------------------------------------------------

function Test-Exercise0 {
    $c = @()
    foreach ($k in 'eu', 'us', 'hub') { $c += New-Check "Resource group $($rg[$k])" (Test-ResourceExists @('group', 'show', '--name', $rg[$k])) }
    foreach ($k in 'eu', 'us', 'hub') { $c += New-Check "Storage account $($st[$k])" (Test-ResourceExists @('storage', 'account', 'show', '--name', $st[$k], '--resource-group', $rg[$k])) }
    foreach ($k in 'eu', 'us') { $c += New-Check "App service plan $($asp[$k])" (Test-ResourceExists @('appservice', 'plan', 'show', '--name', $asp[$k], '--resource-group', $rg[$k])) }
    foreach ($k in 'eu', 'us') { $c += New-Check "Web app $($app[$k])" (Test-ResourceExists @('webapp', 'show', '--name', $app[$k], '--resource-group', $rg[$k])) }
    $c += New-Check "Hub VNet $($vnet.hub)" (Test-ResourceExists @('network', 'vnet', 'show', '--name', $vnet.hub, '--resource-group', $rg.hub))
    $c += New-Check "Hub default subnet" (Test-ResourceExists @('network', 'vnet', 'subnet', 'show', '--name', $snetDefault.hub, '--vnet-name', $vnet.hub, '--resource-group', $rg.hub))
    $c += New-Check "Jumpbox VM $jumpboxVm" (Test-ResourceExists @('vm', 'show', '--name', $jumpboxVm, '--resource-group', $rg.hub))
    return $c
}

function Test-Exercise1 {
    $c = @()
    $expected = @{ eu = "10.0.4.0/22"; us = "10.0.8.0/22" }
    foreach ($k in 'eu', 'us') {
        $vn = Get-Json @('network', 'vnet', 'show', '--name', $vnet[$k], '--resource-group', $rg[$k])
        if ($null -eq $vn) { $c += New-Check "VNet $($vnet[$k])" $false "not found"; continue }
        $prefixes = @($vn.addressSpace.addressPrefixes)
        $c += New-Check "VNet $($vnet[$k]) ($($expected[$k]))" ($prefixes -contains $expected[$k]) "prefixes=$($prefixes -join ',')"
    }
    return $c
}

function Test-Exercise2 {
    $c = @()
    # Subnets (default + apps, apps delegated to Microsoft.Web/serverFarms)
    foreach ($k in 'eu', 'us') {
        $c += New-Check "Default subnet ($k)" (Test-ResourceExists @('network', 'vnet', 'subnet', 'show', '--name', $snetDefault[$k], '--vnet-name', $vnet[$k], '--resource-group', $rg[$k]))
        $appsSn = Get-Json @('network', 'vnet', 'subnet', 'show', '--name', $snetApps[$k], '--vnet-name', $vnet[$k], '--resource-group', $rg[$k])
        $delegated = $null -ne $appsSn -and (@($appsSn.delegations | Where-Object { $_.serviceName -eq 'Microsoft.Web/serverFarms' }).Count -ge 1)
        $c += New-Check "Apps subnet delegated ($k)" $delegated
    }
    # Private DNS zones + 3 vnet links each
    foreach ($zone in 'privatelink.azurewebsites.net', 'privatelink.blob.core.windows.net') {
        $z = Get-Json @('network', 'private-dns', 'zone', 'show', '--name', $zone, '--resource-group', $rg.hub)
        if ($null -eq $z) { $c += New-Check "Private DNS zone $zone" $false "not found"; continue }
        $links = @(Get-Json @('network', 'private-dns', 'link', 'vnet', 'list', '--zone-name', $zone, '--resource-group', $rg.hub))
        $c += New-Check "DNS zone $zone (3 vnet links)" ($links.Count -ge 3) "links=$($links.Count)"
    }
    # Private endpoints (2 app + 3 storage) Succeeded
    $pe = @(
        @{ rg = $rg.eu; name = "pep-$($app.eu)" }, @{ rg = $rg.us; name = "pep-$($app.us)" },
        @{ rg = $rg.eu; name = "pep-$($st.eu)" }, @{ rg = $rg.us; name = "pep-$($st.us)" }, @{ rg = $rg.hub; name = "pep-$($st.hub)" }
    )
    foreach ($p in $pe) {
        $obj = Get-Json @('network', 'private-endpoint', 'show', '--name', $p.name, '--resource-group', $p.rg)
        $c += New-Check "Private endpoint $($p.name)" ($null -ne $obj -and $obj.provisioningState -eq 'Succeeded') $(if ($obj) { $obj.provisioningState } else { "not found" })
    }
    # Public access disabled
    foreach ($k in 'eu', 'us', 'hub') {
        $sa = Get-Json @('storage', 'account', 'show', '--name', $st[$k], '--resource-group', $rg[$k])
        $c += New-Check "Storage public access disabled ($k)" ($null -ne $sa -and $sa.publicNetworkAccess -eq 'Disabled')
    }
    foreach ($k in 'eu', 'us') {
        $wa = Get-Json @('webapp', 'show', '--name', $app[$k], '--resource-group', $rg[$k])
        $c += New-Check "Web app public access disabled ($k)" ($null -ne $wa -and $wa.publicNetworkAccess -eq 'Disabled')
        $vi = @(Get-Json @('webapp', 'vnet-integration', 'list', '--name', $app[$k], '--resource-group', $rg[$k]))
        $c += New-Check "Web app VNet integration ($k)" ($vi.Count -ge 1)
    }
    return $c
}

function Test-Exercise3 {
    $c = @()
    $hub = @(Get-Json @('network', 'vnet', 'peering', 'list', '--resource-group', $rg.hub, '--vnet-name', $vnet.hub))
    $hubOk = $hub.Count -ge 2 -and (@($hub | Where-Object { $_.peeringState -ne 'Connected' }).Count -eq 0)
    $c += New-Check "Hub peerings connected (hub<->eu, hub<->us)" $hubOk "count=$($hub.Count)"
    $eu = @(Get-Json @('network', 'vnet', 'peering', 'list', '--resource-group', $rg.eu, '--vnet-name', $vnet.eu))
    $euOk = $eu.Count -ge 1 -and (@($eu | Where-Object { $_.peeringState -ne 'Connected' }).Count -eq 0)
    $c += New-Check "EU spoke peerings connected" $euOk "count=$($eu.Count)"
    return $c
}

function Test-Exercise4 {
    $c = @()
    $c += New-Check "AzureBastionSubnet in hub" (Test-ResourceExists @('network', 'vnet', 'subnet', 'show', '--name', 'AzureBastionSubnet', '--vnet-name', $vnet.hub, '--resource-group', $rg.hub))
    $c += New-Check "Bastion public IP $bastionPip" (Test-ResourceExists @('network', 'public-ip', 'show', '--name', $bastionPip, '--resource-group', $rg.hub))
    $bas = Get-Json @('network', 'bastion', 'show', '--name', $bastionName, '--resource-group', $rg.hub)
    $c += New-Check "Azure Bastion $bastionName" ($null -ne $bas -and $bas.provisioningState -eq 'Succeeded') $(if ($bas) { $bas.provisioningState } else { "not found" })
    return $c
}

function Test-Exercise5 {
    $c = @()
    $c += New-Check "AzureFirewallSubnet in hub" (Test-ResourceExists @('network', 'vnet', 'subnet', 'show', '--name', 'AzureFirewallSubnet', '--vnet-name', $vnet.hub, '--resource-group', $rg.hub))
    $fw = Get-Json @('network', 'firewall', 'show', '--name', $firewallName, '--resource-group', $rg.hub)
    $c += New-Check "Azure Firewall $firewallName" ($null -ne $fw) $(if ($fw) { "tier=$($fw.sku.tier)" } else { "not found" })
    $fwIp = az network firewall ip-config list --resource-group $rg.hub --firewall-name $firewallName --query "[0].privateIpAddress" -o tsv 2>$null
    $c += New-Check "Firewall private IP" (-not [string]::IsNullOrWhiteSpace($fwIp)) "ip=$fwIp"
    foreach ($k in 'hub', 'eu', 'us') {
        $routes = @(Get-Json @('network', 'route-table', 'route', 'list', '--resource-group', $rg[$k], '--route-table-name', $routeTable[$k]))
        $default = @($routes | Where-Object { $_.addressPrefix -eq '0.0.0.0/0' -and $_.nextHopType -eq 'VirtualAppliance' })
        $ok = $default.Count -ge 1 -and (-not [string]::IsNullOrWhiteSpace($fwIp)) -and ($default[0].nextHopIpAddress -eq $fwIp)
        $c += New-Check "Route table $($routeTable[$k]) -> firewall" $ok $(if ($default.Count) { "nextHop=$($default[0].nextHopIpAddress)" } else { "no default route" })
    }
    return $c
}

function Test-Exercise6 {
    $c = @()
    foreach ($k in 'eu', 'us') {
        $asgName = "asg-storage-$TeamName-$Environment-$k"
        $c += New-Check "ASG $asgName" (Test-ResourceExists @('network', 'asg', 'show', '--name', $asgName, '--resource-group', $rg[$k]))

        $nsgName = "nsg-$($snetDefault[$k])"
        $rules = Get-Json @('network', 'nsg', 'rule', 'list', '--nsg-name', $nsgName, '--resource-group', $rg[$k])
        if ($null -eq $rules) {
            $c += New-Check "NSG $nsgName (deny+allow rules)" $false "not found"
        }
        else {
            $names = @($rules | ForEach-Object { $_.name })
            $ruleOk = ($names -contains 'DenyAllToStorageInbound') -and ($names -contains 'AllowAppServiceToStorageInbound')
            $c += New-Check "NSG $nsgName (deny+allow rules)" $ruleOk
        }
        # Default subnet must have the NSG attached
        $sn = Get-Json @('network', 'vnet', 'subnet', 'show', '--name', $snetDefault[$k], '--vnet-name', $vnet[$k], '--resource-group', $rg[$k])
        $attached = $null -ne $sn -and $null -ne $sn.networkSecurityGroup -and $sn.networkSecurityGroup.id -match [regex]::Escape($nsgName)
        $c += New-Check "Default subnet has NSG ($k)" $attached
    }
    return $c
}

function Test-Exercise7 {
    # Bonus / open-ended: any public-access solution counts.
    $c = @()
    $found = $false
    $detail = ""
    $afd = @(Get-Json @('afd', 'profile', 'list'))
    $fd = @(Get-Json @('network', 'front-door', 'list'))
    if ($afd.Count -gt 0 -or $fd.Count -gt 0) { $found = $true; $detail = "Front Door" }
    foreach ($k in 'eu', 'us', 'hub') {
        if (-not $found) {
            $agw = @(Get-Json @('network', 'application-gateway', 'list', '--resource-group', $rg[$k]))
            if ($agw.Count -gt 0) { $found = $true; $detail = "Application Gateway" }
            $lb = @(Get-Json @('network', 'lb', 'list', '--resource-group', $rg[$k]))
            if ((-not $found) -and $lb.Count -gt 0) { $found = $true; $detail = "Load Balancer" }
        }
    }
    $tm = @(Get-Json @('network', 'traffic-manager', 'profile', 'list'))
    if ((-not $found) -and $tm.Count -gt 0) { $found = $true; $detail = "Traffic Manager" }

    $c += New-Check "Public-access solution deployed (bonus)" $found $(if ($found) { $detail } else { "none found (open-ended: Front Door / App Gateway / etc.)" })
    return $c
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if ($TeamName.Length -lt 2 -or $TeamName.Length -gt 10 -or $TeamName -cnotmatch '^[a-z0-9]+$') {
    Write-Error "Invalid TeamName '$TeamName'. Must be 2-10 lower-case alphanumeric characters."
    exit 2
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI (az) not found. Run this in Azure Cloud Shell or install the Azure CLI."
    exit 2
}
if ($null -eq (Get-Json @('account', 'show'))) {
    Write-Error "Not logged in to Azure. Run 'az login' and 'az account set --subscription <id>'."
    exit 2
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
$definitions = @(
    @{ N = 0; Title = "Prerequisites"; Fn = { Test-Exercise0 }; Bonus = $false },
    @{ N = 1; Title = "Virtual networks"; Fn = { Test-Exercise1 }; Bonus = $false },
    @{ N = 2; Title = "Private network"; Fn = { Test-Exercise2 }; Bonus = $false },
    @{ N = 3; Title = "Virtual network peering"; Fn = { Test-Exercise3 }; Bonus = $false },
    @{ N = 4; Title = "Azure Bastion"; Fn = { Test-Exercise4 }; Bonus = $false },
    @{ N = 5; Title = "Firewall and routing"; Fn = { Test-Exercise5 }; Bonus = $false },
    @{ N = 6; Title = "ASGs and NSGs"; Fn = { Test-Exercise6 }; Bonus = $false },
    @{ N = 7; Title = "Public access (bonus)"; Fn = { Test-Exercise7 }; Bonus = $true }
)

if ($Exercise) { $definitions = $definitions | Where-Object { $Exercise -contains $_.N } }

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  WORKSHOP PROGRESS - team '$TeamName'" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

$summary = @()
foreach ($def in $definitions) {
    Write-Host ""
    Write-Host ("Exercise {0}: {1}" -f $def.N, $def.Title) -ForegroundColor White
    $checks = & $def.Fn
    foreach ($chk in $checks) {
        $mark = if ($chk.Ok) { "[x]" } else { "[ ]" }
        $color = if ($chk.Ok) { "Green" } else { "Red" }
        $line = "  {0} {1}{2}" -f $mark, $chk.Name, $(if ($chk.Detail) { " ($($chk.Detail))" } else { "" })
        Write-Host $line -ForegroundColor $color
    }
    $total = @($checks).Count
    $passed = @($checks | Where-Object { $_.Ok }).Count
    $done = ($passed -eq $total -and $total -gt 0)
    $verdict = if ($done) { "DONE" } else { "INCOMPLETE ($passed/$total)" }
    Write-Host ("  => {0}" -f $verdict) -ForegroundColor $(if ($done) { "Green" } else { "Yellow" })
    $summary += [pscustomobject]@{ N = $def.N; Title = $def.Title; Done = $done; Passed = $passed; Total = $total; Bonus = $def.Bonus }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("-" * 70) -ForegroundColor Cyan
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host ("-" * 70) -ForegroundColor Cyan
foreach ($s in $summary) {
    $label = "Exercise {0}: {1}" -f $s.N, $s.Title
    $status = if ($s.Done) { "DONE" } else { "INCOMPLETE ($($s.Passed)/$($s.Total))" }
    $dots = "." * [Math]::Max(3, 44 - $label.Length)
    Write-Host ("  {0} {1} {2}" -f $label, $dots, $status) -ForegroundColor $(if ($s.Done) { "Green" } else { "Yellow" })
}

$required = @($summary | Where-Object { -not $_.Bonus })
$requiredDone = @($required | Where-Object { $_.Done }).Count
Write-Host ""
Write-Host ("  Completed (required): {0} / {1} exercises" -f $requiredDone, $required.Count) -ForegroundColor Cyan

if ($Strict -and $requiredDone -lt $required.Count) {
    exit 1
}
exit 0
