# ensure-gh.ps1 -- locate a GitHub CLI, or download a portable copy (no admin, no installer).
#
# Output: exactly one line on stdout = absolute path of gh executable.
# Diagnostics go to stderr. Exit 0 on success, 1 on failure.
#
# Notes (learned the hard way):
#   * gh is often NOT installed on Windows; the portable zip from cli/cli releases works anywhere.
#   * Never install with winget/choco for an agent task: MSI needs elevation, portable zip does not.
#   * Cache dir defaults to %LOCALAPPDATA%\dsh-tools\gh so later sessions reuse it (saves tokens/network).
[CmdletBinding()]
param(
  [string]$ToolsDir = '',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Emit([string]$path) {
  Write-Output $path
  exit 0
}

function Warn([string]$message) {
  [Console]::Error.WriteLine("[ensure-gh] $message")
}

# 1) Already on PATH?
if (-not $Force) {
  $onPath = Get-Command gh -ErrorAction SilentlyContinue
  if ($onPath -and $onPath.Source) { Emit $onPath.Source }
}

# 2) Cached portable copy?
if (-not $ToolsDir) { $ToolsDir = Join-Path $env:LOCALAPPDATA 'dsh-tools\gh' }
$cached = Join-Path $ToolsDir 'bin\gh.exe'
if ((Test-Path -LiteralPath $cached) -and -not $Force) {
  try {
    & $cached --version *> $null
    if ($LASTEXITCODE -eq 0) { Emit $cached }
  } catch { }
}

# 3) Download the latest portable release.
$zipPath = Join-Path $ToolsDir 'gh.zip'
New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
Warn 'downloading portable GitHub CLI (about 15 MB, one time) ...'
$release = Invoke-RestMethod -Uri 'https://api.github.com/repos/cli/cli/releases/latest' `
  -Headers @{ 'User-Agent' = 'dsh-publish-skill'; Accept = 'application/vnd.github+json' } -TimeoutSec 30
$asset = $release.assets | Where-Object { $_.name -match 'windows_amd64\.zip$' } | Select-Object -First 1
if (-not $asset) { throw 'no windows_amd64 zip asset found in the latest cli/cli release' }
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing -TimeoutSec 300
Expand-Archive -Path $zipPath -DestinationPath $ToolsDir -Force
Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
$found = Get-ChildItem -Path $ToolsDir -Recurse -Filter 'gh.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $found) { throw 'gh.exe not found after extracting the release zip' }
& $found.FullName --version *> $null
Emit $found.FullName
