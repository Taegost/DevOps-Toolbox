---
title: "feat: Add PowerShell git prompt function (opt-in)"
type: feat
status: pending
date: 2026-11-19
---

## Summary

Ship a first-party `ps_git_prompt.ps1` (the `prompt` function from Issue #18 — git branch, detached-HEAD short SHA, colored path) inside the image at a stable system path, wired in by consuming repos via `postCreateCommand` (opt-in, user decision). Fix the PSReadLine history error at build time by pre-creating the history directory owned by `vscode`, with a silent in-script fallback history path (keep-history-working, user decision). Document the `postCreateCommand` one-liner in README. No new ARG, no module dependency, no CI change. Smoke-test gated; PR only after explicit user approval.

## Problem Frame

Issue #18 (origin document): in PowerShell sessions the stock prompt loses the git-branch visibility bash/zsh users get from the base image's oh-my-zsh git plugin. Consumers whose repos open straight into PowerShell want a branch-aware prompt, installable per-repo via `postCreateCommand`. The issue supplies the exact `prompt` function to ship.

The issue also reports a first-session error: `Error reading or writing history file '/home/vscode/.local/share/powershell/PSReadLine/ConsoleHost_history.txt': Access to the path '/home/vscode/.local/share' is denied.` Image evidence (verified against the published image): `/home/vscode` is mode `750` owned by `vscode:vscode` and `.local` does not exist at build time — PSReadLine must create the entire `~/.local/share/powershell/PSReadLine` chain at first launch. The denied path naming `.local/share` (not `.local` itself) indicates `.local` existed at runtime but was not writable by the session — consistent with a root-owned `.local` created by devcontainer host integration between build and first shell; failure is also possible where the session's effective user cannot write into `$HOME` at all. The issue asks for a safe container fix if possible, else safe suppression.

## Requirements

**Prompt function**
- R1. `prompt` returns `PS <path>` with blue path, plus red `(branch)` when on a branch, red `(short-SHA)` on detached HEAD, and no branch segment outside a work tree — function content per the Issue #18 body
- R2. Script ships at a stable, arch-independent, world-readable system path; it is **not** auto-loaded — consuming repos opt in via `postCreateCommand` appending a dot-source line to PowerShell `$PROFILE` (creating `$PROFILE` if absent), and the documented one-liner is idempotent on re-run

**PSReadLine error**
- R3. History keeps working. Build pre-creates `~/.local/share/powershell/PSReadLine` with correct `vscode` ownership so first launch never mkdirs; if the default history path is still unwritable at runtime, the script silently redirects history to an alternate writable path (a direct child of `$HOME`) — no error output
- R4. First `pwsh` launch as `vscode` in a fresh container emits no PSReadLine error, and command history persists across sessions

**Documentation and repo hygiene**
- R5. README "Project-Specific Dependencies" gains the PowerShell prompt `postCreateCommand` example; "Repository Structure" tree gains the script under `dependencies/`; CLAUDE.md Key Conventions records the first-party-script pattern
- R6. No new `ARG`, no `.env.example` edit (first-party script, no upstream release), no CI workflow change, no posh-git/module dependency

**Process**
- R7. Smoke test (`docker build .`) passes and is reported before any PR; fresh-container acceptance covers R1–R4; PR opened only after explicit user approval (repo ABSOLUTE DIRECTIVE)

---

## Key Technical Decisions

- **Opt-in via `postCreateCommand` (user decision).** Script lives at a stable path; the consumer's `postCreateCommand` appends `. <path>` to `$PROFILE`. Alternative rejected: writing to the AllUsers profile (`/usr/local/pwsh/profile.ps1`) would apply the prompt to every session with no per-repo opt-out, against the issue's per-repo framing.
- **Source lives in `dependencies/ps_git_prompt.ps1`, baked to `/usr/local/share/powershell/ps_git_prompt.ps1` via `COPY`.** `dependencies/` is the established home for everything the Dockerfile COPYs into the image (`Dockerfile:252,274,514`) — first-party scripts included, so no new top-level directory is introduced and `.dockerignore`'s header claim ("explicit COPY from `dependencies/`, so only those files enter the image") stays true untouched. Target mirrors the `/usr/local/share/ca-certificates` precedent for shared data; not on `PATH` because it is dot-sourced, not executed.
- **Keep history working (user decision): build-time pre-creation, not `SaveNothing`.** A new Dockerfile tail block (before `USER vscode`) creates `/home/vscode/.local/share/powershell/PSReadLine` and chowns it to `vscode`. Tail placement follows the PG18 precedent: zero layers below to invalidate on introduction. Ownership — not just existence — is the point: a root-owned directory would reproduce the exact reported error.
- **Script-level fallback for defense in depth.** The consumer's runtime, not the image, decides whether `.local` stays writable (a root-owned `.local` can appear after build). At load, the script probes the default history path and, if unwritable, redirects `-HistorySavePath` to a direct child of `$HOME` (always writable by its owner in the observed failure modes), wrapped so no error surfaces. This covers the root-owned-`.local` case the build-time fix cannot.
- **Script content carried from the issue essentially verbatim.** Its function already handles branch, detached HEAD, and non-git directories. Only additions: the history-path guard and a header comment. Base image git (2.43) supports `git branch --show-current`.
- **Acceptance in a container, not unit tests.** No test suite exists in this repo (CI PR build is the validation step); behavioral verification is the U4 fresh-container acceptance.

---

## Implementation Units

### U1. Dockerfile: pre-create PSReadLine history directory

- **Goal:** First `pwsh` launch finds `~/.local/share/powershell/PSReadLine` already present and owned by `vscode`, so PSReadLine never creates directories at runtime
- **Requirements:** R3, R4
- **Dependencies:** none
- **Files:** `Dockerfile` (new block after the PostgreSQL 18 client block, before `USER vscode`)
- **Approach:** `RUN mkdir -p /home/vscode/.local/share/powershell/PSReadLine && chown -R vscode:vscode /home/vscode/.local` with a banner comment recording the root cause (750 home, absent `.local`, PSReadLine's first-launch mkdir, runtime root-owned-`.local` failure mode) and pointing to U2's fallback for the residual case. Include an in-RUN ownership assertion (`stat -c '%U'` equals `vscode`) per the repo's in-RUN-assertion convention.
- **Patterns to follow:** Tail-block placement + banner style (PostgreSQL 18 client block, `Dockerfile:653-715`); in-RUN assertions (`psql --version | grep …`, `Dockerfile:711`)
- **Test scenarios:**
  - Build succeeds on the local `docker build .` smoke run
  - In the built image, `stat -c '%U' /home/vscode/.local/share/powershell/PSReadLine` reports `vscode`
- **Verification:** Image layer present with correct ownership; subsequent U4 runtime check confirms no error on first launch

### U2. Script `ps_git_prompt.ps1` + COPY into image

- **Goal:** The Issue #18 `prompt` function ships at `/usr/local/share/powershell/ps_git_prompt.ps1`, with the silent history-path fallback
- **Requirements:** R1, R2, R3, R6
- **Dependencies:** U1 (fallback probe exists because ownership fix cannot cover all runtime contexts; script can land in either order but acceptance assumes U1)
- **Files:** `dependencies/ps_git_prompt.ps1` (new), `Dockerfile` (COPY + readability, placed in the new tail area after U1's RUN and before `USER vscode`, so script edits invalidate only the COPY layer, not the ~590 lines of tool layers above)
- **Approach:** Script = issue's `prompt` function verbatim + header comment + guard: probe default PSReadLine history file writability; on failure redirect `-HistorySavePath` to a direct child of `$HOME`; all wrapped to emit nothing on either branch. Dockerfile `COPY dependencies/ps_git_prompt.ps1 /usr/local/share/powershell/` with a short banner (what it is, why not on PATH, Issue #18 reference).
- **Patterns to follow:** Banner-comment style of every install block; `/usr/local/share/` location precedent (Azure PostgreSQL CAs block, `Dockerfile:645-647`)
- **Test scenarios** (executed during U4 acceptance; enumerated here so coverage is not invented later):
  - Dot-source in a git repo on a branch → `prompt` output contains `(branch-name)`
  - Detached HEAD (`git checkout <sha>`) → output contains `(short-sha)`
  - Non-git directory → output has path segment, no parenthesized segment
  - With default history path unwritable (simulate root-owned `.local`) → dot-source emits no error and history redirect takes effect; run two consecutive sessions in this mode — a command entered in the first is recalled in the second from the redirected history path
  - With default history path writable (the normal post-U1 state) and the guard loaded (opt-in session) → dot-source emits no output and `(Get-PSReadLineOption).HistorySavePath` still resolves to the default PSReadLine path (R3: redirect only when unwritable; silence on both branches)
  - Captured `prompt` output contains ANSI color codes for the blue path segment and the red branch/SHA segment (per R1), with `$PSStyle.OutputRendering` set to `ANSI` in the test session so colors survive capture
- **Verification:** Script present and readable at the baked path in the built image; scenarios above pass in U4

### U3. README: document the wiring

- **Goal:** Consumers can wire the prompt in by copying one example
- **Requirements:** R2, R5
- **Dependencies:** U2 (path is fixed there)
- **Files:** `README.md`, `CLAUDE.md` (Key Conventions line)
- **Approach:** Add a "PowerShell git prompt" example under "Project-Specific Dependencies" (README:140): a `postCreateCommand` `pwsh -NoProfile -Command` one-liner that creates `$PROFILE` if absent and appends the dot-source line only when not already present (idempotent, R2). Update the "Repository Structure" tree to add `dependencies/ps_git_prompt.ps1` (no new directory). Add a CLAUDE.md Key Conventions line recording the first-party-script pattern (`dependencies/` → `/usr/local/share/powershell/`, opt-in dot-source loading), following the PG18 plan's corpus-update precedent.
- **Test expectation: none — documentation only**
- **Verification:** One-liner executed twice inside the U4 `docker run` container (idempotency confirmed); the real devcontainer `postCreateCommand` recreate lifecycle is not exercised by U4

### U4. Smoke test + fresh-container acceptance

- **Goal:** Evidence that R1–R4 hold before any PR
- **Requirements:** R7
- **Dependencies:** U1, U2, U3
- **Files:** none (execution only)
- **Approach:** `docker build .` (ABSOLUTE DIRECTIVE smoke test) — report result. Then `docker run -it` as `vscode` (interactive TTY required — PSReadLine engages only in interactive sessions; a non-interactive check would pass vacuously): first `pwsh` launch with no PSReadLine error; a second session recalls the previous command (history persisted); U2's prompt scenarios; run the README one-liner twice → exactly one dot-source line in `$PROFILE`; then start a fresh `pwsh` session inside a git repo and confirm the branch-aware prompt is active via the `$PROFILE` dot-source on startup — the real consumer outcome, distinct from U2's direct dot-source. Non-opt-in containers keep the stock prompt (no auto-load).
- **Test scenarios:** all U2 scenarios plus: first `pwsh` launch as `vscode` in a fresh container emits no PSReadLine error (R4; confirms U1's build-time ownership fix); history persistence across sessions; one-liner idempotency; wired prompt active in a fresh session after the one-liner; stock prompt unchanged without opt-in
- **Verification:** Results reported to the user; PR opened only after explicit approval

---

## Scope Boundaries

- No posh-git or any external PowerShell module — the issue's function is first-party and dependency-free
- No AllUsers/auto-load wiring, no default-shell change to PowerShell
- No bash/zsh prompt work (base image already covers those)
- No CI workflow, `ARG`, or `.env.example` changes
- **Deferred to Follow-Up Work:** if a consumer context surfaces where all of `$HOME` is unwritable (uid-mismatch sessions — nothing under `$HOME` can work, including the fallback), an opt-in `SaveNothing` escape hatch could be added to the script; not built now, since PSReadLine self-suppresses the error after first report and no such case is observed

## Risks

- **Root-cause residual (consumer-side).** The exact runtime trigger of the original error lives in the consumer's devcontainer integration, not the image. Layered defense: absent-`.local` is covered unconditionally by the build-time fix; root-owned-`.local` is covered only in opt-in sessions (the script's fallback runs solely where the consumer dot-sourced it) — a non-opt-in session with a root-owned `.local` retains the error. A fully unwritable `$HOME` remains (see Deferred) with a once-per-session warning as the worst case — matching the issue's "or failing that, suppress it" fallback
- **`.dockerignore` drift.** `dependencies/` is already the COPY-source directory; if future edits ever excluded it wholesale, all four COPYs break loudly at build — acceptable failure mode, caught by smoke test
- **`$PROFILE` location variance.** PowerShell host-specific vs AllHosts profiles differ; the one-liner targets `$PROFILE`'s default resolution (CurrentUser, CurrentHost — `Microsoft.PowerShell_profile.ps1`), not `$PROFILE.CurrentUserAllHosts` — if consumers use nonstandard hosts, they adapt the example; documented choice, not a plan risk beyond noting it
