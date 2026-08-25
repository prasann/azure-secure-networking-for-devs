#!/usr/bin/env pwsh

param(
    [string]$TeamName = $env:TEAM_NAME,
    [string]$EuLocation = $env:EU_LOCATION,
    [string]$UsLocation = $env:US_LOCATION,
    [string]$HubLocation = $env:HUB_LOCATION
)

if ($TeamName.Length -lt 2) {
    Write-Error "Invalid argument: Team name missing or too short (must be at least 2 characters long)"
    exit 1
}

if ($EuLocation.Length -eq 0) {
    Write-Error "Invalid argument: EU location missing"
    exit 1
}

if ($UsLocation.Length -eq 0) {
    Write-Error "Invalid argument: US location missing"
    exit 1
}

if ($HubLocation.Length -eq 0) {
    Write-Error "Invalid argument: Hub location missing"
    exit 1
}

$Environment = "dev"
$FirewallName = "afw-${TeamName}-${Environment}-${HubLocation}"
$ResourceGroupNameHub = $env:ASNFD_RESOURCE_GROUP_NAME_HUB

Write-Output "`nRetrieving the private IP address of firewall ${FirewallName}..."
# https://learn.microsoft.com/cli/azure/network/firewall/ip-config?view=azure-cli-latest#az-network-firewall-ip-config-list
$FirewallPrivateIpAddress = (az network firewall ip-config list `
        --resource-group $ResourceGroupNameHub `
        --firewall-name $FirewallName `
        --query "[0].privateIpAddress" `
        --output tsv)

if ([string]::IsNullOrWhiteSpace($FirewallPrivateIpAddress)) {
    Write-Error "Failed to retrieve the firewall private IP address. Make sure the firewall '${FirewallName}' exists (run 5-firewall.ps1 which provisions it first)."
    exit 1
}

Write-Output "Firewall private IP address: ${FirewallPrivateIpAddress}"

# Route table -> the subnets it should be associated with.
# We force all egress (0.0.0.0/0) from the workload subnets through the firewall.
# IMPORTANT: never associate a "0.0.0.0/0 -> firewall" route with AzureBastionSubnet or
# AzureFirewallSubnet - doing so breaks Bastion and the firewall itself. A route table
# can only be associated with a subnet in the same region, hence one table per virtual network.
$RouteTables = @(
    @{
        Name     = "rt-${TeamName}-${Environment}-hub"
        Location = $HubLocation
        Rg       = $env:ASNFD_RESOURCE_GROUP_NAME_HUB
        Vnet     = $env:ASNFD_VNET_NAME_HUB
        Subnets  = @($env:ASNFD_DEFAULT_SNET_NAME_HUB)
    },
    @{
        Name     = "rt-${TeamName}-${Environment}-eu"
        Location = $EuLocation
        Rg       = $env:ASNFD_RESOURCE_GROUP_NAME_EU
        Vnet     = $env:ASNFD_VNET_NAME_EU
        Subnets  = @($env:ASNFD_DEFAULT_SNET_NAME_EU, $env:ASNFD_APPS_SNET_NAME_EU)
    },
    @{
        Name     = "rt-${TeamName}-${Environment}-us"
        Location = $UsLocation
        Rg       = $env:ASNFD_RESOURCE_GROUP_NAME_US
        Vnet     = $env:ASNFD_VNET_NAME_US
        Subnets  = @($env:ASNFD_DEFAULT_SNET_NAME_US, $env:ASNFD_APPS_SNET_NAME_US)
    }
)

foreach ($RouteTable in $RouteTables) {
    $RouteTableName = $RouteTable.Name

    Write-Output "`nCreating route table ${RouteTableName} in $($RouteTable.Location)..."
    # https://learn.microsoft.com/cli/azure/network/route-table?view=azure-cli-latest#az-network-route-table-create
    az network route-table create `
        --name $RouteTableName `
        --resource-group $RouteTable.Rg `
        --location $RouteTable.Location

    Write-Output "`nAdding default route (0.0.0.0/0 -> firewall ${FirewallPrivateIpAddress}) to ${RouteTableName}..."
    # https://learn.microsoft.com/cli/azure/network/route-table/route?view=azure-cli-latest#az-network-route-table-route-create
    az network route-table route create `
        --name "route-to-firewall" `
        --resource-group $RouteTable.Rg `
        --route-table-name $RouteTableName `
        --address-prefix "0.0.0.0/0" `
        --next-hop-type "VirtualAppliance" `
        --next-hop-ip-address $FirewallPrivateIpAddress

    foreach ($SubnetName in $RouteTable.Subnets) {
        Write-Output "`nAssociating route table ${RouteTableName} with subnet ${SubnetName}..."
        # https://learn.microsoft.com/cli/azure/network/vnet/subnet?view=azure-cli-latest#az-network-vnet-subnet-update
        az network vnet subnet update `
            --name $SubnetName `
            --resource-group $RouteTable.Rg `
            --vnet-name $RouteTable.Vnet `
            --route-table $RouteTableName
    }
}

Write-Output "`nRouting configured. All egress traffic from the workload subnets is now forced through the firewall."
Write-Output "Note: the firewall denies all traffic until you add allow rules (e.g. allow GitHub.com) - see exercise 5."
