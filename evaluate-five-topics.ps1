param(
    [string]$RepoRoot = "C:\vitrivr\vitrivr-engine"
)

$ErrorActionPreference = "Stop"
Set-Location $RepoRoot

function Section([string]$Text) {
    Write-Host ""
    Write-Host "=== $Text ==="
}

function Ensure-Container([string]$Name) {
    $running = docker ps --format "{{.Names}}" | Where-Object { $_ -eq $Name }
    if ($running) { return }

    $exists = docker ps -a --format "{{.Names}}" | Where-Object { $_ -eq $Name }
    if ($exists) {
        docker start $Name | Out-Null
        Start-Sleep -Seconds 2
        return
    }

    throw "Required Docker container '$Name' does not exist."
}

Section "Check services"
Ensure-Container "vitrivr-postgres"
Ensure-Container "fes-openclip"

Section "Stop old engine"
$listener = Get-NetTCPConnection -LocalPort 7070 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
    Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

Section "Clear previous evaluation data"
docker exec vitrivr-postgres psql -U postgres -d postgres -c "TRUNCATE TABLE example.retrievable CASCADE;" | Out-Host

Section "Start engine"
$engineBat = Join-Path $RepoRoot "vitrivr-engine-server\build\install\vitrivr-engine-server\bin\vitrivr-engine-server.bat"
$schema = Join-Path $RepoRoot "example-configs\docker\schema.json"

if (-not (Test-Path $engineBat)) {
    throw "Installed engine distribution not found. Run installDist once first."
}

$logDir = Join-Path $RepoRoot "build\five-topic-eval"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stdout = Join-Path $logDir "engine.out.log"
$stderr = Join-Path $logDir "engine.err.log"
Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue

Start-Process -FilePath $engineBat -ArgumentList $schema -WorkingDirectory $RepoRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr | Out-Null

$ready = $false
for ($i = 0; $i -lt 90; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:7070/api/schema/list" -UseBasicParsing -TimeoutSec 2
        if ($resp.StatusCode -eq 200) {
            $ready = $true
            break
        }
    } catch {}
    Start-Sleep -Seconds 1
}

if (-not $ready) {
    Get-Content $stdout -Tail 80 -ErrorAction SilentlyContinue
    throw "Engine did not become ready."
}

Section "Run 50-image five-topic evaluation"
$response = (& curl.exe -s -X POST -F "pipelineName=image-eval" http://127.0.0.1:7070/api/example/index) -join ""
Write-Host "Engine response: $response"

$stableRounds = 0
$lastFiles = -1
for ($i = 0; $i -lt 360; $i++) {
    $fileRaw = (& docker exec vitrivr-postgres psql -U postgres -d postgres -tAc "SELECT COUNT(*) FROM example.descriptor_file;") -join ""
    $tagRaw = (& docker exec vitrivr-postgres psql -U postgres -d postgres -tAc "SELECT COUNT(*) FROM example.descriptor_tags;") -join ""

    $fileCount = 0
    $tagCount = 0
    [void][int]::TryParse($fileRaw.Trim(), [ref]$fileCount)
    [void][int]::TryParse($tagRaw.Trim(), [ref]$tagCount)

    if (($i % 10) -eq 0) {
        Write-Host ("Processed files: " + $fileCount + " | topic scores: " + $tagCount)
    }

    if ($fileCount -gt 0 -and $tagCount -ge ($fileCount * 5)) {
        if ($fileCount -eq $lastFiles) {
            $stableRounds++
        } else {
            $stableRounds = 0
        }
        $lastFiles = $fileCount

        if (($fileCount -ge 50) -or ($stableRounds -ge 5)) {
            break
        }
    }

    $failure = Get-Content $stdout -ErrorAction SilentlyContinue |
        Select-String -Pattern "Error during batched extraction|OpenCLIP returned no classification result|Failed to analyse" |
        Select-Object -Last 1
    if ($failure) {
        Write-Host $failure.Line
        break
    }

    Start-Sleep -Seconds 1
}

$sqlCommon = @"
WITH ranked AS (
    SELECT
        f.retrievableid,
        f.path,
        CASE
            WHEN lower(replace(f.path, '\\', '/')) LIKE '%/architecture/%' THEN 'architecture'
            WHEN lower(replace(f.path, '\\', '/')) LIKE '%/landscapes/%'   THEN 'landscape'
            WHEN lower(replace(f.path, '\\', '/')) LIKE '%/portraits/%'    THEN 'portrait'
            WHEN lower(replace(f.path, '\\', '/')) LIKE '%/religious/%'    THEN 'religious art'
            WHEN lower(replace(f.path, '\\', '/')) LIKE '%/still_life/%'   THEN 'still life'
            ELSE NULL
        END AS true_topic,
        t.label,
        t.confidence,
        ROW_NUMBER() OVER (
            PARTITION BY f.retrievableid
            ORDER BY t.confidence DESC, t.label
        ) AS predicted_rank
    FROM example.descriptor_file f
    JOIN example.descriptor_tags t
      ON t.retrievableid = f.retrievableid
),
per_image AS (
    SELECT
        retrievableid,
        path,
        true_topic,
        MAX(CASE WHEN predicted_rank = 1 THEN label END) AS predicted_topic,
        MAX(CASE WHEN predicted_rank = 1 THEN confidence END) AS top1_score,
        MAX(CASE WHEN label = true_topic THEN confidence END) AS true_topic_score,
        MIN(CASE WHEN label = true_topic THEN predicted_rank END) AS true_topic_rank
    FROM ranked
    WHERE true_topic IS NOT NULL
    GROUP BY retrievableid, path, true_topic
)
"@

Section "Overall result"
$overallSql = $sqlCommon + @"
SELECT
    COUNT(*) AS images,
    SUM(CASE WHEN predicted_topic = true_topic THEN 1 ELSE 0 END) AS correct_top1,
    ROUND(100.0 * AVG(CASE WHEN predicted_topic = true_topic THEN 1.0 ELSE 0.0 END), 2) AS top1_accuracy_percent,
    ROUND(AVG(true_topic_score)::numeric, 4) AS avg_true_topic_score,
    ROUND(AVG(true_topic_rank)::numeric, 2) AS avg_true_topic_rank
FROM per_image;
"@
docker exec vitrivr-postgres psql -U postgres -d postgres -c $overallSql | Out-Host

Section "Accuracy by topic"
$topicSql = $sqlCommon + @"
SELECT
    true_topic,
    COUNT(*) AS images,
    SUM(CASE WHEN predicted_topic = true_topic THEN 1 ELSE 0 END) AS correct_top1,
    ROUND(100.0 * AVG(CASE WHEN predicted_topic = true_topic THEN 1.0 ELSE 0.0 END), 2) AS accuracy_percent,
    ROUND(AVG(true_topic_score)::numeric, 4) AS avg_true_topic_score,
    ROUND(AVG(true_topic_rank)::numeric, 2) AS avg_true_topic_rank
FROM per_image
GROUP BY true_topic
ORDER BY true_topic;
"@
docker exec vitrivr-postgres psql -U postgres -d postgres -c $topicSql | Out-Host

Section "Confusion matrix"
$confusionSql = $sqlCommon + @"
SELECT
    true_topic,
    predicted_topic,
    COUNT(*) AS images
FROM per_image
GROUP BY true_topic, predicted_topic
ORDER BY true_topic, images DESC, predicted_topic;
"@
docker exec vitrivr-postgres psql -U postgres -d postgres -c $confusionSql | Out-Host

Section "10 weakest images"
$weakSql = $sqlCommon + @"
SELECT
    regexp_replace(path, '^.*[\\/]', '') AS file,
    true_topic,
    predicted_topic,
    ROUND(true_topic_score::numeric, 4) AS true_topic_score,
    true_topic_rank
FROM per_image
ORDER BY true_topic_score ASC NULLS FIRST, path
LIMIT 10;
"@
docker exec vitrivr-postgres psql -U postgres -d postgres -c $weakSql | Out-Host

$csvSql = $sqlCommon + @"
COPY (
    SELECT
        path,
        true_topic,
        predicted_topic,
        top1_score,
        true_topic_score,
        true_topic_rank,
        CASE WHEN predicted_topic = true_topic THEN 1 ELSE 0 END AS correct_top1
    FROM per_image
    ORDER BY true_topic, path
) TO STDOUT WITH CSV HEADER;
"@

$csvPath = Join-Path $logDir "five-topic-evaluation.csv"
$csv = (& docker exec vitrivr-postgres psql -U postgres -d postgres -Atc $csvSql) -join [Environment]::NewLine
Set-Content -Path $csvPath -Value $csv -Encoding UTF8

Section "Saved report"
Write-Host $csvPath
