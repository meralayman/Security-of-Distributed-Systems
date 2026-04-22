$ErrorActionPreference = "Stop"
$base = if ($env:BASE_URL) { $env:BASE_URL } else { "https://localhost" }
$k = if ($base.StartsWith("https")) { "-k" } else { "" }

Write-Host "Health checks (expect 200, X-API-Instance rotates)..."
1..9 | ForEach-Object {
  curl.exe -s $k -D - "$base/health" -o $null | Select-String "HTTP/|x-api-instance"
}

Write-Host "`nToken..."
$tokJson = curl.exe -s $k -X POST "$base/auth/token" `
  -H "Content-Type: application/json" `
  -d '{"username":"demo","password":"demo"}'
$token = ($tokJson | ConvertFrom-Json).access_token
if (-not $token) { throw "No token: $tokJson" }

Write-Host "`nTask..."
curl.exe -s $k "$base/task" `
  -H "Authorization: Bearer $token" `
  -H "Content-Type: application/json" `
  -d '{"payload":{"from":"smoke-test"}}'

Write-Host "`nUnauthorized (expect 401)..."
curl.exe -s $k -w "`nHTTP %{http_code}`n" "$base/task" -H "Content-Type: application/json" -d '{"payload":{}}'
