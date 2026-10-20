#requires -Version 5.1
<#
.SYNOPSIS
  Five-project portfolio showcase: one command, every stack proven live.

.DESCRIPTION
  Brings up each project (reusing already-healthy containers), runs a fast
  signature check against it, and prints a scorecard of numbers actually
  measured in THIS run:

    ScaleX      shorten -> 302 redirect, live latency percentiles (nginx -> API -> redis/postgres)
    QueueEase   OTP login -> join queue -> staff call-next -> done, EN/TA
    DeployHub   git sample -> built image -> live URL -> rollback switches traffic
    DocuMind AI register -> upload PDF -> question -> cited answer (+ GPU mode if up)
    StreamGuard stack health + service inventory (full e2e: its own demo script)

  Each project also ships a deeper standalone suite in <project>\scripts\demo.ps1
  (ScaleX includes a k6 load test, DocuMind a 50-question evaluation harness).

.PARAMETER Full
  After the fast checks, also run every project's complete demo suite in turn.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File demo.ps1
  powershell -ExecutionPolicy Bypass -File demo.ps1 -Full
#>
[CmdletBinding()]
param([switch]$Full)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$script:Rows = New-Object System.Collections.Generic.List[object]
$script:Fails = 0

function Head($t) { Write-Host ""; Write-Host ("=" * 70) -ForegroundColor DarkCyan; Write-Host "  $t" -ForegroundColor Cyan; Write-Host ("=" * 70) -ForegroundColor DarkCyan }
function Info($t) { Write-Host "  $t" -ForegroundColor DarkGray }
function Pass($project, $check, $measured) {
    $script:Rows.Add([pscustomobject]@{ Project = $project; Check = $check; Measured = $measured; State = "PASS" })
    Write-Host "  [PASS] $check -> $measured" -ForegroundColor Green
}
function Fail($project, $check, $measured) {
    $script:Fails++
    $script:Rows.Add([pscustomobject]@{ Project = $project; Check = $check; Measured = $measured; State = "FAIL" })
    Write-Host "  [FAIL] $check -> $measured" -ForegroundColor Red
}
function Check($project, $condition, $check, $measured) {
    if ($condition) { Pass $project $check $measured } else { Fail $project $check $measured }
}

function Invoke-Api {
    # Returns @{ Status; Json } and never throws on HTTP 4xx/5xx.
    param([string]$Method = "GET", [string]$Uri, $Body = $null, [string]$Token = $null, [string]$ContentType = "application/json")
    $headers = @{}
    if ($Token) { $headers["Authorization"] = "Bearer $Token" }
    $params = @{ Method = $Method; Uri = $Uri; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 60 }
    if ($null -ne $Body) {
        $params["ContentType"] = $ContentType
        $params["Body"] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 6 -Compress }
    }
    try {
        $r = Invoke-WebRequest @params
        return @{ Status = [int]$r.StatusCode; Json = $(try { $r.Content | ConvertFrom-Json } catch { $null }); Content = $r.Content; Headers = $r.Headers }
    } catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { return @{ Status = 0; Json = $null; Content = ""; Error = $_.Exception.Message } }
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $sr.ReadToEnd()
        return @{ Status = [int]$resp.StatusCode; Json = $(try { $body | ConvertFrom-Json } catch { $null }); Content = $body }
    }
}

function Wait-Ready {
    param([string]$Uri, [int]$TimeoutSec = 90, [scriptblock]$Predicate)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep -Seconds 3
        $r = Invoke-Api -Uri $Uri
        if ($r.Status -eq 200) {
            if (-not $Predicate) { return $true }
            if (& $Predicate $r) { return $true }
        }
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Invoke-Native {
    # PS 5.1 trap: with ErrorActionPreference=Stop, ANY stderr line from a
    # native command (docker compose warnings, pull progress) becomes a
    # terminating NativeCommandError. Run natives with Continue + merged output.
    param([string]$Exe, [object[]]$Arguments = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $Exe @Arguments 2>&1
        return @{ Output = @($out | ForEach-Object { "$_" }); ExitCode = $LASTEXITCODE }
    } finally { $ErrorActionPreference = $prev }
}

function Compose-Up {
    param([string]$Dir, [string[]]$Files = @())
    Push-Location $Dir
    try {
        $composeArgs = @("compose")
        foreach ($f in $Files) { $composeArgs += @("-f", $f) }
        $composeArgs += @("up", "-d")
        Invoke-Native "docker" $composeArgs | Out-Null
    } finally { Pop-Location }
}

Write-Host ""
Write-Host "  PORTFOLIO SHOWCASE - five projects, one machine" -ForegroundColor White
$dockerVer = (Invoke-Native "docker" @("version", "--format", "{{.Server.Version}}")).Output -join ""
Write-Host "  docker: $dockerVer | node: $(node --version 2>$null)" -ForegroundColor DarkGray

# ============================================================== 1. ScaleX
Head "1. ScaleX - load-tested URL shortener (nginx + 3 APIs + redis + postgres)"
$px = "http://localhost:8080"
Compose-Up "$root\scalex"
Check "ScaleX" (Wait-Ready "$px/healthz" 90) "stack healthy behind nginx" "$px/healthz"

$stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$short = Invoke-Api -Method Post -Uri "$px/api/shorten" -Body @{ url = "https://github.com/scalex/showcase-$stamp" }
Check "ScaleX" ($short.Status -eq 201 -and $short.Json.shortUrl) "POST /api/shorten" "201 -> $($short.Json.shortUrl)"

# Header checks use raw curl: PS 5.1's exception-response object returns empty
# headers on 302s even though the server sends them. Status/location are parsed
# via Select-String match groups — $Matches is unreliable after -match on arrays.
$h1 = curl.exe -s -D - -o NUL $short.Json.shortUrl
$code1 = 0
$stLine = $h1 | Select-String "^HTTP/\S+\s+(\d+)"
if ($stLine) { $code1 = [int]$stLine.Matches[0].Groups[1].Value }
$locLine = $h1 | Select-String "^Location: (.+)"
$loc = if ($locLine) { $locLine.Matches[0].Groups[1].Value.Trim() } else { "" }
Check "ScaleX" ($code1 -eq 302) "redirect" "302 -> $loc"
$h2 = curl.exe -s -D - -o NUL $short.Json.shortUrl
$warm = ""
$xcMatch = $h2 | Select-String "^X-Cache: (.+)"
if ($xcMatch) { $warm = $xcMatch.Matches[0].Groups[1].Value.Trim() }
Check "ScaleX" ($warm -eq "HIT") "redis cache on second hit" "X-Cache: $warm"

# 100 sequential redirects for a live latency figure (client-measured through nginx).
$times = New-Object System.Collections.Generic.List[double]
for ($i = 0; $i -lt 100; $i++) {
    $t0 = Get-Date
    try { Invoke-WebRequest -Uri $short.Json.shortUrl -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop | Out-Null } catch { }
    $times.Add(((Get-Date) - $t0).TotalMilliseconds)
}
$sorted = $times | Sort-Object
$p95 = $sorted[[int][Math]::Floor(0.95 * ($sorted.Count - 1))]
$mean = [Math]::Round(($times | Measure-Object -Average).Average, 2)
Check "ScaleX" ($p95 -lt 100) "100 redirects: mean / p95" "mean ${mean}ms p95 $([Math]::Round($p95,2))ms"
$stats = Invoke-Api -Uri "$px/api/stats/$($short.Json.code)"
Check "ScaleX" ($stats.Status -eq 200) "click stats recorded" "$($stats.Json.clicks) click(s)"

# ============================================================ 2. QueueEase
Head "2. QueueEase - smart clinic queue (EN/TA, OTP, socket.io)"
$pq = "http://localhost:3100"
Compose-Up "$root\queueease"
Check "QueueEase" (Wait-Ready "$pq/healthz/ready" 90 { param($r) $r.Json.db -eq "up" }) "app + postgres ready" "$pq/healthz/ready"

$doctors = (Invoke-Api -Uri "$pq/api/doctors").Json.doctors
$doctor = $doctors[0]
Check "QueueEase" ($doctors.Count -ge 3) "seeded doctors" "$($doctors.Count) doctors"

$phone = "98765$($stamp.ToString().Substring($stamp.ToString().Length - 5))"
$otp = Invoke-Api -Method Post -Uri "$pq/api/auth/otp" -Body @{ phone = $phone; lang = "en" }
$auth = Invoke-Api -Method Post -Uri "$pq/api/auth/verify" -Body @{ phone = $phone; otp = $otp.Json.devOtp; lang = "en" }
Check "QueueEase" ($auth.Json.token) "OTP login (dev OTP -> JWT)" "patient id $($auth.Json.patient.id)"

$join = Invoke-Api -Method Post -Uri "$pq/api/queue/join" -Token $auth.Json.token -Body @{ doctorId = $doctor.id }
Check "QueueEase" ($join.Json.tokenNo -ge 1) "joined queue" "token #$($join.Json.tokenNo), est wait $($join.Json.estimatedWaitMin) min"

$staff = Invoke-Api -Method Post -Uri "$pq/api/staff/login" -Body @{ pin = "1234" }
$next = Invoke-Api -Method Post -Uri "$pq/api/staff/next" -Token $staff.Json.token -Body @{ doctorId = $doctor.id }
Check "QueueEase" ($next.Json.called) "staff called next token" "#$($next.Json.called.tokenNo) ($($next.Json.called.patientName))"

$mine = Invoke-Api -Uri "$pq/api/queue/mine?doctorId=$($doctor.id)" -Token $auth.Json.token
Check "QueueEase" ($mine.Json.status -eq "serving") "patient sees live status" "status=$($mine.Json.status)"

$done = Invoke-Api -Method Post -Uri "$pq/api/staff/$($next.Json.called.visitId)/done" -Token $staff.Json.token -Body @{ doctorId = $doctor.id }
Check "QueueEase" ($done.Json.status -eq "done") "visit closed + notified" "status=$($done.Json.status)"
$ta = Invoke-Api -Uri "$pq/i18n/ta.json"
Check "QueueEase" ($ta.Json.'patient.yourToken') "Tamil dictionary" "$($ta.Json.'patient.yourToken')"

# ============================================================ 3. DeployHub
Head "3. DeployHub - PaaS: git sample -> isolated build -> live URL -> rollback"
$pd = "http://localhost:3001"
Compose-Up "$root\deployhub"
Check "DeployHub" (Wait-Ready "$pd/healthz/ready" 120) "api + worker + dind ready" "$pd/healthz/ready"

$slug = "showcase"
$mkBody = { param($s) (@{ repo = "sample:node-app"; slug = $s } | ConvertTo-Json) }
$d1 = Invoke-Api -Method Post -Uri "$pd/api/deployments" -Body (& $mkBody $slug)
Check "DeployHub" ($d1.Status -in @(200, 201, 202)) "queued deployment #1" "$($d1.Json.url)"

$deadline = (Get-Date).AddSeconds(120)
do {
    Start-Sleep -Seconds 3
    $row = (Invoke-Api -Uri "$pd/api/deployments/$slug").Json
    if ($row.deployments) { $row = $row.deployments[0] }
    $st = $row.status
} while ($st -in @("queued", "cloning", "building", "starting") -and (Get-Date) -lt $deadline)
Check "DeployHub" ($st -eq "running") "build #1 -> running" "buildMs=$($row.buildMs)"

$d2 = Invoke-Api -Method Post -Uri "$pd/api/deployments" -Body (& $mkBody $slug)
$deadline = (Get-Date).AddSeconds(120)
do {
    Start-Sleep -Seconds 3
    $row = (Invoke-Api -Uri "$pd/api/deployments/$slug").Json
    if ($row.deployments) { $row = $row.deployments[0] }
    $st = $row.status
} while ($st -in @("queued", "cloning", "building", "starting") -and (Get-Date) -lt $deadline)
Check "DeployHub" ($st -eq "running") "build #2 -> running" "buildMs=$($row.buildMs)"

$live = Invoke-Api -Uri "$pd/s/$slug"
Check "DeployHub" ($live.Status -eq 200) "reverse proxy serves the app" "GET /s/$slug -> 200"

$rb = Invoke-Api -Method Post -Uri "$pd/api/deployments/$slug/rollback"
Check "DeployHub" ($rb.Status -eq 202 -and $rb.Json.rollingBackTo) "rollback accepted" "rolling back to deployment #$($rb.Json.rollingBackTo)"
Start-Sleep -Seconds 8
$live2 = Invoke-Api -Uri "$pd/s/$slug"
Check "DeployHub" ($live2.Status -eq 200) "traffic still served after rollback" "GET /s/$slug -> 200"
$list = (Invoke-Api -Uri "$pd/api/deployments").Json.deployments | Where-Object { $_.slug -eq $slug }
$runningCount = @($list | Where-Object { $_.status -eq "running" }).Count
$superseded = @($list | Where-Object { $_.status -eq "stopped" }).Count
Check "DeployHub" ($runningCount -eq 1 -and $superseded -ge 1) "superseded version retired" "$runningCount running, $superseded stopped"

# ============================================================= 4. DocuMind
Head "4. DocuMind AI - offline RAG: upload PDF -> question -> cited answer"
$pm = "http://localhost:3200"
$gpuUp = $false
$gpuUp = [bool]((Invoke-Native "docker" @("ps", "--format", "{{.Names}}")).Output | Select-String "documind-gpu")
$files = if ($gpuUp) { @("-f", "docker-compose.yml", "-f", "docker-compose.gpu.yml") } else { @() }
Compose-Up "$root\documind" $files
Check "DocuMind" (Wait-Ready "$pm/readyz" 120) "app + postgres ready" "$pm/readyz"
$cfg = (Invoke-Api -Uri "$pm/api/config").Json
Check "DocuMind" ($cfg.answerMode -in @("gpu", "extractive", "openai")) "answer mode live" "answerMode=$($cfg.answerMode) embedding=$($cfg.embeddingProvider)"

Add-Type -AssemblyName System.Net.Http | Out-Null
function Upload-Doc([string]$Base, [string]$Token, [string]$FilePath) {
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(120)
    $content = New-Object System.Net.Http.MultipartFormDataContent
    $content.Add((New-Object System.Net.Http.StringContent("showcase")), "name")
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $fc = New-Object System.Net.Http.ByteArrayContent($bytes, 0, $bytes.Length)
    $fc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/octet-stream")
    $content.Add($fc, "files", [System.IO.Path]::GetFileName($FilePath))
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::new("POST"), "$Base/api/docs")
    $req.Content = $content
    $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $Token)
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $client.Dispose()
    return @{ Status = [int]$resp.StatusCode; Json = $(try { $body | ConvertFrom-Json } catch { $null }) }
}

$email = "showcase-$stamp@portfolio.local"
$reg = Invoke-Api -Method Post -Uri "$pm/api/register" -Body "{`"email`":`"$email`",`"password`":`"showcase-pw-123`"}"
$login = Invoke-Api -Method Post -Uri "$pm/api/login" -Body "{`"email`":`"$email`",`"password`":`"showcase-pw-123`"}"
Check "DocuMind" ($reg.Status -eq 201 -and $login.Json.token) "register + login" "JWT issued"
$dmToken = $login.Json.token

$pdf = Join-Path $root "documind\eval\docs\world-facts.pdf"
if (-not (Test-Path $pdf)) {
    Push-Location "$root\documind"
    try { Invoke-Native "docker" @("compose", "-f", "docker-compose.yml", "run", "--rm", "--no-deps", "app", "npm", "run", "generate-samples") | Out-Null } finally { Pop-Location }
}
$up = Upload-Doc $pm $dmToken $pdf
Check "DocuMind" ($up.Status -eq 201) "PDF upload + ingest" "$(@($up.Json.files)[0].name): $(@($up.Json.files)[0].pages) pages, $(@($up.Json.files)[0].chunks) chunks"

$ask = Invoke-Api -Method Post -Uri "$pm/api/chat" -Token $dmToken -Body (@{ setId = $up.Json.setId; question = "How tall is Mount Everest and where is it located?" } | ConvertTo-Json)
$cites = @($ask.Json.citations)
$citeStr = ($cites | Select-Object -First 2 | ForEach-Object { "[p.$($_.page)]" }) -join " "
Check "DocuMind" ($ask.Status -eq 200 -and $cites.Count -ge 1) "question -> cited answer" "$($ask.Json.latencyMs)ms, $($cites.Count) citation(s) $citeStr, mode=$($ask.Json.answerMode)"
$answerPreview = if ($ask.Json.answer) { $ask.Json.answer.Substring(0, [Math]::Min(90, $ask.Json.answer.Length)) } else { "" }
Info "answer: $answerPreview..."

# ========================================================== 5. StreamGuard
Head "5. StreamGuard - stream anomaly detection (RabbitMQ pipeline)"
$pg2 = "http://localhost:3300"
$sgDir = "$root\streamguard"
if (Test-Path "$sgDir\docker-compose.yml") {
    Compose-Up $sgDir
    $sgOk = Wait-Ready "$pg2/healthz" 120
    Check "StreamGuard" $sgOk "api health" "$pg2/healthz"
    if ($sgOk) {
        $sgReady = Invoke-Api -Uri "$pg2/healthz/ready"
        Check "StreamGuard" ($sgReady.Status -eq 200) "dependencies ready" "$(if ($sgReady.Json) { ($sgReady.Json | ConvertTo-Json -Compress) } else { 'ready' })"
    }
    $sgContainers = @(docker ps --format "{{.Names}}" | Select-String "streamguard")
    Info "services up: $($sgContainers.Count) ($($sgContainers -join ', '))"
} else {
    Info "streamguard/ not present yet - skipping"
}

# ============================================================= scorecard
Head "SCORECARD (measured in this run)"
$script:Rows | Format-Table -AutoSize | Out-String | Write-Host
$passed = @($script:Rows | Where-Object { $_.State -eq "PASS" }).Count
$total = $script:Rows.Count
Write-Host "  $passed/$total checks passed" -ForegroundColor $(if ($script:Fails -eq 0) { "Green" } else { "Red" })
Write-Host "  Headline results from full recorded runs:" -ForegroundColor DarkGray
Write-Host "    ScaleX     1,000 req/s sustained, p95 2.25 ms, 0% errors (k6, docs/LOAD_TEST.md)" -ForegroundColor DarkGray
Write-Host "    QueueEase  24/24 e2e checks (scripts/demo.ps1)" -ForegroundColor DarkGray
Write-Host "    DeployHub  build-to-running ~1.2-1.8 s, rollback switches traffic (docs/ARCHITECTURE.md)" -ForegroundColor DarkGray
Write-Host "    DocuMind   Hit@3 100%, cited answers (docs/EVALUATION.md / EVALUATION_GPU.md)" -ForegroundColor DarkGray

if ($Full) {
    foreach ($p in @("scalex", "queueease", "deployhub", "documind", "streamguard")) {
        $demo = Join-Path $root "$p\scripts\demo.ps1"
        if (Test-Path $demo) {
            Head "FULL SUITE: $p\scripts\demo.ps1"
            $child = Invoke-Native "powershell" @("-ExecutionPolicy", "Bypass", "-File", $demo)
            $child.Output | ForEach-Object { Write-Host "  $_" }
            if ($child.ExitCode -ne 0) { $script:Fails++; Write-Host "  [FAIL] $p full suite exit code $($child.ExitCode)" -ForegroundColor Red }
        }
    }
}

Write-Host ""
if ($script:Fails -eq 0) {
    Write-Host "  RESULT: PORTFOLIO DEMO PASS" -ForegroundColor Green
    exit 0
} else {
    Write-Host "  RESULT: $script:Fails check(s) failed" -ForegroundColor Red
    exit 1
}
