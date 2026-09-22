---
title: feat: Add ansible-lint
type: feat
status: completed
date: 2026-09-22
---

## Summary

Add ansible-lint 26.8.0 as a pinned tool — installed into Ansible's existing pipx virtualenv, CLI exposed system-wide, `.env.example` and README.md updated. Smoke-test gated; PR opened only after explicit user approval.

## Problem Frame

The image ships Ansible 13.5.0 with baked-in collections but no linter. Playbook linting is the standard companion workflow — consumers currently either run ansible-lint outside the container or install it ad hoc per project via `postCreateCommand`. Baking it in matches the toolbox's purpose: consistent pinned tooling across machines.

## Requirements

**Tool installation**
- R1. ansible-lint 26.8.0 installed into Ansible's pipx venv, sharing its single `ansible-core` 2.20.x (ansible 13.5.0 pins `~=2.20.4`)
- R2. `ansible-lint` command callable system-wide by all users, including non-root `vscode`
- R3. Version pinned via `ARG ANSIBLE_LINT_VERSION` directly above the install block (layer-cache convention)

**Documentation**
- R4. `.env.example` gains `ANSIBLE_LINT_VERSION=26.8.0` plus a PyPI link in the version reference comment block
- R5. README.md tool table gains an ansible-lint row next to Ansible
- R7. CLAUDE.md's Ansible setup paragraph records the venv injection, symlink exposure, and lockstep bump rule

**Process**
- R6. Smoke test (`docker build .`) passes before any PR; PR opened only after explicit user approval per repo ABSOLUTE DIRECTIVE

## Key Technical Decisions

- **Install target: Ansible's pipx venv via `pipx runpip ansible install`.** Single shared `ansible-core` (2.20.x, pinned by ansible 13.5.0 as `~=2.20.4`) satisfies ansible-lint 26.8.0's constraint `ansible-core!=2.17.*,>=2.16.19`. Avoids a duplicate ansible-core whose version could drift from the one running playbooks. Matches the existing runpip precedent used for the azure.azcollection requirements. Confirmed by user over an isolated `pipx install ansible-lint`.
- **CLI exposure: symlink `/usr/local/bin/ansible-lint` to `/usr/local/pipx/venvs/ansible/bin/ansible-lint`.** `runpip` is raw pip — it creates no `PIPX_BIN_DIR` links. `pipx inject` was considered and rejected because its app-exposure behavior varies across pipx versions. The symlink is deterministic and system-wide; it does not embed the Python version, so it is stable independent of `PYTHON_VERSION`.
- **Version handling: `ARG` + exact `==` pin.** ansible-lint is a tool, not a module-support library — it follows the ARG/.env.example convention, not the `~=` convention of `dependencies/python-ansible-requirements.txt` (whose stated scope is packages Ansible modules import).
- **Plain ansible-lint, not `ansible-dev-tools`.** Upstream recommends the bundle, but it also pulls molecule, ansible-navigator, and ansible-builder — outside the requested scope. Confirmed by user.
- **Placement: directly after the python-ansible-requirements block.** Ansible-ecosystem grouping; the install resolver then sees every package already injected into the venv.
- **No completion step.** No shell-completion mechanism verified for ansible-lint. The image's existing global argcomplete activation covers it automatically if its entry script carries the `PYTHON_ARGCOMPLETE_OK` marker — zero-cost grep check at implementation, nothing to add either way.

## Implementation Units

### U1. Add ansible-lint install block to Dockerfile

- **Goal:** ansible-lint 26.8.0 installed into Ansible's venv with system-wide CLI
- **Requirements:** R1, R2, R3
- **Dependencies:** none (block lands after existing Ansible-ecosystem blocks)
- **Files:** `Dockerfile`
- **Approach:** New block after the python-ansible-requirements block: header comment describing the tool with its URL and the shared-venv rationale, `ARG ANSIBLE_LINT_VERSION=26.8.0`, then one `RUN` that freezes the venv's resolved package versions to a constraints file (`pipx runpip ansible freeze`), runs `pipx runpip ansible install -c <constraints> ansible-lint==${ANSIBLE_LINT_VERSION}` so pip cannot silently upgrade any existing package (an unsatisfiable resolution fails the build), follows with `pipx runpip ansible check` as a secondary installed-metadata consistency check, symlinks the venv binary into `/usr/local/bin`, and smoke-checks `ansible-lint --version`. Optionally grep the entry script for the argcomplete marker (informational only).
- **Patterns to follow:**
  - Azure collection requirements block in `Dockerfile` for the `pipx runpip ansible install` shape
  - gcloud completion block in `Dockerfile` for symlinking into a system-wide location
  - General block structure: comment header → ARG → RUN with `--version` check
- **Test scenarios:**
  - Build the image; `ansible-lint --version` inside the container reports 26.8.0
  - Invoke `ansible-lint --version` as the non-root `vscode` user — verifies the symlink resolves on PATH outside root
  - Run `ansible-lint` on a minimal playbook containing a deliberate violation (task without a `name`) — exits non-zero citing the rule; a clean playbook passes — proves functional linting through the shared venv
  - `ansible-lint --version` and `ansible --version` report the same ansible-core version — the alignment property R1 claims, falsifiable from output both tools already print
  - After the install, `pipx runpip ansible check` exits clean and `ansible --version` still reports 13.5.0 — the azure requirements and `python-ansible-requirements.txt` tenants were not silently upgraded
- **Verification:** Built image passes all five scenarios above

### U2. Update .env.example, README.md, and CLAUDE.md

- **Goal:** Documentation reflects the new tool, its version pin, and the shared-venv maintenance rule
- **Requirements:** R4, R5, R7
- **Dependencies:** U1 (version finalized)
- **Files:** `.env.example`, `README.md`, `CLAUDE.md`
- **Approach:**
  - `.env.example`: add `ANSIBLE_LINT_VERSION=26.8.0` in the Infrastructure as code section before `ANSIBLE_VERSION` (alphabetical key order per dotenv-linter); add an `ansible-lint` line with its PyPI URL to the version reference comment block
  - `README.md`: add a tool table row directly after the Ansible row, same shape as existing rows
  - `CLAUDE.md`: extend the Ansible setup paragraph — ansible-lint is injected into the Ansible venv via `pipx runpip` and exposed by a manual `/usr/local/bin` symlink; Ansible major bumps require a lockstep `ANSIBLE_LINT_VERSION` bump
- **Patterns to follow:** Existing `.env.example` version reference entries; existing README tool table rows (`See [Dockerfile](./Dockerfile)` for version)
- **Test scenarios:**
  - `grep -v '^#' .env.example | grep -v '^$' | sed 's/^/--build-arg /'` emits `--build-arg ANSIBLE_LINT_VERSION=26.8.0` — confirms local-build passthrough
- **Verification:** Visual review of both files; build-arg passthrough check passes

### U3. Smoke test and approval-gated PR

- **Goal:** Validated build before review; PR only on explicit approval
- **Requirements:** R6
- **Dependencies:** U1, U2
- **Files:** none — validation and process unit
- **Approach:** Run the local smoke build (`docker build` with `.env` build args), execute U1's five scenarios against the built image, and report the results. Wait for explicit user approval before opening the PR; CI then validates the multi-arch build as usual.
- **Test expectation:** none — process/validation unit, no feature-bearing change
- **Verification:** Build exits zero and all five U1 scenarios pass; approval recorded in conversation before PR creation

## Scope Boundaries

### Deferred to Follow-Up Work

- `ansible-dev-tools` bundle components (molecule, ansible-navigator, ansible-builder)
- Pre-baked `.ansible-lint` config or lint profiles in the image (project-specific — belongs in consumer repos)
- Bumping other tool versions
- Pre-existing `.env.example` usage-comment typo (`--build-` instead of `--build-arg`) — one-word fix in a file U2 touches, left out of scope here

## Risks & Dependencies

- **Shared-venv dependency resolution.** ansible-lint brings black, yamllint, ruamel-yaml, jsonschema, referencing, and friends into a venv that already carries the azure collection requirements and `python-ansible-requirements.txt` pins. pip may silently upgrade those packages to satisfy ansible-lint — warning-only, exit 0; only unsatisfiable conflicts fail the build on their own. The freeze-plus-`-c` install in U1 closes this gap: every existing package is held at its frozen version, so a forced upgrade becomes an unsatisfiable resolution and fails the build (`ResolutionImpossible`) instead of shipping silently. The `pipx runpip ansible check` step is retained as a secondary installed-metadata consistency check.
- **Ansible support window.** ansible-lint tracks the last two major Ansible releases. A future Ansible major bump in this image requires a lockstep `ANSIBLE_LINT_VERSION` bump.
- **Symlink path stability.** `/usr/local/pipx/venvs/ansible/bin` derives from `PIPX_HOME` set in the Dockerfile — stable unless `PIPX_HOME` itself changes.

## Sources & Research

- PyPI `ansible-lint` JSON API — 26.8.0 latest (uploaded 2026-08-12), `requires_python >=3.10`, `ansible-core!=2.17.*,>=2.16.19`, no direct `ansible` dependency
- PyPI `ansible` 13.5.0 JSON API — `ansible-core~=2.20.4` (compatibility verified against the constraint above)
- ansible-lint install docs (`https://docs.ansible.com/projects/lint/installing/`) — pip/pipx are the supported methods; upstream notes unsupported installation methods are not guaranteed. Shared-venv injection is ordinary pip-into-venv semantics within that surface.
- `Dockerfile` — Azure requirements block (runpip pattern), gcloud completion block (symlink pattern), Ansible install block (venv layout)
- Research gap: pipx documentation (`pipx.pypa.io`) was unreachable at plan time; the `pipx inject` rejection in KTDs rests on the repo's established runpip precedent instead
