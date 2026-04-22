<#
.SYNOPSIS
  Assignment §11 functional checks — run from repo root with stack up:
    docker compose up --build -d

.EXAMPLE
  .\scripts\functional-tests.ps1
  $env:BASE_URL = "http://localhost"; .\scripts\functional-tests.ps1   # HTTP-only compose
#>
[CmdletBinding()]
param(
    [string] $BaseUrl = $(if ($env:BASE_URL) { $env:BASE_URL } else { "https://localhost" }),
    [string] $PostgresUser = "app",
    [string] $PostgresDb = "auditdb",
    [string] $RmqUser = "guest",
    [string] $RmqPass = "guest",
    [int] $ProcessedWaitSec = 45
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

# Extra curl args for self-signed HTTPS (omit entirely for plain HTTP — never pass "")
function Get-TlsCurlArgs {
    if ($BaseUrl.StartsWith("https")) { return @("-k") }
    return @()
}

# Never use `$tls + @(...)` in PowerShell — can stringify/collide args; always append via ArrayList.
# Trailing `,$list` prevents PowerShell from unwrapping the ArrayList to its first element on return.
function New-CurlArgsFromTls {
    $a = New-Object System.Collections.ArrayList
    foreach ($x in Get-TlsCurlArgs) { [void]$a.Add($x) }
    , $a
}

function Test-Pass([string]$Name) { Write-Host "[PASS] $Name" -ForegroundColor Green }
function Test-Fail([string]$Name, [string]$Detail) {
    Write-Host "[FAIL] $Name" -ForegroundColor Red
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkRed }
}

$failed = 0
function Bump-Fail { $script:failed++ }

function Invoke-CurlBodyAndCode {
    param([Parameter(Mandatory)][string[]]$CurlArgs)
    $out = [System.IO.Path]::GetTempFileName()
    try {
        # Build one flat argv list — avoids PS5 splat quirks when merging TLS + POST args
        $argv = New-Object System.Collections.ArrayList
        foreach ($a in @($CurlArgs)) { [void]$argv.Add($a) }
        [void]$argv.AddRange(@("-s", "-S", "-o", $out, "-w", "%{http_code}"))
        $flat = [string[]]$argv.ToArray()
        $codeTxt = & curl.exe @flat
        if ($LASTEXITCODE -ne 0) { throw "curl failed with exit $LASTEXITCODE" }
        $code = [int]$codeTxt.Trim()
        $body = Get-Content -Raw $out -ErrorAction SilentlyContinue
        return @{ StatusCode = $code; Body = $body }
    }
    finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $out
    }
}

Write-Host "`n=== [11] Functional tests (BASE_URL=$BaseUrl, repo=$RepoRoot) ===`n" -ForegroundColor Cyan

Write-Host "--- 0) Worker / broker readiness ---"
$consumerOk = $false
for ($w = 0; $w -lt 90; $w++) {
    $psW = docker compose ps worker 2>$null | Out-String
    if ($psW -match 'Up|running') {
        $pair = "${RmqUser}:${RmqPass}"
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
        $raw = curl.exe -s -S -H "Authorization: Basic $b64" "http://localhost:15672/api/queues" 2>$null
        try {
            $arr = $raw | ConvertFrom-Json
            if (-not ($arr -is [array])) { $arr = @($arr) }
            $hit = @($arr | Where-Object { $_.name -eq "tasks_queue" -or $_.name -eq "tasks" }) | Select-Object -First 1
            if ($hit -and [int]$hit.consumers -ge 1) {
                $consumerOk = $true
                Test-Pass "Worker container up; RabbitMQ consumer on queue '$($hit.name)'=$($hit.consumers)"
                break
            }
        }
        catch { }
    }
    Start-Sleep -Milliseconds 800
}
if (-not $consumerOk) {
    Write-Host "[WARN] Could not confirm a worker consumer on tasks_queue/tasks within 90s." -ForegroundColor Yellow
    Write-Host "       Steps 6-7 may fail. Run: docker compose logs worker --tail 80" -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# 1) Normal request works
# -----------------------------------------------------------------------------
Write-Host "--- 1) Normal request works ---"
$testRequestId = $null
try {
    $tokPath = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tokPath, '{"username":"demo","password":"demo"}', (New-Object System.Text.UTF8Encoding $false))
    $tokBuf = New-CurlArgsFromTls
    [void]$tokBuf.AddRange(@("-s", "-S", "-X", "POST", "$BaseUrl/auth/token", "-H", "Content-Type: application/json", "--data-binary", "@$tokPath"))
    $tokJson = & curl.exe @([string[]]$tokBuf.ToArray())
    Remove-Item -Force $tokPath
    $token = ($tokJson | ConvertFrom-Json).access_token
    if (-not $token) { throw "No token (is Nginx/API up at $BaseUrl?). Response: '$tokJson'" }

    $taskPath = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($taskPath, '{"payload":{"ft":"functional-tests"}}', (New-Object System.Text.UTF8Encoding $false))
    $invokeArgs = New-CurlArgsFromTls
    [void]$invokeArgs.AddRange(@("-X", "POST", "$BaseUrl/task", "-H", "Authorization: Bearer $token", "-H", "Content-Type: application/json", "--data-binary", "@$taskPath"))
    $r = Invoke-CurlBodyAndCode ([string[]]$invokeArgs.ToArray())
    Remove-Item -Force $taskPath

    $bodyOnly = $r.Body -replace '\s+$', ''
    $j = $bodyOnly | ConvertFrom-Json
    $ridOut = $j.requestId
    if (-not $ridOut) { $ridOut = $j.request_id }
    $handled = $j.handledBy
    if (-not $handled) { $handled = $j.instance }
    if ($r.StatusCode -eq 200 -and $j.status -eq "queued" -and $ridOut -and $handled) {
        Test-Pass "POST /task returns 200 + queued + request id + handler name"
        $testRequestId = $ridOut
    }
    else {
        Test-Fail "POST /task normal path" "status=$($r.StatusCode) body=$bodyOnly"
        Bump-Fail
    }
}
catch {
    Test-Fail "Normal request" "$_"
    Bump-Fail
}

# -----------------------------------------------------------------------------
# 2) Unauthorized -> 401 (before load/rate tests so limit_req bucket is still fresh)
# -----------------------------------------------------------------------------
Write-Host "`n--- 2) Unauthorized (401) ---"
try {
    $badPath = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($badPath, '{"payload":{}}', (New-Object System.Text.UTF8Encoding $false))
    $invokeBad = New-CurlArgsFromTls
    [void]$invokeBad.AddRange(@("-X", "POST", "$BaseUrl/task", "-H", "Content-Type: application/json", "--data-binary", "@$badPath"))
    $r = Invoke-CurlBodyAndCode ([string[]]$invokeBad.ToArray())
    Remove-Item -Force $badPath
    if ($r.StatusCode -eq 401) {
        Test-Pass "POST /task without JWT returns 401"
    }
    else {
        Test-Fail "Unauthorized" "Expected 401; got $($r.StatusCode)"
        Bump-Fail
    }
}
catch {
    Test-Fail "Unauthorized" "$_"
    Bump-Fail
}

# -----------------------------------------------------------------------------
# 3) Load balancing distributes requests
# -----------------------------------------------------------------------------
Write-Host "`n--- 3) Load balancing ---"
try {
    $seen = [ordered]@{}
    1..36 | ForEach-Object {
        $hdrPath = [System.IO.Path]::GetTempFileName()
        $hc = New-CurlArgsFromTls
        [void]$hc.AddRange(@("-s", "-S", "-D", $hdrPath, "-o", "NUL", "$BaseUrl/health"))
        $null = & curl.exe @([string[]]$hc.ToArray())
        $hdr = Get-Content -Raw $hdrPath -ErrorAction SilentlyContinue
        Remove-Item -Force -ErrorAction SilentlyContinue $hdrPath
        if ($hdr -match '(?im)^x-api-instance:\s*(\S+)') {
            $seen[$Matches[1].Trim()] = $true
        }
    }
    $n = $seen.Keys.Count
    if ($n -ge 2) {
        Test-Pass "Distinct API instances: $n ($([string]::Join(', ', @($seen.Keys))))"
    }
    else {
        Test-Fail "Load balancing" "Expected >= 2 distinct X-API-Instance; got $n"
        Bump-Fail
    }
}
catch {
    Test-Fail "Load balancing" "$_"
    Bump-Fail
}

# -----------------------------------------------------------------------------
# 4) Rate limiting -> 429
# -----------------------------------------------------------------------------
Write-Host "`n--- 4) Rate limiting (429) ---"
try {
    $codes = [System.Collections.ArrayList]::new()

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $useHttps = $BaseUrl.StartsWith("https")
        $codesList = 1..130 | ForEach-Object -Parallel {
            $curl = New-Object System.Collections.ArrayList
            if ($using:useHttps) { [void]$curl.Add("-k") }
            [void]$curl.AddRange(@("-s", "-S", "-o", "NUL", "-w", "%{http_code}", "$using:BaseUrl/health"))
            $code = & curl.exe @([string[]]$curl.ToArray())
            [int][string]$code.Trim()
        } -ThrottleLimit 90
        foreach ($c in $codesList) { [void]$codes.Add($c) }
    }
    else {
        $sb = {
            param($u, [string[]]$tlsA)
            $curl = New-Object System.Collections.ArrayList
            foreach ($x in $tlsA) { [void]$curl.Add($x) }
            [void]$curl.AddRange(@("-s", "-S", "-o", "NUL", "-w", "%{http_code}", "$u/health"))
            $code = & curl.exe @([string[]]$curl.ToArray())
            [int][string]$code.Trim()
        }
        $tlsForJobs = New-CurlArgsFromTls
        $tlsArr = [string[]]$tlsForJobs.ToArray()
        $jobs = 1..55 | ForEach-Object { Start-Job -ScriptBlock $sb -ArgumentList $BaseUrl, $tlsArr }
        $jobs | Wait-Job | ForEach-Object {
            [void]$codes.Add([int](Receive-Job $_))
            Remove-Job $_
        }
    }

    $n429 = ($codes | Where-Object { $_ -eq 429 }).Count
    if ($n429 -ge 1) {
        Test-Pass "At least one 429 under burst ($n429 of $($codes.Count) responses)"
    }
    else {
        $dist = ($codes | Group-Object | ForEach-Object { "$($_.Name):$($_.Count)" }) -join ', '
        Test-Fail "Rate limit" "No 429 in $($codes.Count) rapid /health calls ($dist)"
        Bump-Fail
    }
}
catch {
    Test-Fail "Rate limiting" "$_"
    Bump-Fail
}

# -----------------------------------------------------------------------------
# 5) RabbitMQ queue + consumer (messages route through broker)
# -----------------------------------------------------------------------------
Write-Host "`n--- 5) RabbitMQ ---"
try {
    $mgmtPair = "${RmqUser}:${RmqPass}"
    $queuesJson = curl.exe -s -S -u $mgmtPair "http://localhost:15672/api/queues"
    $queuesArr = @()
    try {
        $queuesArr = $queuesJson | ConvertFrom-Json
        if (-not ($queuesArr -is [array])) { $queuesArr = @($queuesArr) }
    }
    catch { }

    # Prefer assignment name tasks_queue; accept legacy short name tasks if present (align TASK_QUEUE in compose)
    $entry = @($queuesArr | Where-Object { $_.name -eq "tasks_queue" })[0]
    if (-not $entry) { $entry = @($queuesArr | Where-Object { $_.name -eq "tasks" })[0] }
    $consumers = if ($entry) { [int]$entry.consumers } else { -1 }
    $qnm = if ($entry) { $entry.name } else { "" }

    if ($entry -and $consumers -ge 1) {
        Test-Pass "Broker queue '$qnm' visible; worker consumers=$consumers"
    }
    elseif ($entry) {
        Test-Pass "Broker queue '$qnm' exists (consumers=$consumers; broker flow verified in step 6)"
    }
    else {
        Test-Fail "RabbitMQ" "No tasks_queue (or legacy tasks) in management API. mgmt:`n$queuesJson"
        Bump-Fail
    }
}
catch {
    Test-Fail "RabbitMQ" "$_"
    Bump-Fail
}

# -----------------------------------------------------------------------------
# 6) Worker processes tasks + 7) Logs in database
# -----------------------------------------------------------------------------
Write-Host "`n--- 6-7) Worker + database ---"
if ($testRequestId) {
    $rid = $testRequestId
    $processed = $false
    foreach ($i in 1..$ProcessedWaitSec) {
        Start-Sleep -Seconds 1
        $cnt = docker compose exec -T postgres psql -U $PostgresUser -d $PostgresDb -t -A -c "SELECT COUNT(*) FROM request_states WHERE request_id = '$rid'::uuid AND state = 'PROCESSED';" 2>$null
        $trim = ($cnt | Out-String).Trim()
        if ($trim -eq "1") {
            $processed = $true
            break
        }
    }
    if ($processed) {
        Test-Pass "Worker wrote PROCESSED for request_id=$rid"
    }
    else {
        Test-Fail "Worker processing" "No PROCESSED within ${ProcessedWaitSec}s for $rid"
        Write-Host "       Hint: docker compose ps worker   # must be Up" -ForegroundColor DarkYellow
        Write-Host "       Hint: docker compose logs worker --tail 80" -ForegroundColor DarkYellow
        docker compose logs worker --tail 40 2>$null
        Bump-Fail
    }

    try {
        $ac = docker compose exec -T postgres psql -U $PostgresUser -d $PostgresDb -t -A -c "SELECT COUNT(*) FROM audit_logs WHERE request_id = '$rid'::uuid;" 2>$null
        $acn = [int](($ac | Out-String).Trim())
        if ($acn -ge 4) {
            Test-Pass "audit_logs contains $acn rows for this request_id"
        }
        else {
            Test-Fail "audit_logs" "Only $acn rows for $rid"
            Bump-Fail
        }
    }
    catch {
        Test-Fail "audit_logs query" "$_"
        Bump-Fail
    }
}
else {
    Test-Fail "Worker + DB checks" "Skipped (no requestId from step 1)"
    Bump-Fail
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "=== All [11] functional tests passed ===" -ForegroundColor Green
    exit 0
}
Write-Host "=== Failed: $failed section(s) ===" -ForegroundColor Red
exit 1
