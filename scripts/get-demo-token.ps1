# Prints a demo JWT to stdout (for: $token = .\scripts\get-demo-token.ps1)
param([string]$BaseUrl = "https://localhost")

$ErrorActionPreference = "Stop"
$k = if ($BaseUrl.StartsWith("https")) { "-k" } else { "" }

$tokPath = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText(
        $tokPath,
        '{"username":"demo","password":"demo"}',
        (New-Object System.Text.UTF8Encoding $false)
    )
    $tokJson = curl.exe -s $k -X POST "$BaseUrl/auth/token" `
        -H "Content-Type: application/json" `
        --data-binary "@$tokPath"
    $token = ($tokJson | ConvertFrom-Json).access_token
    if (-not $token) { throw "No access_token in response: $tokJson" }
    Write-Output $token
}
finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $tokPath
}
