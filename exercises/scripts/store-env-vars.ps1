# Store-EnvVars.ps1

# Capture all current environment variables
$EnvVars = Get-ChildItem Env: | ForEach-Object {
    [PSCustomObject]@{ Name = $_.Name; Value = $_.Value }
}

# Convert the environment variables to a hashtable
$EnvVarsHashtable = @{}
foreach ($envVar in $EnvVars) {
    $EnvVarsHashtable[$envVar.Name] = $envVar.Value
}

# Check if the env-vars.json file exists
if (Test-Path -Path "env.json") {
    # Load existing environment variables from the file
    $existingEnvVars = Get-Content -Raw -Path "env.json" | ConvertFrom-Json
    # Merge new environment variables with existing ones
    $mergedEnvVars = [ordered]@{}
    $existingEnvVars.PSObject.Properties.Name | ForEach-Object { $mergedEnvVars[$_] = $existingEnvVars.$_ }
    $EnvVarsHashtable.Keys | ForEach-Object { $mergedEnvVars[$_] = $EnvVarsHashtable[$_] }
} else {
    $mergedEnvVars = $EnvVarsHashtable
}

# Write merged environment variables to the file
$mergedEnvVars | ConvertTo-Json | Out-File -FilePath "env.json"

Write-Output "`nEnvironment variables stored in env.json"