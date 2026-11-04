param(
    [string]$RepoRoot = "C:\vitrivr\vitrivr-engine"
)

$ErrorActionPreference = "Stop"
Set-Location $RepoRoot

function Section([string]$Text) {
    Write-Host ""
    Write-Host "=== $Text ==="
}

Section "Stop old engine"
$listener = Get-NetTCPConnection -LocalPort 7070 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
    Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

Section "Clear previous test data"
docker exec vitrivr-postgres psql -U postgres -d postgres -c "TRUNCATE TABLE example.retrievable CASCADE;"

Section "Start engine with architecture_02 config"
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
    try {
        $schemaList = Invoke-RestMethod -Uri "http://127.0.0.1:7070/api/schema/list" -TimeoutSec 2
        if ($schemaList.schemas -contains "example") {
            $ready = $true
            break
        }
    } catch {}
    Start-Sleep -Seconds 1
}
if (-not $ready) { throw "Engine did not become ready." }

Section "Run architecture_02 ingestion"
$jobResponse = (& curl.exe -s -X POST -F "pipelineName=image" http://127.0.0.1:7070/api/example/index) -join ""
Write-Host "Engine response: $jobResponse"

for ($i = 0; $i -lt 300; $i++) {
    $countRaw = (& docker exec vitrivr-postgres psql -U postgres -d postgres -tAc "SELECT COUNT(*) FROM example.descriptor_tags;") -join ""
    $count = 0
    [void][int]::TryParse($countRaw.Trim(), [ref]$count)
    if ($count -gt 0) { break }
    Start-Sleep -Seconds 1
}

Section "Image actually ingested"
docker exec vitrivr-postgres psql -U postgres -d postgres -c "SELECT retrievableid, path, size FROM example.descriptor_file;"

Section "Top tags"
docker exec vitrivr-postgres psql -U postgres -d postgres -c "SELECT label, confidence FROM example.descriptor_tags ORDER BY confidence DESC LIMIT 5;"

Section "Caption and candidates"
Get-Content $stdout -ErrorAction SilentlyContinue |
    Select-String -Pattern "Captioning response|Dynamic candidate tags" |
    Select-Object -Last 20 |
    ForEach-Object { Write-Host $_.Line }
