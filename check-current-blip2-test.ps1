param(
    [string]$RepoRoot = "C:\vitrivr\vitrivr-engine"
)

$ErrorActionPreference = "Continue"
Set-Location $RepoRoot

function Section([string]$Text) {
    Write-Host ""
    Write-Host "=== $Text ==="
}

$stdout = Join-Path $RepoRoot "build\dynamic-tagging-test\engine.out.log"
$stderr = Join-Path $RepoRoot "build\dynamic-tagging-test\engine.err.log"

Section "Current database state"
docker exec vitrivr-postgres psql -U postgres -d postgres -c "SELECT retrievableid, path FROM example.descriptor_file;"
docker exec vitrivr-postgres psql -U postgres -d postgres -c "SELECT label, confidence FROM example.descriptor_tags ORDER BY confidence DESC LIMIT 5;"

Section "Current engine status"
if (Test-Path $stdout) {
    Get-Content $stdout |
        Select-String -Pattern "caption model attempt|Captioning response|Dynamic candidate tags|failed during dynamic candidate generation|All configured captioning models failed|Error during batched extraction|Starting batched conditional image captioning|Api Error" |
        Select-Object -Last 50 |
        ForEach-Object { Write-Host $_.Line }

    Section "Full engine tail"
    Get-Content $stdout -Tail 80
}

Section "Current BLIP2 status"
docker ps --filter "name=fes-blip2" --format "{{.Names}} | {{.Status}}"

$dockerLog = Join-Path $RepoRoot "build\dynamic-tagging-test\fes-blip2.current.log"
$cmd = 'docker logs --tail 120 fes-blip2 > "' + $dockerLog + '" 2>&1'
cmd.exe /d /c $cmd | Out-Null
if (Test-Path $dockerLog) {
    Get-Content $dockerLog
}

Section "Configured caption backend"
$configPath = Join-Path $RepoRoot "example-configs\docker\ingestion-image.json"
if (Test-Path $configPath) {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    Write-Host ("caption_host = " + $cfg.operators.tags.parameters.caption_host)
    Write-Host ("caption_model = " + $cfg.operators.tags.parameters.caption_model)
    Write-Host ("caption_fallback_host = " + $cfg.operators.tags.parameters.caption_fallback_host)
    Write-Host ("caption_prompts = " + $cfg.operators.tags.parameters.caption_prompts)
}
