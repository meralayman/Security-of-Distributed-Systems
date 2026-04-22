# Posts /task with a JSON body that survives Windows PowerShell + curl.exe argument quirks.
# Usage: .\scripts\post-task.ps1 [-BaseUrl https://localhost] [-Token $token]
# If -Token is omitted, obtains demo token first (requires curl.exe).

param(
    [string]$BaseUrl = "https://localhost",
    [string]$Token = ""
)

$ErrorActionPreference = "Stop"
$k = if ($BaseUrl.StartsWith("https")) { "-k" } else { "" }

if (-not $Token) {
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
        $Token = ($tokJson | ConvertFrom-Json).access_token
        if (-not $Token) { throw "No access_token in response: $tokJson" }
    }
    finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $tokPath
    }
}

$bodyPath = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText(
        $bodyPath,
        '{"payload":{"hello":"world"}}',
        (New-Object System.Text.UTF8Encoding $false)
    )
    curl.exe -s $k "$BaseUrl/task" `
        -H "Authorization: Bearer $Token" `
        -H "Content-Type: application/json" `
        --data-binary "@$bodyPath"
    Write-Host ""
}
finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $bodyPath
}

Write-Host "Note: this script does not set `$token in your session. For manual curl, run:" -ForegroundColor DarkGray
Write-Host '  $token = .\scripts\get-demo-token.ps1' -ForegroundColor DarkGray
Write-Host "then post the body with --data-binary @`"<temp-file>`" (see README)." -ForegroundColor DarkGray
