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
        Select-String -Pattern "caption model attempt|Captioning response|Dynamic candidate tags|failed during dynamic candidate generation|All configured captioning models failed|Error during batched extraction" |
        Select-Object -Last 50 |
        ForEach-Object { Write-Host $_.Line }
}

Section "Current BLIP2 status"
& cmd.exe /d /c "docker ps --filter name=fes-blip2 --format \"{{.Names}} | {{.Status}}\""
& cmd.exe /d /c "docker logs --tail 120 fes-blip2 2>&1"
