[CmdletBinding()]
param(
    [string]$BuildDirectory = (Join-Path $PSScriptRoot '../build/sc64'),
    [ValidateRange(1, 4)][int]$Jobs = 4,
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
$sourceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (-not [System.IO.Path]::IsPathRooted($BuildDirectory)) {
    $BuildDirectory = Join-Path (Get-Location).Path $BuildDirectory
}
$buildRoot = [System.IO.Path]::GetFullPath($BuildDirectory)
& cmake -S $sourceRoot -B $buildRoot -G 'Visual Studio 17 2022' -A x64 `
    -DARES_CORES=n64 -DARES_BUILD_LOCAL=OFF -DARES_BUILD_OFFICIAL=OFF `
    -DARES_BUILD_OPTIONAL_TARGETS=OFF -DARES_UNITY_CORES=ON -DENABLE_CCACHE=OFF `
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed.' }
& cmake --build $buildRoot --config Release --parallel $Jobs
if ($LASTEXITCODE -ne 0) { throw 'N64-only compilation failed.' }
if (-not $SkipTests) {
    $testBuild = Join-Path $buildRoot 'sc64-tests'
    & cmake -S (Join-Path $sourceRoot 'tests/sc64') -B $testBuild -G 'Visual Studio 17 2022' -A x64 -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
    if ($LASTEXITCODE -ne 0) { throw 'SC64 test configuration failed.' }
    & cmake --build $testBuild --config Release --parallel $Jobs
    if ($LASTEXITCODE -ne 0) { throw 'SC64 test compilation failed.' }
    & ctest --test-dir $testBuild -C Release --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw 'SC64 transport regressions failed.' }
}
$runtime = Join-Path $buildRoot 'desktop-ui/rundir'
$executable = Join-Path $runtime 'ares.exe'
Copy-Item -LiteralPath (Join-Path $sourceRoot 'LICENSE') -Destination (Join-Path $runtime 'LICENSE')
Copy-Item -LiteralPath (Join-Path $sourceRoot 'scripts/README-sc64.md') -Destination $runtime
Copy-Item -LiteralPath (Join-Path $sourceRoot 'scripts/Run-SC64.ps1') -Destination $runtime
Copy-Item -LiteralPath (Join-Path $sourceRoot 'deps.json') -Destination $runtime
$dependencyNotices = Join-Path $sourceRoot '.deps/ares-deps-windows-x64/licenses'
$runtimeNotices = Join-Path $runtime 'licenses'
New-Item -ItemType Directory -Force -Path $runtimeNotices | Out-Null
Copy-Item -Path (Join-Path $dependencyNotices '*') -Destination $runtimeNotices -Recurse -Force
[xml]$project = Get-Content -LiteralPath (Join-Path $buildRoot 'desktop-ui/desktop-ui.vcxproj')
$manifest = [ordered]@{
    sourceCommit = (& git -C $sourceRoot rev-parse HEAD)
    sourceChanges = @(& git -C $sourceRoot status --porcelain)
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $executable).Hash.ToLowerInvariant()
    cmake = (& cmake --version | Select-Object -First 1)
    compiler = @(Select-String -Path (Join-Path $buildRoot 'CMakeFiles/*/CMakeCXXCompiler.cmake') -Pattern 'CMAKE_CXX_COMPILER_VERSION' -ErrorAction SilentlyContinue | ForEach-Object { $_.Line })
    windowsSdk = ($project.SelectNodes('//*[local-name()="WindowsTargetPlatformVersion"]') | Select-Object -First 1).InnerText
    configuration = 'Windows x64, VS2022, Release, N64-only, generic CPU baseline, unofficial, unity cores, static MSVC CRT'
    dependencyManifestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $sourceRoot 'deps.json')).Hash.ToLowerInvariant()
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runtime 'sc64-build.json') -Encoding UTF8
Write-Output "SC64 runtime: $runtime"
Get-FileHash -Algorithm SHA256 -LiteralPath $executable
