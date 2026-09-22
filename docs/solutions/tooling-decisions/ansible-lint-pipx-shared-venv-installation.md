---
title: "Installing ansible-lint into Ansible's pipx shared venv"
module: "Dockerfile Ansible installation (pipx shared venv)"
date: "2026-09-22"
problem_type: "tooling_decision"
component: "tooling"
severity: "medium"
track: "knowledge"
applies_when:
  - "Adding a CLI tool into an existing pipx venv in a Dockerfile"
  - "Exposing a pipx-managed tool on PATH when pipx creates no bin link for it"
  - "Installing a package whose dependency constraints overlap packages already present in a shared pipx venv"
  - "Bumping the Ansible major version in the DevOps-Toolbox image (ansible-lint must move in lockstep)"
symptoms:
  - "ansible-lint installed via pipx runpip produces no executable on PATH (no PIPX_BIN_DIR link is created)"
  - "pip silently upgrades existing shared-venv packages to satisfy a new package's constraints, warning only and exiting 0"
root_cause: "missing_tooling"
resolution_type: "tooling_addition"
related_components:
  - "development_workflow"
tags:
  - "ansible-lint"
  - "pipx"
  - "shared-venv"
  - "docker"
  - "dependency-drift"
  - "ansible"
  - "build-guard"
  - "devops-toolbox"
---
# Adding ansible-lint to a pipx-based Ansible image (shared venv, not a separate one)

## Context

The DevOps-Toolbox image installs Ansible through pipx into an isolated virtualenv (`pipx install ansible==13.5.0`), with Galaxy collections and supporting Python packages baked in at build time. Ansible linting was the missing piece: playbooks and roles consumed by the image had no enforcement of best-practice rules, and `ansible-lint` was not present at all.

The obvious install path — `pipx install ansible-lint` — creates a *second* isolated venv with its own `ansible-core` dependency. That risks lint and runtime disagreeing about Ansible semantics, and roughly doubles the Ansible footprint in the image.

The version math had to be checked before choosing the shared-venv route. Ansible 13.5.0 pins `ansible-core~=2.20.4`; ansible-lint 26.8.0 requires `ansible-core>=2.16.19,!=2.17.*`. Those constraints are compatible: the existing venv's `ansible-core` satisfies ansible-lint's requirement, so lint can live in the same venv as runtime without a resolver conflict. Both `ansible-lint --version` and `ansible --version` in the built image report core 2.20.9, and the `ansible` package itself stays at 13.5.0 — confirming pip did not touch it.

## Guidance

Install the companion tool into Ansible's **existing** pipx venv with `pipx runpip`, not as a separate `pipx install`:

- `pipx runpip ansible install` is raw `pip` executed *inside* the venv, so the package shares one `ansible-core` with runtime.
- Pin the version with an `ARG` declared directly above the install block (the repo's layer-cache convention — changing one tool's version only invalidates layers below it).
- **Freeze the venv's resolved package versions to a constraints file before the install, and run the install under `-c`** — `pipx runpip ansible freeze > /tmp/ansible-venv-constraints.txt`, then `pipx runpip ansible install -c /tmp/ansible-venv-constraints.txt ansible-lint==${ANSIBLE_LINT_VERSION}`. This is the guard against silent resolver drift: every existing package is held at its frozen version, so pip cannot quietly upgrade a shared dependency to satisfy the new package's constraints. If the combination is unsatisfiable, the install fails the build with `ResolutionImpossible` instead of exiting 0 with warnings.
- Append `pipx runpip ansible check` to the **same** `RUN` as a secondary check. It validates that the *installed* packages' declared metadata is mutually satisfiable, and fails the build on broken or unsatisfiable installed metadata; on success it prints `No broken requirements found.` It does not read the repo's requirements files (they are not in the image at that point), so range enforcement against those pins belongs to the constraints freeze, not to this check.
- Create the CLI entry point manually with a symlink — `pipx runpip` exposes no binaries. Link the path derived from `PIPX_HOME=/usr/local/pipx`, which does not embed a Python version and therefore stays stable across base-image updates: `/usr/local/pipx/venvs/ansible/bin/ansible-lint` → `/usr/local/bin/ansible-lint`.
- Run `ansible-lint --version` in the same `RUN` so a broken install or wrong link fails the build immediately rather than at first use.

Final `Dockerfile` block (placed immediately after the `python-ansible-requirements` block):

```dockerfile
ARG ANSIBLE_LINT_VERSION=26.8.0

RUN pipx runpip ansible freeze > /tmp/ansible-venv-constraints.txt \
    && pipx runpip ansible install \
        -c /tmp/ansible-venv-constraints.txt \
        ansible-lint==${ANSIBLE_LINT_VERSION} \
    && pipx runpip ansible check \
    && ln -s /usr/local/pipx/venvs/ansible/bin/ansible-lint /usr/local/bin/ansible-lint \
    && ansible-lint --version \
    && (grep -q 'PYTHON_ARGCOMPLETE_OK' /usr/local/pipx/venvs/ansible/bin/ansible-lint \
        || echo "ansible-lint: no argcomplete marker in entry script (no automatic completion)") \
    && rm /tmp/ansible-venv-constraints.txt
```

Maintenance rule: ansible-lint officially tracks the last two major Ansible releases. Every Ansible major bump therefore requires a lockstep `ANSIBLE_LINT_VERSION` bump; this coupling is recorded in the repo's `CLAUDE.md` so version updates are never done independently.

## Why This Matters

**One ansible-core for lint and runtime.** With a separate `pipx install ansible-lint` venv, pip would resolve ansible-lint's `ansible-core` independently — possibly a different minor version than the runtime's. ansible-lint parses and partially evaluates playbooks using core modules, so a core version mismatch produces false findings (rules complaining about syntax the runtime accepts) or missed findings (lint tolerating patterns the runtime rejects). The shared venv eliminates the class of bug by construction.

**Smaller image.** A second venv duplicates `ansible-core` and its dependency tree. Injecting into the existing venv adds only ansible-lint and its delta deps.

**The `pipx runpip` CLI trap.** `pipx install` and `pipx inject` register entry points and create links in `PIPX_BIN_DIR`. `pipx runpip` does neither — it is literally pip operating inside the venv. Without the manual symlink, ansible-lint is installed but invisible on `PATH` for every user, and the failure only surfaces the first time someone runs the command. The symlink target deliberately avoids embedding a Python version, and `/usr/local/bin` is on `PATH` for both root and the non-root `vscode` user, so one link serves all users.

**The silent resolver-drift trap.** Adding a package to a shared venv can force pip to *upgrade packages already pinned* — here, the Azure collection requirements and `python-ansible-requirements.txt` pins — to satisfy the new package's constraints. Critically, pip reports these as warnings and exits 0; only `ResolutionImpossible` fails the build. So the Docker build can succeed while the image's Ansible venv quietly drifts out of compliance with its own declared requirements, and the breakage appears later at runtime as an import error or behavioral change. The constraints file — the venv's resolved versions frozen before the install and passed to it via `-c` — is what converts that drift into a build failure: every existing package is held at its frozen version, so a forced upgrade becomes an unsatisfiable resolution and pip exits with `ResolutionImpossible`. `pipx runpip ansible check` in the same `RUN` is retained as a secondary check of installed-metadata consistency.

**Known limitation (accepted):** the ansible-lint entry script lacks the `PYTHON_ARGCOMPLETE_OK` marker, so despite the image's global argcomplete activation, `ansible-lint` gets no shell completion. This is cosmetic; the build-time `grep` documents it explicitly rather than letting it surface as a surprise.

## When to Apply

- Adding a tool to an image where the parent application is pipx-managed and the tool is built on the same shared dependency (ansible-lint on `ansible-core`; the same pattern applies to other Ansible-ecosystem tooling such as `ansible-dev-tools` components).
- The tool's dependency constraints are verified compatible with the venv's current pins before choosing the shared-venv route — check the tool's published `ansible-core` requirement against the `ansible` package's core pin.
- Use a **separate** `pipx install` venv instead when the constraints conflict and cannot be reconciled, or when the tool would force upgrades to runtime-critical packages — under the constraints freeze, either situation fails the build (`ResolutionImpossible`) rather than shipping. Isolation beats sharing when sharing means breakage; the constraints freeze is the arbiter.
- Also applies when updating either package: after any bump of `ANSIBLE_VERSION` or `ANSIBLE_LINT_VERSION`, the constraints freeze re-resolves the venv under the new requirement set and `pipx runpip ansible check` re-validates the installed metadata — with the lockstep-coupling rule still applying (ansible-lint tracks the last two Ansible majors).

## Examples

**Failure modes the guard catches.** With the install running under the frozen constraints file, a resolver drift — say ansible-lint requiring a newer `pyyaml` than a pinned collection dep allows, or an upgrade breaking an azure-collection requirement — fails the build with `ResolutionImpossible` instead of silently producing a drifted image. Without the constraints, the same install exits 0 with a warning and the drift ships; `pipx runpip ansible check` afterwards only validates installed-metadata consistency and cannot catch it.

**Behavioral verification (performed on the built image, all passing):**

- `docker build` exits 0.
- Both root and the non-root `vscode` user run `ansible-lint --version` → 26.8.0 (symlink works for all users).
- `ansible --version` → core 2.20.9, `ansible` package still 13.5.0 (runtime untouched).
- A playbook with an unnamed task exits 2 citing `name[missing]` / `name[play]`; a clean playbook exits 0 — lint actually enforces rules, not just installs.
- `pipx runpip ansible check` → `No broken requirements found.` (installed-metadata consistency — a secondary check; range enforcement was the constraints freeze at install time).

**What a wrong install would look like (for contrast).** `pipx install ansible-lint` alone: builds fine, but `pipx list` shows two venvs with potentially different `ansible-core` versions, and `ansible-lint --version` inside the container disagrees with `ansible --version` on the core version — the mismatch symptom this design exists to prevent. `pipx runpip ansible install ansible-lint==X` without the symlink: build passes, but `ansible-lint` is not on `PATH` for any user — `command not found` at first real use, discovered by whoever consumes the image rather than by CI.
