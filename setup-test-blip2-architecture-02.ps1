param(
    [string]$RepoRoot = "C:\vitrivr\vitrivr-engine"
)

$ErrorActionPreference = "Stop"
Set-Location $RepoRoot

function Section([string]$Text) {
    Write-Host ""
    Write-Host "=== $Text ==="
}

Section "Sync team/image"
git fetch origin
git switch team/image
git pull --ff-only origin team/image

Section "Start dedicated BLIP2 FES"
$existingBlip2 = docker ps -a --format "{{.Names}}" | Where-Object { $_ -eq "fes-blip2" }
if ($existingBlip2) {
    docker rm -f fes-blip2 | Out-Null
}
docker volume create fes-blip2-cache | Out-Null
docker pull faberf/featureextractionserver:blip2-latest
if ($LASTEXITCODE -ne 0) {
    throw "Could not pull faberf/featureextractionserver:blip2-latest"
}

docker run -d --name fes-blip2 -p 5002:8888 -v fes-blip2-cache:/root/.cache -e LOG_LEVEL=INFO faberf/featureextractionserver:blip2-latest | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Could not start fes-blip2."
}

$ready = $false
for ($i = 0; $i -lt 120; $i++) {
    try {
        $tasks = (& curl.exe -s http://127.0.0.1:5002/api/tasks) -join ""
        if ($tasks -match "conditional-image-captioning") {
            $ready = $true
            break
        }
    } catch {}
    Start-Sleep -Seconds 2
}
if (-not $ready) {
    docker logs --tail 100 fes-blip2
    throw "Dedicated BLIP2 FES did not become ready."
}

Section "Build current engine"
.\gradlew.bat :vitrivr-engine-server:installDist --rerun-tasks
if ($LASTEXITCODE -ne 0) {
    throw "Engine build failed."
}

Section "Run architecture_02 test"
powershell -ExecutionPolicy Bypass -File .\test-architecture-02.ps1
