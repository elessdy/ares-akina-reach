[CmdletBinding()]
param([string]$WorkDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) ('sc64-package-test-' + [guid]::NewGuid())))
$ErrorActionPreference = 'Stop'
$exporter = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../scripts/Package-SC64.ps1')).Path
if (-not [System.IO.Path]::IsPathRooted($WorkDirectory)) {
    $WorkDirectory = Join-Path (Get-Location).Path $WorkDirectory
}
$testRoot = [System.IO.Path]::GetFullPath($WorkDirectory)
if (Test-Path -LiteralPath $testRoot) { throw 'Test WorkDirectory must be fresh.' }
New-Item -ItemType Directory -Path $testRoot | Out-Null
$runtime = Join-Path $testRoot 'runtime'
New-Item -ItemType Directory -Path $runtime | Out-Null

function Write-Fixture([string]$Name, [string]$Value) {
    $path = Join-Path $runtime $Name
    New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($path)) | Out-Null
    [System.IO.File]::WriteAllText($path, $Value)
}
function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-True $failed $Message
}

$expected = @('ares.exe', 'SDL3.dll', 'librashader.dll', 'LICENSE', 'README-sc64.md',
    'Run-SC64.ps1', 'deps.json', 'sc64-build.json', 'Database/Arcade.bml',
    'Shaders/example.slangp', 'Shaders/sub/example.slang', 'licenses/SDL3/LICENSE.txt')
foreach ($name in $expected) { Write-Fixture $name "Public emulator fixture: $name" }
Write-Fixture 'deps.json' '{"dependencies":{}}'
$buildManifest = @{
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $runtime 'ares.exe')).Hash
    dependencyManifestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $runtime 'deps.json')).Hash
    sourceCommit = '1111111111111111111111111111111111111111'
    sourceChanges = @()
} | ConvertTo-Json
Write-Fixture 'sc64-build.json' $buildManifest

# Fictional documentation-range address; no real host lookup or local settings.
$privateMarker = 'PRIVATE_FIXTURE_HOST=203.0.113.87:6464'
foreach ($name in @('settings.bml', 'host-address.txt', 'companion.json', 'future-host-config.yml',
    'SC64-user/settings.bml', 'SC64-user/host.txt', 'SC64-user/Saves/game.eep',
    'SC64-user/Systems/game.z64', 'history/recent-games.json', 'Saves/game.sra',
    'games/example.n64', 'game.v64', 'SDL3.pdb', 'librashader.pdb', 'unrelated.dll')) {
    Write-Fixture $name $privateMarker
}
$package = Join-Path $testRoot 'package'
$result = & $exporter -RuntimeDirectory $runtime -OutputDirectory $package
$actual = @(Get-ChildItem -LiteralPath $package -File -Recurse | ForEach-Object {
    $_.FullName.Substring($package.Length + 1).Replace([char]92, [char]47)
})
$expected += 'SHA256SUMS.txt'
Assert-True (@(Compare-Object ($expected | Sort-Object) ($actual | Sort-Object)).Count -eq 0) 'Package did not match the exact allowlisted fixture.'
foreach ($file in Get-ChildItem -LiteralPath $package -File -Recurse) {
    Assert-True (-not ([System.IO.File]::ReadAllText($file.FullName).Contains($privateMarker))) 'Private fixture marker leaked.'
}
$checksumPath = Join-Path $package 'SHA256SUMS.txt'
$priorHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $checksumPath).Hash
Assert-Rejected { & $exporter -RuntimeDirectory $runtime -OutputDirectory $package } 'Existing directory was not refused.'
Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $checksumPath).Hash -eq $priorHash) 'Refused export changed an existing package.'
Assert-Rejected { & $exporter -RuntimeDirectory $runtime -OutputDirectory (Join-Path $runtime 'nested-output') } 'Nested output was not refused.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $runtime 'nested-output'))) 'Refused nested export created output.'
Write-Fixture 'ares.exe' 'changed executable'
$mismatched = Join-Path $testRoot 'mismatched-output'
Assert-Rejected { & $exporter -RuntimeDirectory $runtime -OutputDirectory $mismatched } 'Mismatched executable manifest was not refused.'
Assert-True (-not (Test-Path -LiteralPath $mismatched)) 'Invalid manifest created output.'
Write-Output "SC64 package regressions passed ($($result.Files) allowed fixture files; private state excluded)."
