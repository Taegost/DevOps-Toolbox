---
title: feat: Add Azure CLI ssh extension
type: feat
status: completed
date: 2026-09-25
---

## Summary

Bake the Azure CLI `ssh` extension (2.0.9) into the image so `az ssh vm` / `az ssh config` work out of the box — installed system-wide (`--system`) so it survives the `USER vscode` switch, pinned via `ARG`, verified in-build, with the `.env.example` mirror updated. Smoke-test gated; PR (which closes #11) opened only after explicit user approval.

## Problem Frame

`az ssh` is used routinely to remote into Azure VMs after creation. The command group ships as an extension — `az` does not include it — so consumers must run `az extension add --name ssh` manually in every container session. Issue #11 requests the extension be added automatically. Baking it in matches the toolbox's purpose: consistent pinned tooling without per-project setup steps.

## Requirements

**Tool installation**
- R1. `ssh` extension 2.0.9 installed system-wide via `az extension add --system`, available to all users including the non-root `vscode` user the image ends as
- R2. Version pinned via `ARG AZURE_SSH_EXTENSION_VERSION` declared directly above the install block (layer-cache convention)
- R3. In-build verification: the installed extension version asserts equal to the pin, and `az ssh vm --help` proves the command group registers and loads

**Documentation**
- R4. `.env.example` gains `AZURE_SSH_EXTENSION_VERSION=2.0.9` in the "Cloud cli tools" group, plus a version-reference link for the extension's release history
- R5. `.env.example` version-reference header gains the Azure CLI releases link (one of several tools currently missing a version-reference link — this plan adds only the Azure CLI and `az ssh ext` entries)

**Process**
- R6. Smoke test (`docker build .`) passes before any PR; PR body contains `Closes #11`; PR opened only after explicit user approval per repo ABSOLUTE DIRECTIVE

## Key Technical Decisions

- **`--system` install, not default per-user.** The build runs as root but the image ends as `USER vscode` (Dockerfile). The default extension path (`~/.azure/cliextensions`) would land in root's home and be invisible to the vscode user. `--system` installs under the CLI's python lib path (`/opt/az/...`), which the apt-installed CLI resolves for every user.
- **Placement: directly after the Azure CLI block.** The extension collocates with the tool it extends. The one-time insertion rebuilds the layers below it (AWS CLI onward); future extension version bumps invalidate only from the extension layer down — the isolation property the ARG-per-block convention exists for.
- **Pin via `--version`.** Matches the repo's pin-everything philosophy. Previously published versions stay resolvable in Microsoft's extension index, so the pin does not rot when 2.0.10 ships; upgrading is a deliberate ARG bump mirrored in `.env.example`. The pin covers the extension wheel and its direct deps only — see Risks for the unpinned transitive closure.
- **No lockstep rule with `AZURE_CLI_VERSION`.** Unlike the ansible-lint/Ansible pairing, no coupled version window exists. Layer order guarantees the extension reinstalls against a new CLI on an `AZURE_CLI_VERSION` bump; if that new CLI is incompatible with the pinned extension, `az extension add` fails the build at this step — a broken `az ssh` cannot ship silently.
- **`--yes` on the install.** `docker build` has no TTY; the flag guarantees non-interactive completion.
- **No TARGETARCH handling.** The extension itself is a pure-Python wheel (deps: `oschmod==0.3.12`, `oras==0.1.30`) — one install covers amd64 and arm64. (Transitive closure resolves per-arch from PyPI — see Risks; arch-independence conclusion unchanged.)
- **No README or docs/solutions change.** The extension is a facet of Azure CLI, not a new tool; the README table row already defers to the Dockerfile. The one non-obvious bit (`--system` for the vscode switch) is a single documented flag — the Dockerfile block comment captures the rationale in place.

## Implementation Units

### U1. Add ssh extension install block to Dockerfile

- **Goal:** `az ssh` command group present and loadable for all users at image start
- **Requirements:** R1, R2, R3
- **Dependencies:** none (block lands directly after the existing Azure CLI block)
- **Files:** `Dockerfile`
- **Approach:** New block after `ENV AZURE_CORE_COLLECT_TELEMETRY=false` (line 331), before the AWS CLI banner. Comment banner in repo style explaining the `--system` rationale, layer/cache note, and the fail-loud incompatibility property; then:

  ```dockerfile
  ARG AZURE_SSH_EXTENSION_VERSION=2.0.9

  RUN az extension add \
          --name ssh \
          --version ${AZURE_SSH_EXTENSION_VERSION} \
          --system \
          --yes \
      && az extension show --name ssh --query version --output tsv \
          | grep -qx "${AZURE_SSH_EXTENSION_VERSION}" \
      && az ssh vm --help > /dev/null
  ```

- **Patterns to follow:** Azure CLI block (`Dockerfile:307-331`) for banner style and version-check-in-RUN; every block's ARG-directly-above-RUN layout
- **Test scenarios:**
  - Build succeeds; the extension RUN's embedded assertions pass (version equals pin, command group loads)
  - `az extension list --output table` in the built container reports `ssh  2.0.9`
  - `az ssh vm --help` exits zero as the non-root `vscode` user — verifies the `--system` placement survives `USER vscode`
  - `az extension list --query "[?name=='ssh'].path" --output tsv` shows a path under `/opt/az/...` — proves system-dir placement, not a per-user install
- **Verification:** Built image passes all four scenarios above

### U2. Update .env.example

- **Goal:** Version pin and release references mirrored per repo convention
- **Requirements:** R4, R5
- **Dependencies:** U1 (version finalized)
- **Files:** `.env.example`
- **Approach:**
  - Version-reference header: add `Azure CLI: https://github.com/Azure/azure-cli/releases` and `az ssh ext: https://github.com/Azure/azure-cli-extensions/blob/master/src/ssh/HISTORY.md` after the PostgreSQL line
  - "Cloud cli tools" group: add `AZURE_SSH_EXTENSION_VERSION=2.0.9` after `AZURE_CLI_VERSION=2.85.0` (alphabetical order)
- **Patterns to follow:** Existing version-reference entries (URL column aligned); existing group key ordering
- **Test scenarios:**
  - `grep -v '^#' .env.example | grep -v '^$' | sed 's/^/--build-arg /'` emits `--build-arg AZURE_SSH_EXTENSION_VERSION=2.0.9` — confirms local-build passthrough
- **Verification:** Visual review; build-arg passthrough check passes

### U3. Smoke test and approval-gated PR

- **Goal:** Validated build before review; PR only on explicit approval
- **Requirements:** R6
- **Dependencies:** U1, U2
- **Files:** none — validation and process unit
- **Approach:** Run the local smoke build using the existing `.env` build args (new ARG has a Dockerfile default, so the current `.env` builds unmodified). Execute U1's container scenarios against `devops-toolbox:local`. Report results. Wait for explicit user approval before opening the PR to `main` with `Closes #11` in the body; CI's multi-arch PR build is the final gate.
- **Test expectation:** none — process/validation unit, no feature-bearing change
- **Verification:** Build exits zero; all U1 scenarios pass; approval recorded in conversation before PR creation

## Scope Boundaries

### Deferred to Follow-Up Work

- README mention of the bundled extension (discoverability nice-to-have; table row already defers to Dockerfile)
- Other Azure CLI extensions (e.g. `connectedmachine`, `azure-devops`) — not requested
- Any `AZURE_CLI_VERSION` bump — independent change
- docs/solutions entry — fails the non-trivial-learning bar (single documented flag; rationale lives in the Dockerfile comment)

## Risks & Dependencies

- **Extension index availability.** `az extension add --version` fetches the index and wheel from Microsoft's hosted index, and pip resolves the extension's dependencies from PyPI — both hosts must be reachable. Same network-dependency class as every curl download already in the Dockerfile; an outage fails loudly at this RUN step.
- **Unpinned transitive dependencies.** `az extension add` pip-installs the extension with no `--no-deps` and no constraints hook, and `oras==0.1.30` requires bare `jsonschema` and `requests` — so every cold build (including the weekly cron) resolves whatever PyPI serves that day and root-installs it under `/opt/az`. The ARG pin governs the extension wheel and direct deps only; the transitive closure is unpinned, and `az extension add` exposes no digest/signature verification. This is the same defect class the Ansible venv constraints freeze guards against; `az extension add` offers no constraints passthrough, so disclosure is the available mitigation.
- **One-time layer-cache rebuild.** Inserting the block above ~20 later tool layers invalidates them once on the introducing commit; every subsequent build caches normally.
- **Future incompatibility is loud, not silent.** An `AZURE_CLI_VERSION` bump that the pinned extension does not support fails the build at the extension step (extension declares its supported core range in the index).

## Sources & Research

- Issue #11 — `[FEATURE] Add ssh extension to az cli` (request and scope)
- Microsoft Learn, `az extension` reference (azure-cli-latest, checked 2026-09-25) — `--version` ("The specific version of an extension"), `--system` ("Use a system directory for the extension. Default path is azure-cli-extensions folder under the CLI running python environment lib path"), documented examples for both
- `Azure/azure-cli-extensions` `src/ssh/setup.py` (`VERSION = "2.0.9"`, deps `oschmod==0.3.12`, `oras==0.1.30`) and `src/ssh/HISTORY.md` (2.0.9 latest, checked 2026-09-25) — version pin and pure-Python/arch-independent confirmation
- `Dockerfile` — Azure CLI block (lines 307-331) for banner and RUN shape; `USER vscode` (line 580) driving the `--system` decision
- `.env.example` lines 16-27 (version-reference header) and 29-33 ("Cloud cli tools" group)
- CLAUDE.md — ARG-per-block convention, `.env.example` mirror rule, smoke-test ABSOLUTE DIRECTIVE
