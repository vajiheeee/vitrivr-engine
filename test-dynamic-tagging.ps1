param(
    [string]$RepoRoot = "C:\vitrivr\vitrivr-engine"
)

$ErrorActionPreference = "Stop"
Set-Location $RepoRoot

function Section([string]$Text) {
    Write-Host ""
    Write-Host "=== $Text ==="
}

function Get-DockerLogs([string]$Name, [int]$Tail = 120) {
    & cmd.exe /d /c "docker logs --tail $Tail $Name 2>&1"
}

function Require-Container([string]$Name) {
    $exists = docker ps -a --format "{{.Names}}" | Where-Object { $_ -eq $Name }
    if (-not $exists) {
        throw "Required Docker container '$Name' does not exist."
    }

    $running = docker inspect -f "{{.State.Running}}" $Name 2>$null
    if ($running -ne "true") {
        docker start $Name | Out-Null
    }
}

Section "Sync team/image"
git fetch origin
git switch team/image
git pull --ff-only origin team/image

Section "Build vitrivr-engine"
& .\gradlew.bat :vitrivr-engine-server:installDist --rerun-tasks
if ($LASTEXITCODE -ne 0) {
    throw "Gradle build failed."
}

Section "Check Docker services"
Require-Container "vitrivr-postgres"
Require-Container "fes-openclip"
Require-Container "fes-caption"

$captionTasks = (& curl.exe -s http://127.0.0.1:5001/api/tasks) -join ""
if ($captionTasks -notmatch "conditional-image-captioning") {
    throw "fes-caption does not expose conditional-image-captioning."
}

$openClipTasks = (& curl.exe -s http://127.0.0.1:5000/api/tasks) -join ""
if ($openClipTasks -notmatch "zero-shot-image-classification") {
    throw "fes-openclip does not expose zero-shot-image-classification."
}

Section "Stop old engine on port 7070"
$listener = Get-NetTCPConnection -LocalPort 7070 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
    Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

Section "Clear previous test data"
docker exec vitrivr-postgres psql -U postgres -d postgres -c "TRUNCATE TABLE example.retrievable CASCADE;"
if ($LASTEXITCODE -ne 0) {
    throw "Could not clear the test data."
}

Section "Start freshly built engine"
$engineBat = Join-Path $RepoRoot "vitrivr-engine-server\build\install\vitrivr-engine-server\bin\vitrivr-engine-server.bat"
$schema = Join-Path $RepoRoot "example-configs\docker\schema.json"
$logDir = Join-Path $RepoRoot "build\dynamic-tagging-test"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stdout = Join-Path $logDir "engine.out.log"
$stderr = Join-Path $logDir "engine.err.log"

Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue

$engine = Start-Process -FilePath $engineBat -ArgumentList $schema -WorkingDirectory $RepoRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru

$ready = $false
for ($i = 0; $i -lt 90; $i++) {
    if ($engine.HasExited) {
        break
    }

    try {
        $schemaList = Invoke-RestMethod -Uri "http://127.0.0.1:7070/api/schema/list" -TimeoutSec 2
        if ($schemaList.schemas -contains "example") {
            $ready = $true
            break
        }
    } catch {
    }

    Start-Sleep -Seconds 1
}

if (-not $ready) {
    Write-Host ""
    Write-Host "Engine output:"
    Get-Content $stdout -Tail 100 -ErrorAction SilentlyContinue
    Get-Content $stderr -Tail 100 -ErrorAction SilentlyContinue
    throw "Freshly built engine did not become ready."
}

Section "Run one-image dynamic tagging ingestion"
$jobResponse = (& curl.exe -s -X POST -F "pipelineName=image" http://127.0.0.1:7070/api/example/index) -join ""
Write-Host "Engine response: $jobResponse"

$finished = $false
for ($i = 0; $i -lt 600; $i++) {
    $tagCountRaw = (& docker exec vitrivr-postgres psql -U postgres -d postgres -tAc "SELECT COUNT(*) FROM example.descriptor_tags;") -join ""
    $tagCount = 0
    [void][int]::TryParse($tagCountRaw.Trim(), [ref]$tagCount)

    if ($tagCount -gt 0) {
        $finished = $true
        break
    }

    if ($engine.HasExited) {
        break
    }

    Start-Sleep -Seconds 1
}

Section "Caption model actually used"
$captionEvidence = Get-DockerLogs "fes-caption" 300 | Select-String -Pattern "blip2|conditional-image-captioning/blip2" | Select-Object -Last 20

if ($captionEvidence) {
    $captionEvidence | ForEach-Object { Write-Host $_.Line }
} else {
    Write-Host "No BLIP2 evidence found in recent fes-caption logs."
}

Section "Image actually ingested"
docker exec vitrivr-postgres psql -U postgres -d postgres -c "SELECT retrievableid, path, size FROM example.descriptor_file;"

Section "Dynamic tagging result"
docker exec vitrivr-postgres psql -U postgres -d postgres -c "SELECT retrievableid, label, confidence FROM example.descriptor_tags ORDER BY confidence DESC;"

if (-not $finished) {
    Section "Engine diagnostics"
    Get-Content $stdout -Tail 120 -ErrorAction SilentlyContinue
    Get-Content $stderr -Tail 120 -ErrorAction SilentlyContinue

    Section "Caption FES diagnostics"
    Get-DockerLogs "fes-caption" 120

    Section "OpenCLIP FES diagnostics"
    Get-DockerLogs "fes-openclip" 120

    throw "Dynamic tagging produced no persisted tags. Diagnostics are printed above."
}

Section "Relevant engine log"
Get-Content $stdout -ErrorAction SilentlyContinue | Select-String -Pattern "Dynamic tagging caption model|Captioning response|Dynamic candidate tags|Error during batched extraction" | Select-Object -Last 40 | ForEach-Object { Write-Host $_.Line }

Write-Host ""
Write-Host "Dynamic tagging test completed."
