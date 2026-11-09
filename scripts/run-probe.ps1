#Requires -Version 7.2
<#
.SYNOPSIS
    Queues the security probe, waits for it, and saves the comparison table under results/.

.EXAMPLE
    ./scripts/run-probe.ps1 -ProofOfImpact
#>
[CmdletBinding()]
param(
    # Let probe jobs make one read-only API call with any registration token they find.
    [switch] $ProofOfImpact,
    [ValidateRange(5, 120)] [int] $TimeoutMinutes = 45
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$state = Get-DemoState
if (-not $state['pipelineId']) { throw 'Run ./scripts/deploy.ps1 first.' }
$orgUrl = "https://dev.azure.com/$($state.organization)"
$projectPath = [uri]::EscapeDataString($state.project)
$pipelineId = $state.pipelineId

Write-Step 'Queueing the security probe'
# Pass the pool names this instance was deployed with, so non-default names work too.
$templateParameters = @{ proofOfImpact = $ProofOfImpact.IsPresent.ToString().ToLowerInvariant() }
if ($state['aciPool']) { $templateParameters.aciPool = $state.aciPool }
if ($state['mdpPool']) { $templateParameters.mdpPool = $state.mdpPool }
$run = Invoke-Ado -Method POST -Uri "$orgUrl/$projectPath/_apis/pipelines/$pipelineId/runs?api-version=7.1" -Body @{
    templateParameters = $templateParameters
    resources          = @{ repositories = @{ self = @{ refName = 'refs/heads/main' } } }
}
Write-Host "Run $($run.id): $orgUrl/$projectPath/_build/results?buildId=$($run.id)"

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    Start-Sleep -Seconds 20
    $current = Invoke-Ado -Uri "$orgUrl/$projectPath/_apis/pipelines/$pipelineId/runs/$($run.id)?api-version=7.1"
    Write-Host "  $(Get-Date -Format HH:mm:ss)  $($current.state) $($current.PSObject.Properties['result']?.Value)"
} until ($current.state -eq 'completed' -or (Get-Date) -gt $deadline)
if ($current.state -ne 'completed') { throw "Run $($run.id) did not finish within $TimeoutMinutes minutes." }

Write-Step 'Downloading the comparison'
$artifact = Invoke-Ado -Uri "$orgUrl/$projectPath/_apis/build/builds/$($run.id)/artifacts?artifactName=probe-comparison&api-version=7.1"
$work = Join-Path ([IO.Path]::GetTempPath()) "probe-$($run.id)-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $zip = Join-Path $work 'comparison.zip'
    Invoke-WebRequest -Uri $artifact.resource.downloadUrl -Headers (Get-AdoHeaders) -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $work
    $comparison = Get-ChildItem -Path $work -Recurse -Filter comparison.md | Select-Object -First 1
    # Run IDs are per organisation, so the file name includes the organisation.
    $destination = Join-Path $script:RepoRoot "results/run-$($run.id)-$($state.organization).md"
    Copy-Item -Path $comparison.FullName -Destination $destination -Force
} finally {
    Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
}
Get-Content $destination
Write-Host "`nSaved $destination (result: $($current.result))"
