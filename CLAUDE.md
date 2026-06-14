# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A Docker image (Dev Container) that bundles pinned versions of DevOps tooling — Terraform, Packer, kubectl, Helm, Ansible, cloud CLIs, database clients, and Python/.NET SDKs. Published to Docker Hub as `taegost/devops-toolbox`. Consumers pull the image into their projects' `.devcontainer/devcontainer.json`.

## Build Commands

```bash
# Local build (needs .env file copied from .env.example)
cp .env.example .env
docker build \
  $(grep -v '^#' .env | grep -v '^$' | sed 's/^/--build-arg /') \
  -t devops-toolbox:local .

# CI build (multi-arch, no .env needed — ARGs read from Dockerfile defaults)
# Triggered by: push to main, semver tag, weekly cron, workflow_dispatch
# Defined in .github/workflows/build-and-push.yml
```

No test suite, no linter. The CI pipeline's PR build is the validation step — it builds (without pushing) to confirm the Dockerfile is valid.

## Architecture

### Dockerfile Design

**Base image:** `mcr.microsoft.com/devcontainers/base:ubuntu-24.04` — provides git, zsh, oh-my-zsh, curl, non-root `vscode` user, pipx.

**Version pinning pattern:** Each tool's `ARG VERSION` is declared directly above its install block, not grouped at the top. This is intentional — changing one tool's version only invalidates the Docker layer cache from that tool downward, not the entire build.

**Architecture handling:** `TARGETARCH` is set by Docker Buildx (`amd64` or `arm64`). Tools that use different arch naming (AWS CLI: `x86_64`/`aarch64`, gcloud: `x86_64`/`arm`) remap inline with shell conditionals.

**Install method priority:**
1. Direct binary download (most tools) — for exact version pinning
2. APT with version pin (Azure CLI only) — because it's a Python app with complex deps
3. pipx (Ansible, Python dev tools) — isolated virtualenvs, no dependency conflicts
4. Microsoft install script (.NET SDK) — needed for feature-band control beyond what APT offers

**Ansible setup:** Ansible is installed via pipx into an isolated venv. Collections (`dependencies/ansible-requirements.yml`) are baked in at build time. Supporting Python packages (`dependencies/python-ansible-requirements.txt`) are injected into Ansible's venv via `pipx runpip ansible install`. Azure collection deps are installed from the collection's own requirements file post-install.

**Shell completions:** Written to `/etc/bash_completion.d/` system-wide (not `~/.bashrc`) — available to all users without per-user config. Bash-completion loading is appended to `/etc/bash.bashrc`.

### Dependency Files

| File | Purpose | Version Strategy |
|---|---|---|
| `dependencies/ansible-requirements.yml` | Ansible Galaxy collections baked into image | `>=X,<Y` (compatible range, capped at next major) |
| `dependencies/python-ansible-requirements.txt` | Python packages injected into Ansible's venv | `~=X.Y.Z` (compatible release) |
| `dependencies/python-dev-requirements.txt` | Dev tools (ipython, pytest, black) via pipx | `==X.Y.Z` (exact pin) |

### CI/CD Pipeline

**File:** `.github/workflows/build-and-push.yml`

**Triggers:** push to main, semver tags (`v*.*.*`), PRs to main (build-only validation), weekly Monday 04:00 UTC cron, manual `workflow_dispatch`.

**Platforms:** `linux/amd64`, `linux/arm64` (via QEMU + Buildx).

**Tagging (via docker/metadata-action):**
- `latest` — every push to main + weekly rebuild
- `sha-<short>` — every build (traceability)
- `1.2.3`, `1.2`, `1` — when a `v1.2.3` Git tag is pushed (semver expansion)
- PR builds: no push, no tags

**Security:** Images are signed with Cosign against Sigstore/Fulcio public transparency log. Docker Hub README is synced automatically.

**Required secrets:** `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` (access token, not password), `DOCKERHUB_IMAGENAME`.

### Tag Validation

Two-stage guard against bad semver tags:
1. `Validate tag format` step — regex check that tag matches `vMAJOR.MINOR.PATCH`
2. `Verify semver tags were generated` step — confirms docker/metadata-action produced non-SHA tags

## Updating a Tool Version

1. Find the tool's `ARG` in the Dockerfile (directly above its install block)
2. Update the version value
3. Update the matching entry in `.env.example`
4. **MUST:** Stage changes and commit, but do NOT create a PR until the user confirms the Docker build succeeds locally. Wait for the user to smoke test before opening the PR.
5. After user approval, create the PR — CI validates the build
6. Merge to main, then tag a new semver release (`v1.2.3`) to publish versioned tags

`.env.example` is the quick-reference for current versions — it mirrors all Dockerfile ARGs with links to each tool's release page in comments.

## ABSOLUTE DIRECTIVE

- **NEVER create a PR for Dockerfile changes without the user first smoke-testing the Docker build locally.** The CI pipeline takes minutes; a local smoke build catches issues faster. Commit the changes, push the branch, but stop before opening the PR. Tell the user the branch is ready for smoke testing and provide the exact build command.

## Key Conventions

- No `weekly` tag — semantically identical to `latest`, would add noise
- `kubeseal` and `stern` version ARGs omit the `v` prefix (unlike other tools) because their GitHub release URLs use bare numbers
- `mariadb-client` comes from Ubuntu APT, not MariaDB Foundation repo — MariaDB 12.x lacks a stable version-addressable APT URL
- Azure Ansible collection Python deps are installed from the collection's own `requirements.txt` (only exists post-install), not pre-listed in `python-ansible-requirements.txt`
- `.dockerignore` excludes `.github`, `.devcontainer`, and README.md — the image doesn't need them
