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
#   guard emits nothing on either branch, and is skipped entirely when
#   PSReadLine is not loaded (non-interactive sessions).
# =============================================================================

function prompt {
    $e = [char]27
    $branch = git branch --show-current 2>$null
    if (-not $branch -and (git rev-parse --is-inside-work-tree 2>$null)) {
        $branch = git rev-parse --short HEAD 2>$null   # detached HEAD
    }
    $out = "PS $e[34m$($PWD.Path)$e[0m"
    if ($branch) { $out += " $e[1;31m($branch)$e[0m" }
    "$out> "
}

# --- PSReadLine history-path fallback ----------------------------------------
# Silent on both branches: default path writable -> no change, no output;
# default path unwritable -> redirect to $HOME/.ps_readline_history.txt.
# Anything that throws inside either branch is swallowed below - nothing
# reaches the console.
if (Get-Module -Name PSReadLine) {
    $psGitPromptPreviousEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'
        $psGitPromptHistoryDir = Split-Path -Parent (Get-PSReadLineOption).HistorySavePath
        $psGitPromptProbe = Join-Path $psGitPromptHistoryDir ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -Path $psGitPromptProbe -ItemType File -Force
        Remove-Item -Path $psGitPromptProbe -Force -ErrorAction SilentlyContinue
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
    $ErrorActionPreference = $psGitPromptPreviousEap
}
