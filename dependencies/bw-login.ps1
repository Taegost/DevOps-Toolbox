# =============================================================================
# bw-login.ps1 - Bitwarden CLI login + unlock helper
# =============================================================================
# What it does:
#   One step: checks `bw status`, runs `bw login` interactively if the CLI is
#   unauthenticated, unlocks the vault, and sets $env:BW_SESSION in the
#   calling session. PowerShell twin of dependencies/bw-login.sh.
#
# How it is loaded:
#   NOT auto-loaded and NOT on PATH. Dot-source it - the PowerShell analog of
#   bash's eval "$(bw-login)": a child process cannot set its parent's
#   environment, so running the script normally would discard
#   $env:BW_SESSION on exit.
#     . /usr/local/share/powershell/bw-login.ps1
#
# FIDO2-only 2FA:
#   Password-based `bw login` is blocked for FIDO2-only accounts (the CLI
#   has no WebAuthn support), and the interactive API-key prompts of
#   `bw login --apikey` don't compose inside this generic flow - run
#   `bw login --apikey` manually first (it prompts for the personal API
#   key's client_id/client_secret, or reads BW_CLIENTID/BW_CLIENTSECRET
#   from your environment), then re-dot-source this script to unlock.
# =============================================================================

$bwStatus = (bw status | ConvertFrom-Json).status
switch ($bwStatus) {
    'unlocked' {
        Write-Host 'bw: vault already unlocked in this shell (BW_SESSION set) - nothing to do'
        return
    }
    'unauthenticated' {
        Write-Host 'bw: not logged in - starting interactive login'
        bw login
        $key = bw unlock --raw
    }
    'locked' {
        Write-Host 'bw: vault locked - unlock to get a session key'
        $key = bw unlock --raw
    }
    default {
        Write-Error "bw-login: unexpected bw status '$bwStatus' (expected unlocked, unauthenticated or locked)"
        exit 1
    }
}

if (-not $key) {
    Write-Error 'bw-login: unlock produced no session key'
    exit 1
}

$env:BW_SESSION = $key
