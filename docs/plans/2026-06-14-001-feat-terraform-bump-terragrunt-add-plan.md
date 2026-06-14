---
title: feat: Bump Terraform to 1.15.6 and add Terragrunt 1.0.8
type: feat
status: completed
date: 2026-06-14
---

## Summary

Bump Terraform from 1.14.8 to 1.15.6 and add Terragrunt 1.0.8 as a new tool with checksum verification, shell completions, and matching doc updates.

## Problem Frame

The image currently ships Terraform 1.14.8 (November 2025). Terraform 1.15.6 (June 2026) is the latest stable release. Terragrunt — a thin wrapper around Terraform/OpenTofu that provides state management, DRY configuration, and CLI ergonomics — is not currently available in the image despite being a common companion to Terraform in DevOps workflows.

---

## Requirements

- R1. Terraform version updated from 1.14.8 to 1.15.6 in Dockerfile and `.env.example`
- R2. Terragrunt 1.0.8 installed via direct binary download from GitHub releases
- R3. Terragrunt binary verified against published SHA256SUMS before installation
- R4. Terragrunt shell completions available system-wide via `/etc/bash_completion.d/`
- R5. README.md tool table updated: Terraform version reference, new Terragrunt row
- R6. New Terragrunt install block follows existing Dockerfile conventions: header comment describing the tool, in-line rationale comments, version pin as `ARG`, and a `--version` smoke test

---

## Key Technical Decisions

- **Checksum verification: yes.** Follows Packer's pattern (download SHA256SUMS, grep the expected hash, pipe to `sha256sum -c`). Most tools in this Dockerfile skip verification; Packer and now Terragrunt are the exceptions.
- **Install method: raw binary, not archive.** Terragrunt publishes a standalone binary alongside `.tar.gz` and `.zip` archives. Downloading the raw binary avoids an extraction step. This matches the kubectl install pattern.
- **Version ARG format: no `v` prefix.** `TERRAGRUNT_VERSION=1.0.8` (not `v1.0.8`). The `v` prefix is baked into the download URL pattern. This matches kubeseal and stern conventions.
- **Shell completions: `terragrunt --install-autocomplete`** per upstream docs. If this writes per-user files rather than system-wide, fall back to the `complete -C` pattern used by Packer and AWS CLI.

---

## Implementation Units

### U1. Bump Terraform version

- **Goal:** Update Terraform from 1.14.8 to 1.15.6
- **Requirements:** R1
- **Dependencies:** none
- **Files:** `Dockerfile`, `.env.example`
- **Approach:** Change the `TERRAFORM_VERSION` ARG in the Dockerfile and the matching line in `.env.example`. No other Terraform install block changes — the URL pattern (`releases.hashicorp.com`) and zip extraction are unchanged.
- **Patterns to follow:** Single-line version ARG change per the repo's update conventions documented in README.md
- **Test scenarios:**
  - Build the image locally and run `terraform version` — verifies the binary downloads, extracts, and reports 1.15.6
- **Verification:** `docker build` succeeds and `terraform version` inside the container reports 1.15.6

### U2. Add Terragrunt install block to Dockerfile

- **Goal:** Install Terragrunt 1.0.8 with checksum verification
- **Requirements:** R2, R3, R6
- **Dependencies:** none
- **Files:** `Dockerfile`
- **Approach:** Add a new install block after the Terraform block (logical grouping — both are HashiCorp-ecosystem IaC tools). Download the raw `terragrunt_linux_${TARGETARCH}` binary and the `SHA256SUMS` file. Verify the checksum, then `install -m 755` to `/usr/local/bin/terragrunt`. The block includes: header comment identifying the tool with a URL to its homepage, inline comments explaining each step, the `ARG TERRAGRUNT_VERSION` declaration, and a `terragrunt --version` smoke test.
- **Patterns to follow:**
  - Packer block for checksum verification shape (`SHA256SUMS` download, `grep` + `awk` for expected hash, `sha256sum -c`)
  - kubectl block for raw binary install (`install -m 755` rather than `chmod +x` after mv)
  - General block structure: comment header → ARG → RUN with cleanup → version check
- **Test scenarios:**
  - Build the image and run `terragrunt --version` — verifies the binary downloads, passes checksum verification, and reports 1.0.8
  - Build with a deliberately wrong checksum expectation to confirm the `sha256sum -c` gate fails the build
- **Verification:** `terragrunt --version` inside the container reports 1.0.8

### U3. Add Terragrunt shell completions

- **Goal:** Terragrunt tab completion available in bash sessions
- **Requirements:** R4
- **Dependencies:** U2 (binary must be installed first)
- **Files:** `Dockerfile`
- **Approach:** Run `terragrunt --install-autocomplete` during build. If this command writes to a per-user RC file rather than `/etc/bash_completion.d/`, fall back to the `complete -C` pattern: `echo "complete -C '$(which terragrunt)' terragrunt" > /etc/bash_completion.d/terragrunt`. The install docs show `touch ~/.bashrc` before running `--install-autocomplete`, so the fallback may be necessary.
- **Patterns to follow:** Terraform's `-install-autocomplete || true` for the primary approach; Packer's `complete -C` for the fallback
- **Test scenarios:**
  - After build, start a bash session in the container and type `terragrunt <TAB>` — verifies completions load without errors
- **Verification:** `complete -p terragrunt` returns a completion specification inside a container bash session

### U4. Update README.md and .env.example

- **Goal:** Documentation reflects the new and updated tools
- **Requirements:** R1, R5
- **Dependencies:** U1, U2 (versions must be finalized)
- **Files:** `README.md`, `.env.example`
- **Approach:**
  - `.env.example`: bump `TERRAFORM_VERSION` to 1.15.6, add `TERRAGRUNT_VERSION=1.0.8` in the Infrastructure as code section (near Terraform/Packer) with a release page link in the version reference comment block
  - `README.md`: add a Terragrunt row to the tools table (between Packer and kubectl, under "Infrastructure as code" grouping), add Terragrunt to the Repository Structure tree under `dependencies/` if any new dependency file is created (none expected — Terragrunt has no external Python/Ansible deps)
- **Patterns to follow:** Existing table rows use "See [Dockerfile](./Dockerfile)" for version reference
- **Test scenarios:**
  - `.env.example`: verify `grep -v '^#' .env.example | grep -v '^$' | sed 's/^/--build-arg /'` passes Terragrunt's ARG correctly to `docker build`
- **Verification:** Visual review of both files confirms correct versions, consistent formatting, and working build arg passthrough

---

## Scope Boundaries

### Deferred to Follow-Up Work

- Bumping other tools to their latest versions
- Adding Terragrunt-specific Ansible collections or Python packages (none currently needed)

---

## Risks & Dependencies

- **Terraform 1.14 → 1.15 minor bump:** HashiCorp maintains backward compatibility within 1.x. No breaking changes are expected in the CLI itself, but consumers should test their own Terraform configurations.
- **Terragrunt `--install-autocomplete` behavior:** The upstream docs show a `touch ~/.bashrc` prerequisite, which suggests the command may write per-user configuration. If so, the `complete -C` fallback in U3 handles this.

---

## Sources & Research

- Terraform releases: `https://releases.hashicorp.com/terraform/` — 1.15.6 confirmed via GitHub API
- Terragrunt releases: `https://github.com/gruntwork-io/terragrunt/releases` — v1.0.8 confirmed via GitHub API, SHA256SUMS and binary naming verified from release assets
- Terragrunt install docs: `https://terragrunt.gruntwork.io/docs/getting-started/install/` — `--install-autocomplete` for shell completions, raw binary + SHA256SUMS for verification
- Packer install block in `Dockerfile:159-172` — checksum verification pattern to mirror
- kubectl install block in `Dockerfile:285-291` — raw binary install pattern to mirror
