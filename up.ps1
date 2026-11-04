<#
  Starts (or restarts) the grammary server in Docker with restart=unless-stopped,
  so it comes back by itself after a reboot (Docker Desktop must autostart).

  The container signs in with its OWN long-lived token: CLAUDE_CODE_OAUTH_TOKEN
  from `claude setup-token` (valid for a year, covered by the subscription). The
  first run creates it: approve in the browser, paste the token the CLI prints,
  and it is saved to .env next to this script (gitignored; docker compose reads
  .env by itself, so even a bare `docker compose up` keeps it).

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

# `claude setup-token` (approved in the browser) -> the pasted token -> .env
function New-ContainerToken {
  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    throw 'the claude CLI is not on PATH - install Claude Code, then re-run .\up.ps1'
  }
  if ([Console]::IsInputRedirected) {
    throw 'creating the token needs an interactive terminal - run .\up.ps1 -SetupToken in one'
  }
  Write-Host 'Creating the container''s own Claude token (valid for a year): approve it in the browser window, then copy the sk-ant-oat01-... token the CLI prints.' -ForegroundColor Cyan
  & claude setup-token
  if ($LASTEXITCODE -ne 0) { throw 'claude setup-token failed - nothing saved' }
  $secure = Read-Host 'Paste the token (input is hidden)' -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim() }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  if ($token -notmatch '^sk-ant-oat\d+-\S+$') {
    throw 'that is not a setup-token (expected sk-ant-oat01-...) - nothing saved; run .\up.ps1 -SetupToken again'
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
