# Invoke-RestMethod against the demo HTTPS cert.
# - PS 7+ (`pwsh`): uses -SkipCertificateCheck
# - Windows PowerShell 5.1: uses legacy ICertificatePolicy bypass (ignored by PS7+ for this cmdlet)
param([string]$BaseUrl = "https://localhost")

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -ge 6) {
    $token = (Invoke-RestMethod -Uri "$BaseUrl/auth/token" -Method Post -ContentType "application/json" -Body '{"username":"demo","password":"demo"}' -SkipCertificateCheck).access_token
    Invoke-RestMethod -Uri "$BaseUrl/task" -Method Post -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json" -Body '{"payload":{"hello":"world"}}' -SkipCertificateCheck
    return
}

Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) { return true; }
}
"@

[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$token = (Invoke-RestMethod -Uri "$BaseUrl/auth/token" -Method Post -ContentType "application/json" -Body '{"username":"demo","password":"demo"}').access_token
Invoke-RestMethod -Uri "$BaseUrl/task" -Method Post -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json" -Body '{"payload":{"hello":"world"}}'
