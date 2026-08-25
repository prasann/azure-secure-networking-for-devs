#!/usr/bin/env pwsh

param(
    [Parameter(Mandatory=$True)][string]$TeamName,
    [Parameter(Mandatory=$True)][string]$Environment,
    [Parameter(Mandatory=$True)][string]$ResourceGroupName,
    [Parameter(Mandatory=$True)][string]$Location,
    [Parameter(Mandatory=$True)][string]$JumpboxAdminUsername,
    [Parameter(Mandatory=$True)][string]$JumpboxAdminPassword,
    [Parameter(Mandatory=$True)][string]$VnetName,
    [Parameter(Mandatory=$True)][string]$SubnetName
)

$JumpboxNsgName = $env:ASNFD_JUMPBOX_NSG_NAME
$JumpboxNicName = "nic-vm-${TeamName}-${Environment}-hub"
$JumpboxVmName = "vm${TeamName}hub"  # Max 15 characters for Windows machines
$JumpboxOsDiskName = "vmdisk-${TeamName}-${Environment}-hub"

# To list available Windows 11 images/SKUs, run: "az vm image list --publisher MicrosoftWindowsDesktop --offer windows-11 --all --output table"
# Use ":latest" for the version so the newest patched image is always selected. Pinned build numbers get delisted over time and break VM creation.
# NOTE: Windows 11 (client) images require a subscription eligible for Windows client in Azure (e.g. Visual Studio / MSDN, or Enterprise dev/test).
#       If your subscription is not eligible, switch to a Windows Server image, e.g. "MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest".
$JumpboxVmImage = "MicrosoftWindowsDesktop:windows-11:win11-24h2-pro:latest" # URN format for '--image': "Publisher:Offer:Sku:Version"

Write-Output "`nCreating network security group (NSG) for jumpbox..."
# https://learn.microsoft.com/cli/azure/network/nsg?view=azure-cli-latest#az-network-nsg-create()

az network nsg create `
    --name $JumpboxNsgName `
    --resource-group $ResourceGroupName `
    --location $Location `
    --no-wait false

Write-Output "`nCreating network interface (NIC) for jumpbox..."
# https://learn.microsoft.com/cli/azure/network/nic?view=azure-cli-latest#az-network-nic-create()

az network nic create `
    --name $JumpboxNicName `
    --resource-group $ResourceGroupName `
    --location $Location `
    --vnet-name $VnetName `
    --subnet $SubnetName `
    --network-security-group $JumpboxNsgName

Write-Output "`nCreating jumpbox virtual machine..."
# https://learn.microsoft.com/cli/azure/vm?view=azure-cli-latest#az-vm-create()

az vm create `
    --name $JumpboxVmName `
    --resource-group $ResourceGroupName `
    --location $Location `
    --image $JumpboxVmImage `
    --admin-username $JumpboxAdminUsername `
    --admin-password $JumpboxAdminPassword `
    --nics $JumpboxNicName `
    --os-disk-name $JumpboxOsDiskName
