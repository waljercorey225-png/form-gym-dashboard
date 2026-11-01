$ErrorActionPreference = 'Stop'
$appUrl = 'http://localhost:4173/'
$healthUrl = 'http://localhost:4173/api/health'
$serverScript = Join-Path $PSScriptRoot 'local-server.ps1'
$ready = $false

try {
    $ready = (Invoke-RestMethod -Uri $healthUrl -TimeoutSec 2).status -eq 'ok'
} catch {}

if (-not $ready) {
    $serverArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "' + $serverScript + '"'
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $serverArguments -WorkingDirectory $PSScriptRoot -WindowStyle Minimized
    $deadline = (Get-Date).AddSeconds(20)
    while (-not $ready -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        try {
            $ready = (Invoke-RestMethod -Uri $healthUrl -TimeoutSec 1).status -eq 'ok'
        } catch {}
    }
}

if (-not $ready) {
    throw 'The local app server did not start. Check whether port 4173 is already in use.'
}

Start-Process $appUrl
