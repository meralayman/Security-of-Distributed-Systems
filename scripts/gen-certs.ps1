$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$certs = Join-Path $root "nginx\certs"
New-Item -ItemType Directory -Force -Path $certs | Out-Null
$key = Join-Path $certs "key.pem"
$cert = Join-Path $certs "cert.pem"
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 `
  -keyout $key -out $cert `
  -subj "/CN=localhost"
Write-Host "Wrote $cert and $key. Mount these in nginx if you replace the baked-in image certs."
