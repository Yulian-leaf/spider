[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$RepoUrl,

  [string]$Branch = "main",
  [string]$Message = "init",
  [string]$Path = (Get-Location).Path,

  [int]$WarnFileSizeMB = 50,
  [int]$MaxFileSizeMB = 100,
  [switch]$DisableLargeFileSkip,

  [switch]$NoCommit,
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Git {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
  if ($DryRun) {
    Write-Host ("DRYRUN> git " + ($GitArgs -join " "))
    return
  }
  & git @GitArgs
  if ($LASTEXITCODE -ne 0) {
    throw "git command failed ($LASTEXITCODE): git $($GitArgs -join ' ')"
  }
}

function Test-GitAvailable {
  try {
    & git --version | Out-Null
    return $true
  }
  catch {
    return $false
  }
}

function Get-GitPath {
  param(
    [Parameter(Mandatory = $true)][string]$BasePath,
    [Parameter(Mandatory = $true)][string]$FullPath
  )

  # Windows PowerShell 5.1 / .NET Framework doesn't have Path.GetRelativePath.
  $baseFull = [System.IO.Path]::GetFullPath($BasePath)
  if (-not $baseFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $baseFull += [System.IO.Path]::DirectorySeparatorChar
  }

  $uriBase = [System.Uri]::new($baseFull)
  $uriFull = [System.Uri]::new([System.IO.Path]::GetFullPath($FullPath))
  $relUri = $uriBase.MakeRelativeUri($uriFull)
  $rel = [System.Uri]::UnescapeDataString($relUri.ToString())

  # ensure forward slashes for git paths
  return ($rel -replace "\\", "/")
}

function Get-WorkingTreeLargeFiles {
  param(
    [Parameter(Mandatory = $true)][string]$RootPath,
    [Parameter(Mandatory = $true)][int64]$WarnBytes,
    [Parameter(Mandatory = $true)][int64]$BlockBytes
  )

  $files = Get-ChildItem -LiteralPath $RootPath -Recurse -File -Force -ErrorAction Stop |
  Where-Object { $_.FullName -notlike (Join-Path $RootPath ".git") + "*" }

  $warn = @()
  $block = @()

  foreach ($f in $files) {
    if ($f.Length -ge $BlockBytes) {
      $block += [pscustomobject]@{
        SizeMB = [math]::Round($f.Length / 1MB, 2)
        Path   = Get-GitPath -BasePath $RootPath -FullPath $f.FullName
      }
      continue
    }

    if ($f.Length -ge $WarnBytes) {
      $warn += [pscustomobject]@{
        SizeMB = [math]::Round($f.Length / 1MB, 2)
        Path   = Get-GitPath -BasePath $RootPath -FullPath $f.FullName
      }
    }
  }

  return [pscustomobject]@{ Warn = $warn; Block = $block }
}

function Ensure-GitignoreHasEntries {
  param(
    [Parameter(Mandatory = $true)][string]$GitignorePath,
    [Parameter(Mandatory = $true)][string[]]$Entries,
    [switch]$WhatIf
  )

  if ($Entries.Count -eq 0) { return }

  $existing = @()
  if (Test-Path -LiteralPath $GitignorePath) {
    $existing = Get-Content -LiteralPath $GitignorePath -ErrorAction SilentlyContinue
  }

  $toAdd = @()
  foreach ($e in $Entries) {
    if (-not ($existing -contains $e)) {
      $toAdd += $e
    }
  }

  if ($toAdd.Count -eq 0) { return }

  if ($WhatIf) {
    Write-Host "DRYRUN> append to .gitignore:"
    $toAdd | ForEach-Object { Write-Host ("  " + $_) }
    return
  }

  $block = @(
    "",
    "# Auto-added by git-init-push.ps1 to avoid GitHub 100MB limit",
    "# (these files were detected as too large to push)",
    ""
  ) + $toAdd

  $block | Out-File -FilePath $GitignorePath -Append -Encoding utf8
}

function Get-RepoTooLargeBlobs {
  param(
    [Parameter(Mandatory = $true)][int64]$ThresholdBytes,
    [int]$Top = 10
  )

  $results = @()

  $gitDir = (& git rev-parse --git-dir 2>$null)
  if ($LASTEXITCODE -ne 0 -or -not $gitDir) {
    return $results
  }

  $packDir = Join-Path (Join-Path $gitDir "objects") "pack"
  $idxFiles = @()
  if (Test-Path -LiteralPath $packDir) {
    $idxFiles = @(Get-ChildItem -LiteralPath $packDir -Filter "*.idx" -File -ErrorAction SilentlyContinue)
  }

  if ($idxFiles.Count -gt 0) {
    foreach ($idx in $idxFiles) {
      $lines = & git verify-pack -v $idx.FullName 2>$null
      foreach ($line in $lines) {
        if ($line -notmatch "^[0-9a-f]{40}\s+") { continue }
        $parts = $line -split "\s+"
        if ($parts.Count -lt 3) { continue }
        $hash = $parts[0]
        $type = $parts[1]
        $size = 0
        if (-not [int64]::TryParse($parts[2], [ref]$size)) { continue }
        if ($type -eq "blob" -and $size -ge $ThresholdBytes) {
          $results += [pscustomobject]@{ Object = $hash; SizeMB = [math]::Round($size / 1MB, 2) }
        }
      }
    }
  }
  else {
    # Fallback: works on newer Git versions
    $lines = & git cat-file --batch-check="%(objectname) %(objecttype) %(objectsize)" --batch-all-objects 2>$null
    foreach ($line in $lines) {
      if ($line -notmatch "^[0-9a-f]{40}\s+") { continue }
      $parts = $line -split "\s+"
      if ($parts.Count -lt 3) { continue }
      $hash = $parts[0]
      $type = $parts[1]
      $size = 0
      if (-not [int64]::TryParse($parts[2], [ref]$size)) { continue }
      if ($type -eq "blob" -and $size -ge $ThresholdBytes) {
        $results += [pscustomobject]@{ Object = $hash; SizeMB = [math]::Round($size / 1MB, 2) }
      }
    }
  }

  if ($results.Count -eq 0) { return $results }

  return $results | Sort-Object SizeMB -Descending | Select-Object -First $Top
}

if (-not (Test-GitAvailable)) {
  throw "Git not found on PATH. Install Git for Windows and ensure 'git --version' works."
}

if (-not (Test-Path -LiteralPath $Path)) {
  throw "Path does not exist: $Path"
}

Set-Location -LiteralPath $Path

# 1) init
if (-not (Test-Path -LiteralPath (Join-Path $Path ".git"))) {
  Invoke-Git init
}

# 2) ensure .gitignore exists (only create when missing)
$gitignorePath = Join-Path $Path ".gitignore"
if (-not (Test-Path -LiteralPath $gitignorePath)) {
  $defaultGitignore = @(
    "# OS / Editor",
    "Thumbs.db",
    "Desktop.ini",
    ".DS_Store",
    "",
    "# VS Code / Visual Studio",
    ".vscode/",
    ".vs/",
    "",
    "# C/C++ build artifacts",
    "*.exe",
    "*.obj",
    "*.o",
    "*.out",
    "",
    "# Common outputs",
    "**/output/",
    ".cph/"
  ) -join "`r`n"

  if ($DryRun) {
    Write-Host "DRYRUN> create .gitignore"
  }
  else {
    $defaultGitignore | Out-File -FilePath $gitignorePath -Encoding utf8
  }
}

# 2.5) detect and skip too-large files before staging
$warnBytes = [int64]$WarnFileSizeMB * 1MB
$blockBytes = [int64]$MaxFileSizeMB * 1MB

$scan = Get-WorkingTreeLargeFiles -RootPath $Path -WarnBytes $warnBytes -BlockBytes $blockBytes

if ($scan.Warn.Count -gt 0) {
  Write-Warning "Large files (>=${WarnFileSizeMB}MB) detected in working tree. GitHub recommends <=50MB and blocks >100MB."
  $scan.Warn | Sort-Object SizeMB -Descending | Select-Object -First 20 | Format-Table -AutoSize | Out-Host
}

if (-not $DisableLargeFileSkip -and $scan.Block.Count -gt 0) {
  Write-Warning "Too-large files (>=${MaxFileSizeMB}MB) will be skipped from commit/push to avoid GitHub limits."
  $scan.Block | Sort-Object SizeMB -Descending | Select-Object -First 20 | Format-Table -AutoSize | Out-Host

  $pathsToIgnore = $scan.Block | Select-Object -ExpandProperty Path
  Ensure-GitignoreHasEntries -GitignorePath $gitignorePath -Entries $pathsToIgnore -WhatIf:$DryRun
}

# 3) stage
Invoke-Git add -A

# 3.5) unstage / untrack too-large files (keeps them on disk)
if (-not $DisableLargeFileSkip -and $scan.Block.Count -gt 0) {
  foreach ($f in $scan.Block) {
    if ($DryRun) {
      Write-Host ("DRYRUN> git rm -f --cached -- " + $f.Path)
      continue
    }

    try {
      # Remove from index so it won't be committed/pushed
      # --ignore-unmatch prevents noisy failures when path isn't tracked/staged
      Invoke-Git rm -f --cached --ignore-unmatch -- $f.Path
    }
    catch {
      # If it wasn't staged/tracked, ignore
    }
  }
}

# 4) commit (optional)
if (-not $NoCommit) {
  $hasStagedChanges = $true
  try {
    if (-not $DryRun) {
      & git diff --cached --quiet
      if ($LASTEXITCODE -eq 0) { $hasStagedChanges = $false }
    }
  }
  catch {
    # ignore
  }

  if ($DryRun -or $hasStagedChanges) {
    try {
      Invoke-Git commit -m $Message
    }
    catch {
      # Most common case: nothing to commit
      if ($_.Exception.Message -notmatch "nothing to commit") {
        throw
      }
    }
  }
}

# 5) branch name
try {
  Invoke-Git branch -M $Branch
}
catch {
  # ignore
}

# 6) remote
$remoteExists = $false
if (-not $DryRun) {
  $remotes = & git remote 2>$null
  if ($LASTEXITCODE -eq 0 -and $remotes) {
    $remoteExists = ($remotes -split "\r?\n" | Where-Object { $_ -eq "origin" } | Measure-Object).Count -gt 0
  }
}

if ($DryRun) {
  Write-Host "DRYRUN> ensure origin remote = $RepoUrl"
}
else {
  if ($remoteExists) {
    Invoke-Git remote set-url origin $RepoUrl
  }
  else {
    Invoke-Git remote add origin $RepoUrl
  }
}

# 7) warn about large files in HEAD (if there is a commit)
if (-not $DryRun) {
  $hasHead = $true
  & git rev-parse --verify HEAD 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { $hasHead = $false }

  if ($hasHead) {
    $large = @()
    $tooLargeHead = @()
    # Show non-ASCII paths without quoting/escaping
    $lines = & git -c core.quotepath=false ls-tree -r --long HEAD
    foreach ($line in $lines) {
      # format: <mode> <type> <object> <size>\t<path>
      $parts = $line -split "\t", 2
      if ($parts.Count -ne 2) { continue }
      $meta = $parts[0] -split "\s+"
      if ($meta.Count -lt 4) { continue }
      $size = 0
      if (-not [int64]::TryParse($meta[-1], [ref]$size)) { continue }
      if ($size -ge ($WarnFileSizeMB * 1MB)) {
        $large += [pscustomobject]@{ SizeMB = [math]::Round($size / 1MB, 2); Path = $parts[1] }
      }
      if ($size -ge ($MaxFileSizeMB * 1MB)) {
        $tooLargeHead += [pscustomobject]@{ SizeMB = [math]::Round($size / 1MB, 2); Path = $parts[1] }
      }
    }

    if (-not $DisableLargeFileSkip -and $tooLargeHead.Count -gt 0) {
      Write-Error "HEAD contains files >=${MaxFileSizeMB}MB. GitHub will reject pushes if these blobs exist in history, even if deleted later. Remove them from history (or re-init the repo) before pushing."
      $tooLargeHead | Sort-Object SizeMB -Descending | Select-Object -First 10 | Format-Table -AutoSize | Out-Host
      throw "Push blocked: too-large files present in commit history (HEAD)."
    }
    if ($large.Count -gt 0) {
      Write-Warning "Large files (>=${WarnFileSizeMB}MB) detected in HEAD. GitHub recommends <=50MB and blocks >100MB. Consider Git LFS or ignoring large files."
      $large | Sort-Object SizeMB -Descending | Select-Object -First 10 | Format-Table -AutoSize | Out-Host
    }
  }
}

# 8) push
try {
  # IMPORTANT: GitHub rejects pushes if ANY commit history contains blobs >= 100MB.
  # Auto-skip only helps for new commits; it cannot undo existing history.
  if (-not $DisableLargeFileSkip -and -not $DryRun) {
    $tooLargeAny = @(Get-RepoTooLargeBlobs -ThresholdBytes $blockBytes -Top 10)
    if ($tooLargeAny.Count -gt 0) {
      Write-Error "Repository history contains blobs >=${MaxFileSizeMB}MB. GitHub will reject this push even if those files were later deleted."
      $tooLargeAny | Format-Table -AutoSize | Out-Host
      Write-Error "Fix: re-init the repo (delete .git) and re-run this script, OR rewrite history with filter-repo/BFG, OR use Git LFS."
      throw "Push blocked: too-large blobs exist in history."
    }
  }

  Invoke-Git push -u origin $Branch
}
catch {
  if ($_.Exception.Message -match "GH001|pre-receive hook declined|exceeds GitHub's file size limit") {
    Write-Error "Push was rejected by GitHub due to large files. This script can auto-skip files >=${MaxFileSizeMB}MB (default). If you need them in the repo, use Git LFS."
  }
  throw
}

Write-Host "Done: pushed to $RepoUrl ($Branch)"