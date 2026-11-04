param(
    [string]$RepoRoot = "C:\vitrivr\vitrivr-engine"
)

$ErrorActionPreference = "Stop"
Set-Location $RepoRoot

function Section([string]$Text) {
    Write-Host ""
    Write-Host "=== $Text ==="
}

Section "Start fresh full FES for vit_gpt2"
$existing = docker ps -a --format "{{.Names}}" | Where-Object { $_ -eq "fes-vitgpt2" }
if ($existing) {
    docker rm -f fes-vitgpt2 | Out-Null
}

docker pull faberf/featureextractionserver:full-latest
if ($LASTEXITCODE -ne 0) { throw "Could not pull full-latest FES image." }

docker volume create fes-vitgpt2-cache | Out-Null
docker run -d --name fes-vitgpt2 -p 5003:8888 -v fes-vitgpt2-cache:/root/.cache -e LOG_LEVEL=INFO faberf/featureextractionserver:full-latest | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not start fes-vitgpt2." }

$ready = $false
$tasksText = ""
for ($i = 0; $i -lt 120; $i++) {
    try {
        $tasksText = (& curl.exe -s http://127.0.0.1:5003/api/tasks) -join ""
        if ($tasksText -match "image-captioning") {
            $ready = $true
            break
        }
    } catch {}
    Start-Sleep -Seconds 2
}

if (-not $ready) {
    Section "Available FES tasks"
    Write-Host $tasksText
    Section "FES log"
    docker logs --tail 120 fes-vitgpt2
    throw "Fresh full FES does not expose image-captioning."
}

Section "Build current engine"
.\gradlew.bat :vitrivr-engine-server:installDist --rerun-tasks
if ($LASTEXITCODE -ne 0) { throw "Engine build failed." }

Section "Stop old engine"
$listener = Get-NetTCPConnection -LocalPort 7070 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
    Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

Section "Clear previous test data"
docker exec vitrivr-postgres psql -U postgres -d postgres -c "TRUNCATE TABLE example.retrievable CASCADE;"

Section "Start engine"
$engineBat = Join-Path $RepoRoot "vitrivr-engine-server\build\install\vitrivr-engine-server\bin\vitrivr-engine-server.bat"
$schema = Join-Path $RepoRoot "example-configs\docker\schema.json"
$logDir = Join-Path $RepoRoot "build\vitgpt2-test"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stdout = Join-Path $logDir "engine.out.log"
$stderr = Join-Path $logDir "engine.err.log"
Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue

Start-Process -FilePath $engineBat -ArgumentList $schema -WorkingDirectory $RepoRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr | Out-Null

$engineReady = $false
for ($i = 0; $i -lt 90; $i++) {
    try {
        $schemaList = Invoke-RestMethod -Uri "http://127.0.0.1:7070/api/schema/list" -TimeoutSec 2
        if ($schemaList.schemas -contains "example") {
            $engineReady = $true
            break
        }
    } catch {}
    Start-Sleep -Seconds 1
}
if (-not $engineReady) { throw "Engine did not become ready." }

Section "Run architecture_02 ingestion"
$response = (& curl.exe -s -X POST -F "pipelineName=image" http://127.0.0.1:7070/api/example/index) -join ""
Write-Host "Engine response: $response"

for ($i = 0; $i -lt 180; $i++) {
    $countRaw = (& docker exec vitrivr-postgres psql -U postgres -d postgres -tAc "SELECT COUNT(*) FROM example.descriptor_tags;") -join ""
    $count = 0
    [void][int]::TryParse($countRaw.Trim(), [ref]$count)
    if ($count -gt 0) { break }

    if (($i % 10) -eq 0) {
        Write-Host ("Still processing architecture_02... " + $i + "s")
    }

    $failure = Get-Content $stdout -ErrorAction SilentlyContinue |
        Select-String -Pattern "All configured captioning models failed|Error during batched extraction" |
        Select-Object -Last 1
    if ($failure) {
        Write-Host $failure.Line
        break
    }

    Start-Sleep -Seconds 1
}

Section "Image actually ingested"
docker exec vitrivr-postgres psql -U postgres -d postgres -c "SELECT retrievableid, path, size FROM example.descriptor_file;"

Section "Top tags"
docker exec vitrivr-postgres psql -U postgres -d postgres -c "SELECT label, confidence FROM example.descriptor_tags ORDER BY confidence DESC LIMIT 5;"

Section "Caption and candidates"
Get-Content $stdout -ErrorAction SilentlyContinue |
    Select-String -Pattern "caption model attempt|Captioning response|Dynamic candidate tags|failed during dynamic candidate generation|All configured captioning models failed" |
    Select-Object -Last 50 |
    ForEach-Object { Write-Host $_.Line }

$countRaw = (& docker exec vitrivr-postgres psql -U postgres -d postgres -tAc "SELECT COUNT(*) FROM example.descriptor_tags;") -join ""
$count = 0
[void][int]::TryParse($countRaw.Trim(), [ref]$count)

if ($count -eq 0) {
    Section "vit_gpt2 diagnostics"
    docker logs --tail 120 fes-vitgpt2
}
