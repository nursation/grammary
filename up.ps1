<#
  Starts (or restarts) the grammary server in Docker with restart=unless-stopped,
  so it comes back by itself after a reboot (Docker Desktop must autostart).

  Credentials, in order of preference:
    1. CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY from the shell environment
    2. the same keys from .env next to this script (gitignored; recommended —
       run `claude setup-token` once and put CLAUDE_CODE_OAUTH_TOKEN=<token>
       there; docker compose reads .env by itself, so even a manual
       `docker compose up` keeps working). Do NOT put the token into
       ~/.claude/settings.json env block — that would silently downgrade every
       host Claude Code session to the inference-only token.
    3. the same keys from ~/.claude/settings.json env block (legacy fallback)
    4. last resort: host ~\.claude\.credentials.json is mounted read-only into
       the container

  Usage:
    .\up.ps1              start (build on first run)
    .\up.ps1 -Rebuild     force image rebuild
    .\up.ps1 -Down        stop and remove the container
#>
param(
  [switch]$Rebuild,
  [switch]$Down
)

$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {

# --- hydrate credentials into the process env (compose interpolates from it) --

# .env: compose reads it natively; loading it here too lets the fallback logic
# below see the same values
$envFile = Join-Path $PSScriptRoot '.env'
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
  docker compose -f docker-compose.yml -f docker-compose.hostlogin.yml down
  exit $LASTEXITCODE
}

$files = @('-f', 'docker-compose.yml')

if ([string]::IsNullOrEmpty($env:ANTHROPIC_API_KEY) -and
    [string]::IsNullOrEmpty($env:CLAUDE_CODE_OAUTH_TOKEN)) {
  $credFile = Join-Path $env:USERPROFILE '.claude\.credentials.json'
  if (Test-Path $credFile) {
    # compose wants forward slashes on Windows
    $env:GRAMMARY_CLAUDE_FILE = $credFile -replace '\\', '/'
    $files += @('-f', 'docker-compose.hostlogin.yml')
    Write-Host 'no CLAUDE_CODE_OAUTH_TOKEN found - mounting the host claude credentials (read-only) into the container' -ForegroundColor Yellow
    Write-Host 'cleaner setup: run "claude setup-token" once and put CLAUDE_CODE_OAUTH_TOKEN=<token> into .env next to this script'
  } else {
    Write-Host 'warning: no Anthropic credentials found at all - /fix will fail until you run "claude login" or "claude setup-token"' -ForegroundColor Red
  }
}

$composeArgs = @('compose') + $files + @('up', '-d')
if ($Rebuild) { $composeArgs += '--build' }
& docker @composeArgs
if ($LASTEXITCODE -ne 0) { throw 'docker compose failed' }

# --- wait for /health and sanity-check the result -----------------------------

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

Write-Host ("grammary is up: http://127.0.0.1:$port  model=" + $health.model) -ForegroundColor Green

if (-not $health.auth) {
  Write-Host 'warning: the container has NO Anthropic credentials - /fix will fail. Re-run .\up.ps1 (it wires them in); recreating the container with a bare "docker compose up" loses them.' -ForegroundColor Red
}

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
