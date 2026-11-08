# scan-secrets.ps1 -- fast pre-publish leak scanner for a project folder.
#
# Guards the two mistakes that are expensive after a public push:
#   1. real secrets (tokens, private keys, cloud keys) => ERROR, must fix before publishing;
#   2. private infrastructure/PII (private IPs, Tailscale/CGNAT IPs, personal home paths,
#      emails) => WARNING, usually should be scrubbed before a public repo.
#
# Matched secret text is redacted in the report, so running this never leaks the secret.
#
# Exit codes (default): 0 clean, 1 warnings only, 2 errors found.
# Pass -NoExit to always exit 0 (used by publish-github.ps1, which reads the JSON itself).
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [string]$ExtraPatterns = '',
  [switch]$Json,
  [switch]$NoExit,
  [switch]$FailOnWarnings,
  [int]$MaxFiles = 20000,
  [long]$MaxBytesPerFile = 2MB
)

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $Path).Path
$skipDirRegex = '\\(\.git|node_modules|\.venv|venv|__pycache__|\.pytest_cache|\.mypy_cache|\.next|\.turbo|dist|build|out|coverage|\.idea|\.vscode)(\\|$)'
$selfRegex = '\\\.dsh\\skills\\github-repo-publish\\'
$binaryExt = @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.bmp', '.pdf', '.zip', '.gz', '.7z', '.rar',
  '.exe', '.dll', '.so', '.dylib', '.bin', '.woff', '.woff2', '.ttf', '.otf', '.eot', '.mp3', '.mp4', '.mov',
  '.jar', '.class', '.pyc', '.node', '.wasm', '.sqlite', '.db', '.lock')

$errorRules = [ordered]@{
  'github-token'   = 'gh[pousr]_[A-Za-z0-9]{36,}'
  'github-pat'     = 'github_pat_[A-Za-z0-9_]{20,}'
  'aws-access-key' = 'AKIA[0-9A-Z]{16}'
  'private-key'    = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'slack-token'    = 'xox[baprs]-[A-Za-z0-9-]{10,}'
  'openai-key'     = 'sk-[A-Za-z0-9_-]{24,}'
  'google-api-key' = 'AIza[0-9A-Za-z_-]{35}'
  'jwt-like'       = 'eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}'
  'basic-auth-url' = '://[^/\s:@$<>{}]+:[^/\s@$<>{}]+@[^/\s]+'
}

$warnRules = [ordered]@{
  'private-ip'        = '\b(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.\d{1,3}\.\d{1,3})\b'
  'tailscale-ip'      = '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}\b'
  'windows-home-path' = '[A-Za-z]:\\Users\\[A-Za-z0-9._-]+'
  'linux-home-path'   = '/home/[a-z_][a-z0-9_-]{1,}'
  'mac-home-path'     = '/Users/[A-Za-z0-9._-]+'
  'email'             = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
}

if ($ExtraPatterns) {
  $index = 0
  foreach ($pattern in $ExtraPatterns.Split(';')) {
    if ($pattern.Trim()) { $warnRules["custom-$($index)"] = $pattern.Trim(); $index++ }
  }
}

$errorHits = New-Object System.Collections.Generic.List[object]
$warnHits = New-Object System.Collections.Generic.List[object]

$fileList = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object {
    $_.Length -le $MaxBytesPerFile -and
    $_.FullName -notmatch $skipDirRegex -and
    $_.FullName -notmatch $selfRegex -and
    ($binaryExt -notcontains $_.Extension.ToLowerInvariant())
  } | Select-Object -First $MaxFiles)

function Redact([string]$line, [string]$matchValue) {
  if ($matchValue) { return ($line -replace [regex]::Escape($matchValue), '<redacted>') }
  return $line
}

foreach ($file in $fileList) {
  $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/')
  $lineNo = 0
  try {
    foreach ($line in [IO.File]::ReadLines($file.FullName)) {
      $lineNo++
      foreach ($rule in $errorRules.Keys) {
        $m = [regex]::Match($line, $errorRules[$rule])
        if ($m.Success) {
          $errorHits.Add([pscustomobject]@{ rule = $rule; file = $relative; line = $lineNo; preview = (Redact $line $m.Value).Trim() })
        }
      }
      foreach ($rule in $warnRules.Keys) {
        $m = [regex]::Match($line, $warnRules[$rule])
        if ($m.Success) {
          $warnHits.Add([pscustomobject]@{ rule = $rule; file = $relative; line = $lineNo; preview = $line.Trim() })
        }
      }
    }
  } catch { }
}

$result = [pscustomobject]@{
  path     = $root
  scanned  = $fileList.Count
  errors   = $errorHits.ToArray()
  warnings = $warnHits.ToArray()
}

if ($Json) {
  Write-Output ($result | ConvertTo-Json -Depth 5 -Compress)
} else {
  foreach ($hit in $result.errors) { Write-Output ("ERROR [{0}] {1}:{2}  {3}" -f $hit.rule, $hit.file, $hit.line, $hit.preview) }
  foreach ($hit in $result.warnings) { Write-Output ("WARN  [{0}] {1}:{2}  {3}" -f $hit.rule, $hit.file, $hit.line, $hit.preview) }
  Write-Output ("scan: {0} files, {1} errors, {2} warnings" -f $result.scanned, $result.errors.Count, $result.warnings.Count)
}

if ($NoExit) { exit 0 }
if ($result.errors.Count -gt 0) { exit 2 }
if ($result.warnings.Count -gt 0 -and $FailOnWarnings) { exit 1 }
exit 0
