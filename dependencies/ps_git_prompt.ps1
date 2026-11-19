# =============================================================================
# ps_git_prompt.ps1 - git-aware PowerShell prompt (Issue #18)
# =============================================================================
# What it is:
#   A first-party, dependency-free `prompt` function for PowerShell. It shows
#   `PS <path>` with the path in blue, appends the git branch in bold red (or
#   the short commit SHA on a detached HEAD), and shows no branch segment
#   outside a git work tree. Needs git >= 2.22 for `git branch
#   --show-current` (base image ships 2.43).
#
# How it is loaded:
#   NOT auto-loaded and NOT on PATH. This file is dot-sourced: consuming repos
#   opt in via a `postCreateCommand` one-liner that appends a dot-source line
#   for /usr/local/share/powershell/ps_git_prompt.ps1 to the user's $PROFILE
#   (created if absent; idempotent on re-run). See the README
#   ("Project-Specific Dependencies") for the one-liner.
#
# PSReadLine history fallback (Issue #18):
#   The image pre-creates the default PSReadLine history directory owned by
#   vscode, but a root-owned ~/.local can still appear after the build
#   (devcontainer host integration), making the default history path
#   unwritable. On load, the guard below probes the default history DIRECTORY
#   by creating and removing a temp file - never by checking the history file
#   itself, which is absent in the normal first-launch state. If the probe
#   fails, history is silently redirected to a direct child of $HOME. The
#   guard emits nothing on either branch and never touches PSReadLine
#   options unless the default history path is unwritable.
# =============================================================================

function prompt {
    $e = [char]27
    # Gate all git detection on real work-tree membership: bare repos report
    # a current branch too (HEAD points at one), but have no work tree, so
    # they must render no branch segment.
    $branch = $null
    if ((git rev-parse --is-inside-work-tree 2>$null) -eq 'true') {
        $branch = git branch --show-current 2>$null
        if (-not $branch) { $branch = git rev-parse --short HEAD 2>$null }   # detached HEAD
    }
    $out = "PS $e[34m$($PWD.Path)$e[0m"
    if ($branch) { $out += " $e[1;31m($branch)$e[0m" }
    "$out> "
}

# --- PSReadLine history-path fallback ----------------------------------------
# Silent on both branches: default path writable -> no change, no output;
# default path unwritable -> redirect to $HOME/.ps_readline_history.txt.
# Anything that throws inside the scriptblock below is swallowed - nothing
# reaches the console. The scriptblock scope keeps every guard variable out
# of the caller's session (dot-sourcing otherwise runs in caller scope).
# NOTE: $PROFILE runs BEFORE the console host imports PSReadLine, so a bare
# Get-Module check here sees nothing in interactive sessions and the guard
# would silently never run. Force-import when running in a console host
# (idempotent - the host reuses the loaded module). On Linux every pwsh
# session reports UserInteractive+ConsoleHost, so a non-interactive
# dot-source also runs the guard - harmless: it only probes the history
# dir and leaves options alone unless the probe fails.
& {
    $psReadLineModule = Get-Module -Name PSReadLine
    if (-not $psReadLineModule -and [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost') {
        Import-Module PSReadLine -ErrorAction SilentlyContinue
        $psReadLineModule = Get-Module -Name PSReadLine
    }
    if ($psReadLineModule) {
        $previousEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Stop'
            $historyDir = Split-Path -Parent (Get-PSReadLineOption).HistorySavePath
            $probe = Join-Path $historyDir ([System.IO.Path]::GetRandomFileName())
            $null = New-Item -Path $probe -ItemType File -Force
            # Rare accepted leak: if this Remove-Item fails (concurrent lock),
            # one empty probe file stays in the history dir - PSReadLine
            # ignores stray files, so we swallow rather than surface noise.
            Remove-Item -Path $probe -Force -ErrorAction SilentlyContinue
        } catch {
            # Default path unwritable: fall back to a direct child of $HOME.
            try {
                Set-PSReadLineOption -HistorySavePath (Join-Path $HOME '.ps_readline_history.txt')
            } catch {
                # $HOME unwritable too (uid-mismatch session): nothing left to
                # redirect to. PSReadLine self-suppresses its error after the
                # first report, so staying silent here is safe.
            }
        }
        $ErrorActionPreference = $previousEap
    }
}
