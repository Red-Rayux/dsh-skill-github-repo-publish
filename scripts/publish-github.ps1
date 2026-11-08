# publish-github.ps1 -- one-command publish of a local folder to a GitHub repo.
#
# What it does (in order):
#   1. preflight: verify source folder + git; optional prebuild command; leak scan;
#      strip accidental UTF-8 BOM from text files (keeps it on .ps1 for PS 5.1);
#   2. git: init if needed, repo-local identity, add + commit, branch name;
#   3. auth: resolve GH_TOKEN / -Token / `gh auth token`; verify the account matches -Owner;
#   4. repo: create via API when missing (or push to existing with -Update);
#   5. push with an ephemeral credential helper (the token is never written to git config);
#   6. metadata: description, topics;
#   7. optional release: git-archive source zip + GitHub Release asset;
#   8. verify: remote HEAD vs local HEAD, a blob sha via the contents API (NOT raw.githubusercontent,
#      which is CDN-cached), release assets;
#   9. print one compact JSON object (the only output an agent needs to read).
#
# Typical use:
#   & publish-github.ps1 -SourceDir D:\work\my-project -Owner Red-Rayux -Repo my-project `
#       -Description "..." -Topics "a,b" -DryRun
#   & publish-github.ps1 ... -Release -ReleaseTag v1.0.0
#
# Requires: Windows PowerShell 5.1+ (or pwsh 7), git, network for the first gh download/API calls.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$SourceDir,
  [Parameter(Mandatory = $true)][string]$Owner,
  [Parameter(Mandatory = $true)][string]$Repo,
  [string]$Description = '',
  [ValidateSet('public', 'private')][string]$Visibility = 'public',
  [string]$Topics = '',
  [string]$CommitMessage = '',
  [string]$Branch = 'main',
  [string]$Token = '',
  [string]$ToolsDir = '',
  [string]$PrebuildCommand = '',
  [switch]$Update,
  [switch]$Release,
  [string]$ReleaseTag = '',
  [string]$ReleaseName = '',
  [string]$ReleaseNotes = '',
  [string]$ReleaseNotesFile = '',
  [switch]$SkipScan,
  [switch]$SkipBomStrip,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------- output helpers
function Emit-Result {
  param($Object, [int]$Code = 0)
  $Object | ConvertTo-Json -Depth 8
  exit $Code
}

function Fail {
  param([string]$Step, [string]$Message, [string[]]$Hints = @())
  Emit-Result ([pscustomobject]@{ ok = $false; step = $Step; error = [string]$Message; hints = @($Hints) }) 1
}

# ---------------------------------------------------------------- native + git helpers
# Native commands often write warnings/progress to stderr (git autocrlf, git push "To ...",
# gh upload progress). Under $ErrorActionPreference='Stop' the 2>&1 merge would turn those
# into terminating errors, so every native call goes through this capture helper instead.
function Invoke-Native {
  param([Parameter(Mandatory = $true)][string]$File, [string[]]$Arguments = @())
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $File @Arguments 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previous
  }
  return [pscustomobject]@{ code = $code; output = @($output) }
}

$script:GitRoot = ''

function Git-Text {
  param([string[]]$GitArgs)
  $native = Invoke-Native -File 'git' -Arguments (@('-C', $script:GitRoot) + $GitArgs)
  if ($native.code -ne 0) {
    throw ("git " + ($GitArgs -join ' ') + " failed: " + (($native.output | Out-String).Trim()))
  }
  return ([string](($native.output | Out-String).Trim()))
}

function Git-Lines {
  param([string[]]$GitArgs)
  $native = Invoke-Native -File 'git' -Arguments (@('-C', $script:GitRoot) + $GitArgs)
  if ($native.code -ne 0) {
    throw ("git " + ($GitArgs -join ' ') + " failed: " + (($native.output | Out-String).Trim()))
  }
  return @($native.output)
}

# ---------------------------------------------------------------- state
$script:Token = ''
$script:GhPath = ''
$scan = $null
$warnSample = @()
$notes = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- helpers
function Get-ApiHeaders {
  $headers = @{
    Authorization = "token $($script:Token)"
    'User-Agent'  = 'dsh-github-publish-skill'
    Accept        = 'application/vnd.github+json'
  }
  return $headers
}

function Invoke-Api {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method,
    [Parameter(Mandatory = $true)][string]$ApiPath,
    $Body = $null,
    [hashtable]$ExtraHeaders = @{}
  )
  $headers = Get-ApiHeaders
  foreach ($key in $ExtraHeaders.Keys) { $headers[$key] = $ExtraHeaders[$key] }
  $params = @{ Uri = "https://api.github.com$ApiPath"; Method = $Method; Headers = $headers; TimeoutSec = 60 }
  if ($null -ne $Body) {
    $params['Body'] = ($Body | ConvertTo-Json -Depth 8 -Compress)
    $params['ContentType'] = 'application/json'
  }
  try {
    $data = Invoke-RestMethod @params
    return [pscustomobject]@{ ok = $true; status = 200; data = $data; error = ''; detail = '' }
  } catch {
    $status = 0
    $detail = ''
    try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { }
    try {
      if ($_.Exception.Response) {
        $reader = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
        $detail = $reader.ReadToEnd()
      }
    } catch { }
    return [pscustomobject]@{ ok = $false; status = $status; data = $null; error = $_.Exception.Message; detail = $detail }
  }
}

function Resolve-Token {
  if ($Token) { return $Token }
  if ($env:GH_TOKEN) { return $env:GH_TOKEN }
  if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
  if ($script:GhPath) {
    $native = Invoke-Native -File $script:GhPath -Arguments @('auth', 'token')
    if ($native.code -eq 0 -and $native.output.Count -gt 0) {
      $stored = ([string]$native.output[0]).Trim()
      if ($stored) { return $stored }
    }
  }
  return ''
}

function Remove-BomFromTextFiles {
  param([string]$Root)
  $keepBomExt = @('.ps1', '.psm1', '.psd1')
  $stripped = 0
  $files = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.Length -lt 2MB }
  foreach ($file in $files) {
    if ($keepBomExt -contains $file.Extension.ToLowerInvariant()) { continue }
    try { $bytes = [IO.File]::ReadAllBytes($file.FullName) } catch { continue }
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { continue }
    try {
      $text = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
      [IO.File]::WriteAllText($file.FullName, $text, (New-Object Text.UTF8Encoding($false)))
      $stripped++
    } catch { }
  }
  return $stripped
}

function Get-ScanSummary {
  if ($null -eq $scan) { return [pscustomobject]@{ skipped = $true } }
  return [pscustomobject]@{ errors = $scan.errors.Count; warnings = $scan.warnings.Count; warningSample = @($warnSample) }
}

# ================================================================ main
try {
  if (-not (Test-Path -LiteralPath $SourceDir)) { Fail 'source' "SourceDir not found: $SourceDir" }
  $src = (Resolve-Path -LiteralPath $SourceDir).Path
  if (-not (Test-Path -LiteralPath $src -PathType Container)) { Fail 'source' "SourceDir is not a directory: $src" }
  $script:GitRoot = $src
  if (-not $Branch) { $Branch = 'main' }
  if (-not $CommitMessage) { $CommitMessage = "chore: publish $Repo" }

  # ---- git availability
  try { $gitVersion = Git-Text @('--version') } catch { Fail 'git' 'git is not available on PATH' @('Install Git for Windows and make sure `git` resolves in this shell.') }
  $hasGit = Test-Path -LiteralPath (Join-Path $src '.git')
  $hasHead = $false
  if ($hasGit) {
    try { Git-Text @('rev-parse', '--verify', 'HEAD') | Out-Null; $hasHead = $true } catch { $hasHead = $false }
  }

  # ---- optional prebuild
  if ($PrebuildCommand) {
    if ($DryRun) {
      $notes.Add("would run prebuild: $PrebuildCommand")
    } else {
      $prebuild = Invoke-Native -File 'cmd' -Arguments @('/c', "cd /d `"$src`" && $PrebuildCommand")
      if ($prebuild.code -ne 0) {
        Fail 'prebuild' "PrebuildCommand failed (exit $($prebuild.code))" @(([string]($prebuild.output | Out-String)).Trim())
      }
      $notes.Add('prebuild ok')
    }
  }

  # ---- leak scan
  if (-not $SkipScan) {
    $scanner = Join-Path $PSScriptRoot 'scan-secrets.ps1'
    if (-not (Test-Path -LiteralPath $scanner)) { Fail 'scan' "scanner missing: $scanner" }
    try {
      $scanJson = (& $scanner -Path $src -Json -NoExit) | Out-String
      $scan = $scanJson | ConvertFrom-Json
    } catch {
      Fail 'scan' ('leak scan failed: ' + $_.Exception.Message)
    }
    if ($scan.errors.Count -gt 0) {
      Fail 'secrets' ("{0} potential secret(s) found - fix before publishing" -f $scan.errors.Count) @(
        $scan.errors | Select-Object -First 20 | ForEach-Object { "$($_.rule)  $($_.file):$($_.line)  $($_.preview)" }
      )
    }
    if ($scan.warnings.Count -gt 0) {
      $warnSample = @($scan.warnings | Select-Object -First 10 | ForEach-Object { "$($_.rule)  $($_.file):$($_.line)" })
      $notes.Add("leak-scan warnings: $($scan.warnings.Count) (private IPs / home paths / emails)")
    }
  } else {
    $notes.Add('leak scan skipped (-SkipScan)')
  }

  # ---- BOM cleanup + git init/config/commit
  $bomStripped = 0
  if (-not $DryRun) {
    if (-not $SkipBomStrip) {
      $bomStripped = Remove-BomFromTextFiles $src
      if ($bomStripped -gt 0) { $notes.Add("stripped UTF-8 BOM from $bomStripped file(s)") }
    }
    if (-not $hasGit) {
      Git-Text @('init', '-b', $Branch) | Out-Null
      Git-Text @('config', 'core.autocrlf', 'false') | Out-Null
      $hasGit = $true
      $notes.Add('git init')
    }
    Git-Text @('config', 'user.name', $Owner) | Out-Null
    Git-Text @('config', 'user.email', "$Owner@users.noreply.github.com") | Out-Null
    Git-Text @('add', '-A') | Out-Null
    $dirty = Git-Text @('status', '--porcelain')
    if ($dirty -or -not $hasHead) {
      Git-Text @('commit', '-m', $CommitMessage) | Out-Null
      $hasHead = $true
      $notes.Add('git commit')
    }
    if ($hasHead) {
      $currentBranch = Git-Text @('rev-parse', '--abbrev-ref', 'HEAD')
      if ($currentBranch -ne $Branch) {
        Git-Text @('branch', '-M', $Branch) | Out-Null
        $notes.Add("renamed local branch $currentBranch -> $Branch")
      }
    }
  } elseif (-not $hasGit) {
    $notes.Add("would run: git init -b $Branch")
  }

  $trackedCount = 0
  if (-not $DryRun -and $hasGit) {
    $trackedCount = (Git-Lines @('ls-files') | Measure-Object).Count
  } else {
    $trackedCount = (Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notmatch '\\\.git\\' } | Measure-Object).Count
  }
  $localHead = ''
  if ($hasHead) { $localHead = Git-Text @('rev-parse', 'HEAD') }

  # ---- gh CLI + auth
  try {
    $ghCandidates = @(& (Join-Path $PSScriptRoot 'ensure-gh.ps1') -ToolsDir $ToolsDir 2>$null)
    if ($ghCandidates.Count -gt 0) { $script:GhPath = ([string]$ghCandidates[-1]).Trim() }
  } catch {
    if (-not $DryRun) {
      Fail 'gh' ('could not locate/download GitHub CLI: ' + $_.Exception.Message) @(
        'Network is required once to download the portable gh CLI, or put gh on PATH.',
        'You can also set -ToolsDir to a folder that already contains a portable gh release.'
      )
    }
    $notes.Add('gh CLI unavailable: ' + $_.Exception.Message)
  }
  if ($script:GhPath) { $script:Token = Resolve-Token }

  $authOk = $false
  $authLogin = ''
  $repoExists = $false
  $repoData = $null
  if ($script:Token) {
    $me = Invoke-Api -Method GET -ApiPath '/user'
    if ($me.ok -and $me.data.login) {
      $authLogin = [string]$me.data.login
      $authOk = ($authLogin -ieq $Owner)
    }
  }
  if (-not $authOk) {
    if (-not $DryRun) {
      $hints = @()
      if (-not $script:Token) {
        $hints += 'Run `' + $script:GhPath + ' auth login --hostname github.com --git-protocol https` in a normal terminal, or pass -Token / set GH_TOKEN.'
        $hints += 'Or create a classic PAT with `repo` scope (+ `workflow` only if you must push .github/workflows).'
      } else {
        $hints += "token belongs to '$authLogin' but -Owner is '$Owner'; use a token for the right account or fix -Owner."
      }
      Fail 'auth' 'GitHub authentication failed' $hints
    }
    $notes.Add('auth unavailable in dry run; will be required for the real run')
  } else {
    $repoCheck = Invoke-Api -Method GET -ApiPath "/repos/$Owner/$Repo"
    if ($repoCheck.ok) { $repoExists = $true; $repoData = $repoCheck.data }
    elseif ($repoCheck.status -ne 404 -and $repoCheck.status -ne 0) {
      Fail 'repo' ("unexpected GitHub API response ({0}): {1}" -f $repoCheck.status, $repoCheck.error)
    }
  }

  # ---- dry run stops here with the full plan
  if ($DryRun) {
    $plan = New-Object System.Collections.Generic.List[string]
    if (-not $repoExists) { $plan.Add("create $Visibility repo $Owner/$Repo") } else { $plan.Add("push to existing repo $Owner/$Repo (-Update required)") }
    $plan.Add("push branch $Branch ($trackedCount files)")
    if ($Description) { $plan.Add('set description') }
    if ($Topics) { $plan.Add("set topics: $Topics") }
    if ($Release) { $plan.Add("create release $ReleaseTag") }
    Emit-Result ([pscustomobject]@{
        ok          = $true
        dryRun      = $true
        source      = $src
        repo        = "$Owner/$Repo"
        branch      = $Branch
        visibility  = $Visibility
        trackedFiles = $trackedCount
        head        = $localHead
        ghPath      = $script:GhPath
        auth        = [pscustomobject]@{ ok = $authOk; login = $authLogin }
        repoExists  = $repoExists
        plan        = $plan.ToArray()
        scan        = Get-ScanSummary
        notes       = $notes.ToArray()
      }) 0
  }

  if (-not $authOk) { Fail 'auth' 'not authenticated' @('Pass -Token or set GH_TOKEN, then retry without -DryRun.') }

  # ---- create repo when needed
  $createdRepo = $false
  if (-not $repoExists) {
    $ownerInfo = Invoke-Api -Method GET -ApiPath "/users/$Owner"
    $isOrg = $false
    if ($ownerInfo.ok) { $isOrg = ([string]$ownerInfo.data.type -eq 'Organization') }
    $createPath = '/user/repos'
    if ($isOrg) { $createPath = "/orgs/$Owner/repos" }
    $createBody = @{
      name         = $Repo
      description  = $Description
      private      = ($Visibility -eq 'private')
      has_issues   = $true
      has_wiki     = $false
      has_projects = $false
      auto_init    = $false
    }
    $created = Invoke-Api -Method POST -ApiPath $createPath -Body $createBody
    if (-not $created.ok) {
      Fail 'create' ("create repo failed ({0}): {1}" -f $created.status, $created.error) @(
        ($created.detail | Out-String).Trim(),
        'A classic PAT needs the `repo` scope to create repositories.'
      )
    }
    $repoExists = $true
    $createdRepo = $true
    $repoData = $created.data
    $notes.Add('repo created')
  }
  if (-not $Update -and -not $createdRepo) {
    Fail 'repo-exists' "repo already exists: https://github.com/$Owner/$Repo" @(
      'Pass -Update to push to the existing repo, or choose another -Repo name.'
    )
  }

  # ---- remote + push (token used ephemerally, never stored)
  $remoteUrl = "https://github.com/$Owner/$Repo.git"
  $existingRemote = ''
  try { $existingRemote = Git-Text @('remote', 'get-url', 'origin') } catch { $existingRemote = '' }
  if ($existingRemote) { Git-Text @('remote', 'set-url', 'origin', $remoteUrl) | Out-Null }
  else { Git-Text @('remote', 'add', 'origin', $remoteUrl) | Out-Null }

  $env:GH_TOKEN = $script:Token
  $helper = '!' + ($script:GhPath -replace '\\', '/') + ' auth git-credential'
  $pushOut = @()
  $pushOk = $false
  $push = Invoke-Native -File 'git' -Arguments @('-C', $src, '-c', 'credential.helper=', '-c', "credential.https://github.com.helper=$helper", 'push', '-u', 'origin', $Branch)
  $pushOut = $push.output
  if ($push.code -eq 0) { $pushOk = $true }

  if (-not $pushOk) {
    # Fallback: one-shot token URL, used only for this call (never written to git config).
    $tokenUrl = "https://x-access-token:$($script:Token)@github.com/$Owner/$Repo.git"
    $push = Invoke-Native -File 'git' -Arguments @('-C', $src, 'push', $tokenUrl, "HEAD:$Branch")
    $pushOut = $push.output
    if ($push.code -eq 0) { $pushOk = $true }
  }
  if (-not $pushOk) {
    $pushText = ([string]($pushOut | Out-String)).Trim()
    $hints = @()
    if ($pushText -match 'workflow') {
      $hints += 'A classic PAT needs the `workflow` scope to push .github/workflows/*. Move CI to e.g. docs/ci.yml.example, or use a token with that scope.'
    }
    if ($pushText -match 'non-fast-forward|fetch first|rejected') {
      $hints += 'Remote has commits the local repo does not: fetch/rebase manually, or publish to a new repo name.'
    }
    Fail 'push' $pushText $hints
  }

  # ---- metadata
  if ($Topics) {
    $names = @($Topics.Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ($names.Count -gt 0) {
      $topicsResult = Invoke-Api -Method PUT -ApiPath "/repos/$Owner/$Repo/topics" -Body @{ names = $names } -ExtraHeaders @{ Accept = 'application/vnd.github.mercy-preview+json' }
      if (-not $topicsResult.ok) { $notes.Add("topics update failed ($($topicsResult.status))") }
    }
  }
  if ($Description -and -not $createdRepo) {
    $descResult = Invoke-Api -Method PATCH -ApiPath "/repos/$Owner/$Repo" -Body @{ description = $Description }
    if (-not $descResult.ok) { $notes.Add("description update failed ($($descResult.status))") }
  }

  # ---- optional release
  $releaseInfo = $null
  if ($Release) {
    $tag = $ReleaseTag
    if (-not $tag) {
      $packageJson = Join-Path $src 'package.json'
      if (Test-Path -LiteralPath $packageJson) {
        try { $version = (Get-Content -LiteralPath $packageJson -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { $version = '' }
        if ($version) { $tag = "v$version" }
      }
    }
    if (-not $tag) { Fail 'release' 'ReleaseTag is required when package.json has no version' @('Pass -ReleaseTag vX.Y.Z') }
    $title = $ReleaseName
    if (-not $title) { $title = "$Repo $tag" }
    $noteText = $ReleaseNotes
    if ($ReleaseNotesFile -and (Test-Path -LiteralPath $ReleaseNotesFile)) {
      $noteText = Get-Content -LiteralPath $ReleaseNotesFile -Raw -Encoding UTF8
    }
    if (-not $noteText) { $noteText = "Release $tag" }

    $zipDir = Join-Path $env:TEMP ('dsh-publish-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $zipDir | Out-Null
    $zipPath = Join-Path $zipDir ("$Repo-$tag.zip")
    Push-Location -LiteralPath $src
    try { Git-Text @('archive', '--format=zip', "--prefix=$Repo-$tag/", '-o', $zipPath, 'HEAD') | Out-Null }
    finally { Pop-Location }

    $env:GH_TOKEN = $script:Token
    $releaseNative = Invoke-Native -File $script:GhPath -Arguments @('release', 'create', $tag, $zipPath, '--repo', "$Owner/$Repo", '--title', $title, '--notes', $noteText)
    $releaseOut = $releaseNative.output
    $releaseCode = $releaseNative.code
    if ($releaseCode -ne 0) {
      Fail 'release' ([string]($releaseOut | Out-String)).Trim() @(
        'If the tag/release already exists, delete it first (gh release delete <tag> --cleanup-tag) or use another -ReleaseTag.',
        'A tag must point at the same commit that was pushed; create the release after the final push.'
      )
    }
    Remove-Item -LiteralPath $zipDir -Recurse -Force -ErrorAction SilentlyContinue
    $releaseInfo = [pscustomobject]@{ tag = $tag; url = "https://github.com/$Owner/$Repo/releases/tag/$tag"; zip = "$Repo-$tag.zip" }
  }

  # ---- verify (contents API blob sha avoids raw.githubusercontent CDN staleness)
  $repoAfter = Invoke-Api -Method GET -ApiPath "/repos/$Owner/$Repo"
  $remoteHead = ''
  try {
    $lsRemote = Git-Text @('ls-remote', 'origin', "refs/heads/$Branch")
    if ($lsRemote) { $remoteHead = ($lsRemote -split '\s+')[0] }
  } catch { }
  $blobFile = ''
  if (Test-Path -LiteralPath (Join-Path $src 'README.md')) { $blobFile = 'README.md' }
  else {
    $firstFile = (Git-Lines @('ls-files') | Select-Object -First 1)
    if ($firstFile) { $blobFile = [string]$firstFile }
  }
  $blobMatch = $null
  if ($blobFile) {
    $localBlob = Git-Text @('rev-parse', "HEAD:$blobFile")
    $encoded = ($blobFile -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $contentResult = Invoke-Api -Method GET -ApiPath "/repos/$Owner/$Repo/contents/$encoded"
    if ($contentResult.ok) { $blobMatch = ([string]$contentResult.data.sha -eq $localBlob) }
  }

  Emit-Result ([pscustomobject]@{
      ok           = $true
      repo         = "$Owner/$Repo"
      url          = $repoAfter.data.html_url
      visibility   = $repoAfter.data.visibility
      branch       = $Branch
      head         = $localHead
      remoteHead   = $remoteHead
      headMatch    = ($remoteHead -eq $localHead)
      blobChecked  = $blobFile
      blobMatch    = $blobMatch
      trackedFiles = $trackedCount
      createdRepo  = $createdRepo
      release      = $releaseInfo
      scan         = Get-ScanSummary
      notes        = $notes.ToArray()
    }) 0
} catch {
  Fail 'unexpected' $_.Exception.Message @('Re-run with -DryRun to inspect the preflight without side effects.')
}
