---
title: "Baking the Azure CLI ssh extension into a multi-user image with --system"
module: "Dockerfile Azure CLI extension installation (--system)"
date: "2026-09-25"
problem_type: "tooling_decision"
component: "tooling"
severity: "medium"
track: "knowledge"
applies_when:
  - "Baking an Azure CLI extension into an image that installs as root and ends as a non-root USER"
  - "Writing a new az extension add block in the DevOps-Toolbox Dockerfile"
  - "Deciding whether a tool install needs TARGETARCH remapping for linux/amd64 + linux/arm64 builds"
  - "Assessing supply-chain exposure of CLI-managed pip installs that offer no constraints hook"
  - "Bumping AZURE_CLI_VERSION or a pinned extension version (they have a coupled compatibility range)"
symptoms:
  - "az extension add succeeds during docker build, but the runtime user gets a command-group-not-found error for az ssh"
root_cause: "config_error"
resolution_type: "tooling_addition"
related_components:
  - "development_workflow"
tags:
  - "azure-cli"
  - "az-ssh-extension"
  - "docker"
  - "cli-extensions"
  - "system-install"
  - "multi-arch"
  - "supply-chain"
  - "devops-toolbox"
---
# Baking the Azure CLI ssh extension into a multi-user image with `az extension add --system`

## Context

The DevOps Toolbox image is a dev container consumed by many projects and users. It builds as root but ends as `USER vscode` — every interactive session runs as the non-root `vscode` user. Issue #11 asked that the Azure CLI `ssh` command group (`az ssh vm`, `az ssh config`) work out of the box at container start, instead of each user having to run `az extension add` themselves on first use.

The obvious install — `RUN az extension add --name ssh` — has a trap. `az extension add` defaults to a per-user path, `~/.azure/cliextensions`. During the build that resolves to **root's** home (`/root/.azure/cliextensions`). The build step exits 0, the layer commits, and nothing looks wrong — but the extension is invisible to the `vscode` user the image actually ships as.

Beyond the path question, four more decisions had to be made before the block was worth committing:

- how to pin the extension version and prove the result in a repo with no test suite (the CI build is the only validation step);
- whether the multi-arch build (`linux/amd64` + `linux/arm64` via QEMU/Buildx) needed `TARGETARCH` remapping for this tool;
- what the install does and does not guarantee about Python dependency resolution (supply chain);
- how the extension's version interacts with `AZURE_CLI_VERSION` bumps over time.

## Guidance

1. **Use `--system` for any extension baked into the image.** `--system` installs under the CLI's own Python lib path (`/opt/az/lib/python3.13/site-packages/azure-cli-extensions/ssh`) instead of `$HOME/.azure/cliextensions`. That path is part of the image, identical for every user, so the extension resolves no matter who runs `az`. This is the single flag that closes the root-installs-but-runs-as-vscode gap.

2. **Follow the repo's layer-cache convention.** Declare `ARG AZURE_SSH_EXTENSION_VERSION` directly above its install `RUN`, not grouped at the top of the Dockerfile, and place the block directly after the Azure CLI block it extends. Bumping the extension version invalidates only this layer and everything below it — not the whole build.

3. **Pin explicitly and assert inside the same `RUN`.** Pass `--version ${AZURE_SSH_EXTENSION_VERSION}` and verify in the same layer:
   - *version drift check*: `az extension show --name ssh --query version --output tsv | grep -qx "${AZURE_SSH_EXTENSION_VERSION}"` — if the index ever serves a different version than the ARG (or a future CLI change breaks the pin), the build fails instead of silently shipping different contents;
   - *command-group load check*: `az ssh vm --help > /dev/null` — the extension must not just install but actually load.
   
   Pass `--yes`: docker build has no TTY, and the extension add's interactive confirmation prompt would hang or fail the build.

4. **Verify as the runtime user, not root.** After a local build, the acceptance check is `docker run --rm -u vscode devops-toolbox:local az ssh vm --help` exiting 0. This is the only check that exercises the exact failure mode the block exists to prevent — an extension that installed into root's home.

5. **No `TARGETARCH` handling for pure-Python extensions.** The ssh extension ships as a pure-Python wheel, so one install covers both `linux/amd64` and `linux/arm64`. Contrast with the binary downloads elsewhere in the image: AWS CLI remaps `amd64`→`x86_64`, `arm64`→`aarch64`; gcloud remaps `amd64`→`x86_64`, `arm64`→`arm`. Arch remapping is only needed for native binaries — check what the artifact actually is before adding a conditional.

6. **Know the supply-chain limits — and disclose them.** `az extension add` pip-installs the extension with no `--no-deps` option, no constraints passthrough, and no digest or signature verification. Direct dependencies are pinned by the extension's own setup.py (`oschmod==0.3.12`, `oras==0.1.30`), but the transitive closure (bare `jsonschema`, and `requests` via oras) resolves from PyPI at every cold build — unpinned. The repo's Ansible venv install freezes its resolved set to a constraints file and installs under `-c` so nothing can silently upgrade; `az extension add` offers no equivalent hook. The mitigation available today is disclosure: state the unpinned-transitive-deps exposure in the plan's risk section when implementing, so the tradeoff is made consciously rather than assumed away.

7. **Treat the extension version and `AZURE_CLI_VERSION` as coupled.** The extension declares its supported core CLI range in Microsoft's extension index. An `AZURE_CLI_VERSION` bump that is incompatible with the pinned extension fails `az extension add` at build time — a broken `az ssh` cannot ship silently. Expect a bump of either ARG to put the other in scope.

## Why This Matters

The per-user-default failure mode is the worst kind: **silent at build time, broken at run time**. `az extension add` without `--system` exits 0 during the build, so CI passes and the image publishes; the first user to run `az ssh vm` gets a command-group-not-found error — in a container where the extension exists on disk but under `/root`, where they cannot reach it. Because every consumer project inherits the image, one wrong flag ships a broken tool to everyone, and the symptom surfaces far from its cause.

The in-RUN assertions convert three quiet failure modes into loud build failures: version drift, a broken command group, and CLI/extension incompatibility. Given this repo has no test suite and the CI build is the validation step, assertions inside the `RUN` are the only executable checks that will ever run for this tool.

On the supply-chain side, the unpinned transitive closure means two cold builds of an identical Dockerfile can produce images with different dependency contents if an upstream package releases in between. That is a reproducibility hole and a small tampering surface the Dockerfile cannot close itself. Documenting it means reviewers weigh the exposure when deciding whether to add an extension at all, and users know the guarantee level they are getting. The repo's own Ansible install (frozen constraints under `-c`) sets the local standard — the gap is worth naming wherever a tool cannot meet it.

## When to Apply

- Baking **any** Azure CLI extension into an image that installs as root and runs as another user — always with `--system`, never the default per-user path.
- Writing a new `az extension add` block in this Dockerfile — apply the ARG-above-RUN placement, `--version` pin, `--yes`, and both in-RUN assertions.
- Deciding whether a tool needs `TARGETARCH` remapping — check whether it ships as a pure-Python wheel (no) or a native binary (yes, remap inline like AWS CLI/gcloud).
- Assessing supply-chain exposure for CLI-managed pip installs — when the install command offers no constraints hook, disclose the unpinned transitive deps in the plan rather than assuming everything is pinned.
- Bumping `AZURE_CLI_VERSION` or an extension version — treat them as coupled; the extension's supported core range in Microsoft's index is the compatibility boundary, and the build will enforce it.

## Examples

**The install block as implemented (`Dockerfile:333-357`):**

```dockerfile
# -----------------------------------------------------------------------------
# Azure CLI ssh extension
# Adds the `ssh` command group (az ssh vm / az ssh config) out of the box (#11).
# Installed with --system because the image ends as USER vscode: the default
# per-user path (~/.azure/cliextensions) would land in root's home and be
# invisible to the vscode user. --system installs under the CLI's python lib
# path (/opt/az/...), which resolves for every user.
#
# Sits directly after the Azure CLI block it extends — version bumps
# invalidate only from this layer down. An AZURE_CLI_VERSION bump incompatible
# with the pinned extension fails the build here — a broken az ssh cannot
# ship silently.
# Pure-Python wheel (deps: oschmod==0.3.12, oras==0.1.30) — no TARGETARCH
# handling needed.
# -----------------------------------------------------------------------------
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

**Before / after — the wrong way vs the right way:**

```dockerfile
# BEFORE (broken): builds green, invisible to the runtime user
RUN az extension add --name ssh

# AFTER: system path, pinned, non-interactive, self-verifying
RUN az extension add \
        --name ssh --version ${AZURE_SSH_EXTENSION_VERSION} \
        --system --yes \
    && az extension show --name ssh --query version --output tsv \
        | grep -qx "${AZURE_SSH_EXTENSION_VERSION}" \
    && az ssh vm --help > /dev/null
```

**Post-build verification as the shipping user (the check that would have caught the naive install):**

```bash
docker run --rm -u vscode devops-toolbox:local az ssh vm --help    # exit 0
docker run --rm -u vscode devops-toolbox:local az extension list --output table
# ssh    2.0.9    ...    system
```

**The contrast — a constraints-pinned install (Ansible venv, for reference; `az extension add` cannot do this):**

```dockerfile
RUN pipx runpip ansible freeze > /tmp/constraints.txt \
    && pipx runpip ansible install -c /tmp/constraints.txt <pkgs>
```

The Ansible pattern freezes the resolved package set and installs under `-c`, so an upstream release cannot change what a rebuild produces. The `az extension add` route has no equivalent hook — direct deps are pinned by the extension's setup.py, transitive deps are not — which is exactly why the limitation is disclosed rather than left implicit. The decision is also recorded in `CLAUDE.md` under "Install method priority" item 5, and mirrors `.env.example` (`AZURE_SSH_EXTENSION_VERSION=2.0.9`).
