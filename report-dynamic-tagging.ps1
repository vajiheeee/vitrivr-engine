param(
    [string]$RepoRoot = "C:\vitrivr\vitrivr-engine"
)

$ErrorActionPreference = "Continue"
Set-Location $RepoRoot

function Section([string]$Text) {
    Write-Host ""
    Write-Host "=== $Text ==="
}

function Get-DockerLogs([string]$Name, [int]$Tail = 300) {
    & cmd.exe /d /c "docker logs --tail $Tail $Name 2>&1"
}

Section "Caption model actually used"
$stdout = Join-Path $RepoRoot "build\dynamic-tagging-test\engine.out.log"
$captionEvidence = if (Test-Path $stdout) {
    Get-Content $stdout |
        Select-String -Pattern "Dynamic tagging caption model attempt:" |
        Select-Object -Last 5
}

if ($captionEvidence) {
    $captionEvidence | ForEach-Object { Write-Host $_.Line }
} else {
    Write-Host "No caption-model line found in the current engine log."
}

Section "Image actually ingested"
docker exec vitrivr-postgres psql -U postgres -d postgres -c "SELECT retrievableid, path, size FROM example.descriptor_file;"

Section "Dynamic tagging result"
docker exec vitrivr-postgres psql -U postgres -d postgres -c "SELECT retrievableid, label, confidence FROM example.descriptor_tags ORDER BY confidence DESC;"

Section "Relevant engine log"
if (Test-Path $stdout) {
    Get-Content $stdout |
        Select-String -Pattern "Dynamic tagging caption model|Captioning response|Dynamic candidate tags|Error during batched extraction" |
        Select-Object -Last 40 |
        ForEach-Object { Write-Host $_.Line }
} else {
    Write-Host "Engine log file not found: $stdout"
}
