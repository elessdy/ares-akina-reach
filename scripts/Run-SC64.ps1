[CmdletBinding()]
param(
    [string]$Emulator = (Join-Path $PSScriptRoot 'ares.exe'),
    [Parameter(Mandatory = $true)][string]$Rom,
    [string]$UserDirectory = (Join-Path $PSScriptRoot 'SC64-user'),
    [ValidateRange(1, 65535)][int]$UsbPort = 9064,
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
$executable = (Resolve-Path -LiteralPath $Emulator).Path
$romFile = (Resolve-Path -LiteralPath $Rom).Path
if (-not [System.IO.Path]::IsPathRooted($UserDirectory)) {
    $UserDirectory = Join-Path (Get-Location).Path $UserDirectory
}
$stateRoot = [System.IO.Path]::GetFullPath($UserDirectory)
$arguments = @('--settings-file', (Join-Path $stateRoot 'settings.bml'), '--no-file-prompt',
    '--setting', 'Nintendo64/SC64=true', '--setting', "Nintendo64/SC64USBHostPort=$UsbPort",
    '--setting', 'Nintendo64/SC64SDImage=')
foreach ($entry in @(@('Home', 'Systems'), @('Firmware', 'Firmware'), @('Saves', 'Saves'),
    @('Screenshots', 'Screenshots'), @('Debugging', 'Debugging'))) {
    $directory = Join-Path $stateRoot $entry[1]
    if (-not $Check) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $portablePath = $directory.Replace('\', '/') + '/'
    $arguments += @('--setting', "Paths/$($entry[0])=$portablePath")
}
$arguments += $romFile
if ($Check) {
    [pscustomobject]@{ Executable = $executable; Arguments = $arguments; LoopbackEndpoint = "127.0.0.1:$UsbPort" }
    return
}
& $executable @arguments
