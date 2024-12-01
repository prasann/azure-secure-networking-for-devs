# Load-EnvVars.ps1

# Check if the env-vars.json file exists
if (Test-Path -Path "env.json") {
    # Load environment variables from the file
    $envVars = Get-Content -Raw -Path "env.json" | ConvertFrom-Json

    # Set environment variables
    foreach ($key in $envVars.PSObject.Properties.Name) {
        $env:$key = $envVars.$key
    }

    Write-Output "`nEnvironment variables loaded from env.json"
} else {
    Write-Error "env-vars.json file not found"
}