# lilium-chat-v2 dev environment (podman) — PowerShell wrapper.
#
# The host has no Elixir toolchain — all Elixir work runs in the
# elixir:1.20-otp-29 container (docker-compose.yml).
#
# Usage:
#   .\scripts\dev.ps1 up [postgres|app]   # start services (default: all)
#   .\scripts\dev.ps1 down                # stop + remove containers
#   .\scripts\dev.ps1 logs [svc]          # tail logs (default: all)
#   .\scripts\dev.ps1 deps                # mix deps.get
#   .\scripts\dev.ps1 setup               # create + migrate dev DB
#   .\scripts\dev.ps1 server              # start app (mix phx.server) on :4000
#   .\scripts\dev.ps1 test [mix args...]  # run mix test
#   .\scripts\dev.ps1 psql                # psql shell into the dev DB
param(
    [Parameter(Position = 0)] [string] $Cmd = "help",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)] $Args
)

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

function Invoke-Compose([string[]] $ComposeArgs) {
    & podman compose @ComposeArgs
    if ($LASTEXITCODE -ne 0) { throw "podman compose failed ($LASTEXITCODE)" }
}

switch ($Cmd) {
    "up" {
        $svc = if ($Args -and $Args[0]) { $Args[0] } else { "" }
        if ($svc) { Invoke-Compose @("up", "-d", $svc) } else { Invoke-Compose @("up", "-d") }
    }
    "down" { Invoke-Compose @("down") }
    "logs" {
        $svc = if ($Args -and $Args[0]) { $Args[0] } else { "" }
        if ($svc) { Invoke-Compose @("logs", "-f", $svc) } else { Invoke-Compose @("logs", "-f") }
    }
    "deps" { Invoke-Compose @("run", "--rm", "app", "mix", "deps.get") }
    "setup" {
        Invoke-Compose @("up", "-d", "postgres")
        Invoke-Compose @("run", "--rm", "app", "mix", "ecto.setup")
    }
    "server" {
        Invoke-Compose @("up", "-d", "postgres")
        Invoke-Compose @("up", "app")
    }
    "test" {
        Invoke-Compose @("up", "-d", "postgres")
        $mixArgs = @("run", "--rm", "app", "mix", "test")
        if ($Args) { $mixArgs = $mixArgs + $Args }
        Invoke-Compose $mixArgs
    }
    "psql" { Invoke-Compose @("exec", "postgres", "psql", "-U", "chat", "-d", "lilium_chat_dev") }
    default {
        Write-Host "Usage: dev.ps1 <up|down|logs|deps|setup|server|test|psql> [args]"
    }
}
