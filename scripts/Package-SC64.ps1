[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RuntimeDirectory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'

function Assert-RegularItem($Item) {
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Package input must not be a link or junction: $($Item.FullName)"
    }
}

$runtime = Get-Item -LiteralPath $RuntimeDirectory
if (-not $runtime.PSIsContainer) { throw 'RuntimeDirectory must be a directory.' }
Assert-RegularItem $runtime
$runtimeRoot = $runtime.FullName.TrimEnd([char]92, [char]47)
if (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path (Get-Location).Path $OutputDirectory
}
$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory).TrimEnd([char]92, [char]47)
if (Test-Path -LiteralPath $outputRoot) { throw 'OutputDirectory already exists; choose a fresh export directory.' }
if ($outputRoot.Equals($runtimeRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $outputRoot.StartsWith($runtimeRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must be outside RuntimeDirectory.'
}

# Export only emulator components. In particular, do not glob *.dll or copy
# the runtime root: the launcher may already have created SC64-user there.
$requiredFiles = @('ares.exe', 'SDL3.dll', 'librashader.dll', 'LICENSE',
    'README-sc64.md', 'Run-SC64.ps1', 'deps.json', 'sc64-build.json')
$resourceDirectories = @('Database', 'Shaders', 'licenses')
$files = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
foreach ($name in $requiredFiles) {
    $item = Get-Item -LiteralPath (Join-Path $runtimeRoot $name)
    Assert-RegularItem $item
    if ($item.PSIsContainer) { throw "Required package file is a directory: $name" }
    $files.Add($item)
}
foreach ($name in $resourceDirectories) {
    $directory = Get-Item -LiteralPath (Join-Path $runtimeRoot $name)
    Assert-RegularItem $directory
    if (-not $directory.PSIsContainer) { throw "Required resource directory is a file: $name" }
    $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $pending.Push($directory)
    while ($pending.Count -gt 0) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop().FullName -Force) {
            Assert-RegularItem $item
            if ($item.PSIsContainer) { $pending.Push($item) }
            else { $files.Add($item) }
        }
    }
}

$manifest = Get-Content -LiteralPath (Join-Path $runtimeRoot 'sc64-build.json') -Raw | ConvertFrom-Json
$executableHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $runtimeRoot 'ares.exe')).Hash
if ($manifest.sha256 -ne $executableHash) { throw 'Executable does not match sc64-build.json.' }
$dependencyHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $runtimeRoot 'deps.json')).Hash
if ($manifest.dependencyManifestSha256 -ne $dependencyHash) { throw 'Dependency manifest does not match sc64-build.json.' }

# Validate everything before creating the destination. Without -Force this also
# refuses a destination created by another process after the existence check.
New-Item -ItemType Directory -Path $outputRoot | Out-Null
$checksums = New-Object 'System.Collections.Generic.List[string]'
foreach ($file in $files | Sort-Object FullName) {
    $relative = $file.FullName.Substring($runtimeRoot.Length + 1)
    $destination = Join-Path $outputRoot $relative
    New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($destination)) | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $destination
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash.ToLowerInvariant()
    $checksums.Add("$hash  $($relative.Replace([char]92, [char]47))")
}
$checksums | Set-Content -LiteralPath (Join-Path $outputRoot 'SHA256SUMS.txt') -Encoding UTF8
[pscustomobject]@{ PackageDirectory = $outputRoot; Files = $files.Count; ExecutableSha256 = $executableHash.ToLowerInvariant() }
