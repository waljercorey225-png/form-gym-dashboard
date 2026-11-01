$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$configPath = Join-Path $root 'cloud-config.js'
$config = Get-Content -LiteralPath $configPath -Raw
$url = [regex]::Match($config, 'url\s*:\s*"(https://[^\"]+)"')
$key = [regex]::Match($config, 'anonKey\s*:\s*"([^\"]+)"')

if (-not $url.Success -or -not $key.Success -or $key.Groups[1].Value -match '^YOUR_') {
    throw 'Set the Supabase project URL and public anon/publishable key in cloud-config.js before building.'
}

$output = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $output -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'index.html') -Destination (Join-Path $output 'index.html') -Force
Copy-Item -LiteralPath $configPath -Destination (Join-Path $output 'cloud-config.js') -Force

$files = @(Get-ChildItem -LiteralPath $output -File | Select-Object -ExpandProperty Name | Sort-Object)
if (($files -join ',') -ne 'cloud-config.js,index.html') {
    throw 'The deploy output contains unexpected files. Only index.html and cloud-config.js may be uploaded.'
}
Write-Host "Static deploy bundle ready: $output"
Write-Host 'Upload only the dist folder. It contains no local CSV data or server scripts.'
