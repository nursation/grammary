<#
  Starts (or restarts) the grammary server in Docker with restart=unless-stopped,
  so it comes back by itself after a reboot (Docker Desktop must autostart).

  The container signs in with its OWN long-lived token: CLAUDE_CODE_OAUTH_TOKEN
  from `claude setup-token` (valid for a year, covered by the subscription). The
  first run creates it: approve in the browser, copy the token the CLI prints
  (all of its lines - a narrow terminal wraps it) and press Enter; it is saved
  to .env next to this script (gitignored; docker compose reads .env by itself,
  so even a bare `docker compose up` keeps it). A token already in the
  clipboard is reused instead of creating another one.

  The host login (~\.claude\.credentials.json) is not shared with the container:
  its access token lives ~8 hours and the container cannot refresh it, so the
  server died every morning until the next `claude` login on the host.

  Credentials, in order of preference:
    1. CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY from the shell environment
    2. the same keys from .env next to this script
    3. the same keys from ~/.claude/settings.json env block (legacy fallback).
       Do NOT put the token there: that would silently downgrade every host
       Claude Code session to the inference-only token.
    4. none of them: `claude setup-token` runs and the token goes to .env

  Usage:
    .\up.ps1              start (build on first run; creates the token if missing)
    .\up.ps1 -SetupToken  replace the token (after a year, or if it was revoked)
    .\up.ps1 -Rebuild     force image rebuild
    .\up.ps1 -Down        stop and remove the container
#>
param(
  [switch]$Rebuild,
  [switch]$Down,
  [switch]$SetupToken
)

$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {

$envFile = Join-Path $PSScriptRoot '.env'

# replaces (or appends) one NAME=value line of .env, keeping every other line
function Set-DotEnvValue([string]$Name, [string]$Value) {
  $lines = @()
  if (Test-Path $envFile) { $lines = @(Get-Content $envFile) }
  $found = $false
  $lines = @(foreach ($line in $lines) {
    if ($line -match "^\s*$Name\s*=") { $found = $true; "$Name=$Value" } else { $line }
  })
  if (-not $found) { $lines += "$Name=$Value" }
  # UTF-8 without BOM: docker compose parses this file too
  [IO.File]::WriteAllLines($envFile, [string[]]$lines)
}

# The CLI hard-wraps the token to the terminal width and indents every line,
# and a terminal may copy that break as a newline or as a space: find the
# token in the clipboard and glue its pieces back. A setup-token has 108
# characters, so gluing stops there, before any text that follows it.
function Get-ClipboardToken {
  $text = ''
  try { $text = "$(Get-Clipboard -Raw)" } catch {}
  $m = [regex]::Match($text, 'sk-ant-oat\d+-[A-Za-z0-9_-]*')
  if (-not $m.Success) { return }
  $token = $m.Value
  $rest = $text.Substring($m.Index + $m.Length)
  while ($token.Length -lt 108) {
    # the next piece: after spaces and at most one line break (a blank line ends it)
    $next = [regex]::Match($rest, '^[^\S\r\n]*(?:\r\n|\r|\n)?[^\S\r\n]*([A-Za-z0-9_-]+)')
    if (-not $next.Success) { break }
    $token += $next.Groups[1].Value
    $rest = $rest.Substring($next.Length)
  }
  $token
}

# a setup-token has 108 characters; fewer means a wrapped line was not copied
function Confirm-TokenLength([string]$Token) {
  if ($Token.Length -eq 108) { return $true }
  Write-Host "the copied token has $($Token.Length) characters, not 108 - were all of its lines selected?" -ForegroundColor Yellow
  return ((Read-Host 'use it anyway? [y/N]') -match '^\s*y')
}

# `claude setup-token` (approved in the browser) -> the copied token -> .env
function New-ContainerToken {
  if ([Console]::IsInputRedirected) {
    throw 'creating the token needs an interactive terminal - run .\up.ps1 -SetupToken in one'
  }

  # a token an earlier run printed (still on screen, copied) is reused
  # instead of creating one more
  $old = Get-ClipboardToken
  $reuse = $old -and (Read-Host 'the clipboard holds a setup-token - use it? [Y/n]') -notmatch '^\s*n'

  if (-not $reuse) {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
      throw 'the claude CLI is not on PATH - install Claude Code, then re-run .\up.ps1'
    }
    Write-Host 'Creating the container''s own Claude token (valid for a year): approve it in the browser.' -ForegroundColor Cyan
    & claude setup-token
    if ($LASTEXITCODE -ne 0) { throw 'claude setup-token failed - nothing saved' }
  }

  $token = $null
  $ask = -not $reuse
  while (-not $token) {
    if ($ask) {
      # hidden, so a token pasted here anyway is not printed a second time
      $secure = Read-Host 'Select ALL lines of the token above, copy them, then press Enter here (q = quit)' -AsSecureString
      try { $Host.UI.RawUI.FlushInputBuffer() } catch {}   # the rest of a multi-line paste
      if ((New-Object Net.NetworkCredential('', $secure)).Password.Trim() -eq 'q') { throw 'nothing saved' }
    }
    $ask = $true
    $copied = Get-ClipboardToken
    if (-not $copied) {
      Write-Host 'the clipboard holds no sk-ant-oat01-... token' -ForegroundColor Yellow
    } elseif (-not $reuse -and $copied -eq $old) {
      Write-Host 'that is still the old token - copy the one just printed' -ForegroundColor Yellow
    } elseif (Confirm-TokenLength $copied) {
      $token = $copied
    }
  }

  Set-DotEnvValue 'CLAUDE_CODE_OAUTH_TOKEN' $token
  $env:CLAUDE_CODE_OAUTH_TOKEN = $token
  Write-Host "token saved to $envFile (gitignored)" -ForegroundColor Green
}

# --- hydrate credentials into the process env (compose interpolates from it) --

# .env: compose reads it natively; loading it here too lets the checks below
# see the same values
if (Test-Path $envFile) {
  foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*(ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN)\s*=\s*(.+)$') {
      $name = $Matches[1]
      if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name))) {
        Set-Item -Path "env:$name" -Value $Matches[2].Trim()
      }
    }
  }
}

# legacy fallback: ~/.claude/settings.json env block
$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
if (Test-Path $settingsPath) {
  $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
  foreach ($name in @('ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN')) {
    if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name))) {
      $v = $settings.env.$name
      if (-not [string]::IsNullOrEmpty($v)) { Set-Item -Path "env:$name" -Value $v }
    }
  }
}

# compose interpolates these even for `down`; empty is fine
foreach ($name in @('ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN')) {
  if ($null -eq [Environment]::GetEnvironmentVariable($name)) {
    Set-Item -Path "env:$name" -Value ''
  }
}

if ($Down) {
  docker compose down
  exit $LASTEXITCODE
}

# --- the container's own token ------------------------------------------------

if ($SetupToken) {
  New-ContainerToken
} elseif ([string]::IsNullOrEmpty($env:ANTHROPIC_API_KEY) -and
          [string]::IsNullOrEmpty($env:CLAUDE_CODE_OAUTH_TOKEN)) {
  Write-Host 'no CLAUDE_CODE_OAUTH_TOKEN yet - the container needs its own token (once a year)' -ForegroundColor Yellow
  New-ContainerToken
}

$composeArgs = @('compose', 'up', '-d')
if ($Rebuild) { $composeArgs += '--build' }
& docker @composeArgs
if ($LASTEXITCODE -ne 0) { throw 'docker compose failed' }

# --- wait for /health, then prove Claude accepts the credentials -------------

$port = if ($env:GRAMMARY_PORT) { $env:GRAMMARY_PORT } else { 8917 }
$deadline = (Get-Date).AddSeconds(30)
$health = $null
do {
  try { $health = Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 2; break }
  catch { Start-Sleep -Milliseconds 500 }
} while ((Get-Date) -lt $deadline)

if (-not $health) {
  Write-Host 'grammary did not answer /health in 30s - check "docker logs grammary"' -ForegroundColor Red
  exit 1
}

# /health only proves the server runs; one tiny fix proves Claude takes the token
Write-Host 'checking the credentials with one tiny fix...'
try {
  $null = Invoke-RestMethod "http://127.0.0.1:$port/fix" -Method Post -ContentType 'application/json' -Body '{"text":"helo world"}' -TimeoutSec 110
} catch {
  $err = $_
  $why = $err.Exception.Message
  # the server's JSON error: ErrorDetails in PowerShell 7, the raw response in 5.1
  $body = $null
  if ($err.ErrorDetails -and $err.ErrorDetails.Message) {
    $body = $err.ErrorDetails.Message
  } else {
    try {
      $body = (New-Object IO.StreamReader($err.Exception.Response.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd()
    } catch {}
  }
  if ($body) {
    try { $parsed = ($body | ConvertFrom-Json).error } catch { $parsed = $null }
    $why = if ($parsed) { $parsed } else { $body }
  }
  Write-Host "grammary runs, but Claude did not answer: $why" -ForegroundColor Red
  Write-Host 'an auth error means the token is wrong, expired or revoked - run .\up.ps1 -SetupToken' -ForegroundColor Red
  exit 1
}

Write-Host ("grammary is up: http://127.0.0.1:$port  model=" + $health.model) -ForegroundColor Green

if ("$port" -ne '8917') {
  Write-Host "warning: the extension is built for port 8917 - update SERVER in extension\background.js AND host_permissions in extension\manifest.json, then reload the extension" -ForegroundColor Yellow
}

# restart=unless-stopped only helps if the engine itself starts at sign-in
try {
  $ds = Get-Content (Join-Path $env:APPDATA 'Docker\settings-store.json') -Raw -ErrorAction Stop | ConvertFrom-Json
  if ($ds.PSObject.Properties['AutoStart'] -and -not $ds.AutoStart) {
    Write-Host 'warning: Docker Desktop does not start at sign-in (Settings -> General -> "Start Docker Desktop when you sign in") - grammary will NOT come back after a reboot' -ForegroundColor Yellow
  }
} catch {}

} finally { Pop-Location }
