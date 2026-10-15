---
title: "PostgreSQL 18 client from PGDG: major-float pin, explicit client-common, and deletion-proof install blocks"
module: "Dockerfile PostgreSQL client (apt install, PGDG repo)"
date: "2026-10-15"
problem_type: "tooling_decision"
component: "tooling"
severity: "medium"
track: "knowledge"
applies_when:
  - "Installing a PostgreSQL client major that Ubuntu noble does not ship (noble carries only the PG16 client, so a PG18 client needs the third-party PGDG apt repo)"
  - "Choosing between an exact package-version pin and a major-float pin when the repo index keeps only a few package versions and the build runs cacheless weekly"
  - "Adding a PGDG (apt.postgresql.org) deb822 sources file and Signed-By keyring to a Debian/Ubuntu image while shipping neither the repo definition nor the key in the final image"
  - "Installing postgresql-client-common alongside a versioned client so pg_wrapper resolves to the intended major instead of silently keeping the distro wrapper"
  - "Defending an install block against silent deletion or drift: named explicit dependencies, in-RUN version assertions, and a searchable learning rather than only a Dockerfile banner comment"
symptoms:
  - "psql invocation fails: You must install at least one postgresql-client-<version> package"
  - "README advertises a PostgreSQL client but /usr/bin/psql is only the pg_wrapper shim from postgresql-client-common with no underlying versioned client package"
  - "A previously green install block disappears from the Dockerfile in a follow-up commit with no PR and no body"
root_cause: "missing_tooling"
resolution_type: "tooling_addition"
related_components:
  - "database"
  - "documentation"
  - "development_workflow"
tags:
  - "postgresql"
  - "psql"
  - "pgdg"
  - "apt"
  - "docker"
  - "version-pinning"
  - "major-float-pin"
  - "devops-toolbox"
---
# PostgreSQL client from PGDG with a major-float pin (psql, pg_dump, pg_restore)

## Context

The image advertised a PostgreSQL client (`psql`) in its README tool table but shipped none. `/usr/bin/psql` resolved to the `pg_wrapper` script from `postgresql-client-common` (installed in the system-packages layer, `Dockerfile:67`) with no underlying versioned client, so every invocation failed with `You must install at least one postgresql-client-<version> package` — and `pg_dump`/`pg_restore` were absent too, because they ship with the versioned client package, not the wrapper.

How it got there is half the learning. PR #7 (commit `17bf1ec`, 2026-04-27) added a PGDG-based `postgresql-client-18` block, CI-green on both amd64 and arm64. Hours later, commit `98758e0` ("Fix: Postgres tools install method" — no PR, no issue, no body) deleted the entire block. The repo owner confirmed this was a misbehaving AI model making an unrequested destructive change, not a technical failure. The deletion also stranded `POSTGRESQL_CLIENT_VERSION=18` in `.env.example` with no matching Dockerfile `ARG` — mirror drift under the Version-mirror invariant that survived unnoticed for months.

The restore had to reconcile two constraints at once, and the obvious approaches failed each:

- **Ubuntu noble's own repos:** noble ships only the PG16 client. There is no `postgresql-client-18` in the base repos, so the existing system-packages pattern cannot deliver PG18 at all.
- **The mariadb-client APT exception:** "MariaDB 12.x lacks a stable version-addressable APT URL" does not transfer — PGDG *is* a stable, version-addressable third-party repo, so the exception's premise fails and the third-party-repo path is correct here.
- **Exact point-version pins against PGDG:** PGDG keeps only ~3 package versions in its index (announced 2026-04-23; 18.0–18.2 were already pruned by restore time). An exact pin breaks the weekly cacheless rebuild within roughly two point releases. The repo's exact-pin conventions for vendor-hosted binaries and single-version repos both fail to transfer to a rolling third-party apt index.
- **Letting apt resolve `postgresql-client-common` implicitly:** Ubuntu's installed `257build1.1` already satisfies the client-18 dependency floor (`>= 182~`), so implicit resolution silently keeps the Ubuntu wrapper while installing the PGDG client — a split-source PG stack that works but is not what the design intends.
- **Trusting CI to guard the block:** the original block was CI-green and was still deleted hours later. Green CI validates what exists at build time; it does not prevent a later deletion until the next build runs.

## Guidance

Restored on branch `feat/postgresql-client-18`, commit `a7e7f93` (plan: `docs/plans/2026-10-15-002-feat-add-postgresql-client-18-plan.md`). One banner-commented block at the Dockerfile tail, directly before `USER vscode`, after the Azure PostgreSQL TLS CAs block — the committed banner records the rationale below plus the removal history, so a future agent reading the block sees that deletion was already tried and was wrong.

```dockerfile
ARG POSTGRESQL_CLIENT_VERSION=18

RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor \
    | tee /etc/apt/keyrings/postgresql.gpg > /dev/null \
    && printf 'Types: deb\nURIs: https://apt.postgresql.org/pub/repos/apt\nSuites: noble-pgdg\nComponents: main\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/postgresql.gpg\n' "${TARGETARCH}" \
    | tee /etc/apt/sources.list.d/pgdg.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
    postgresql-client-${POSTGRESQL_CLIENT_VERSION} \
    postgresql-client-common \
    && psql --version | grep "psql (PostgreSQL) ${POSTGRESQL_CLIENT_VERSION}\." \
    && pg_dump --version \
    && pg_restore --version \
    && rm -f /etc/apt/sources.list.d/pgdg.sources /etc/apt/keyrings/postgresql.gpg \
    && rm -rf /var/lib/apt/lists/*
```

Design decisions, each load-bearing:

- **Major-float pin.** The ARG carries only the major (`18`) and feeds the package name `postgresql-client-18`; there is no package-version pin. Point and security releases resolve fresh from the PGDG index on each cacheless build, so the weekly rebuild — the repo's drift tripwire — becomes the delivery mechanism instead of the thing that breaks. A major bump (18→19) is an explicit ARG edit. The term and its contrast with exact pins are defined in `CONCEPTS.md` ("Major-float pin"); the repo-level convention lives in `CLAUDE.md` (install-method priority + Key Conventions).
- **deb822 `.sources` format** (`Types:/URIs:/Suites:/Components:/Architectures:/Signed-By:`) — the vendor-documented format as of 2026; the traditional one-liner still parses but is no longer the documented snippet. Written via `printf` so `${TARGETARCH}` interpolates cleanly, and apt resolves per-arch natively under QEMU — no arch-name remap (unlike the AWS CLI block's `x86_64`/`aarch64` remap, which exists because its download URLs use different names, not because apt does).
- **Keyring at `/etc/apt/keyrings/postgresql.gpg`, not the official snippet's path.** The official snippet dearms to `/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc`; that directory does not exist in this image, and a key there can become dpkg-owned when PGDG's own `postgresql-client-common` upgrade ships the same path — post-install cleanup would then delete a package-owned file. `/etc/apt/keyrings/` stays out of dpkg's inventory (Azure CLI block precedent). No GPG fingerprint pin: the key arrives over TLS from postgresql.org, the same trust class as the unpinned Microsoft key.
- **`postgresql-client-common` named explicitly in the install list.** Naming it upgrades the wrapper consciously from Ubuntu `257build1.1` to PGDG `293.pgdg24.04+1`, so the whole PG stack (client-18, `libpq5 >= 18.6`, client-common) comes from one source. Its `Breaks/Replaces: postgresql-common (<< 269)` is moot because `postgresql-common` is not installed. The system-layer install at `Dockerfile:67` stays — removing it would invalidate every layer below for zero gain.
- **In-RUN grep assertion on the major.** A wrong-major install exits 0 on a bare `--version` invocation, so the major must be grepped: `psql --version | grep "psql (PostgreSQL) ${POSTGRESQL_CLIENT_VERSION}\."`, plus `pg_dump --version` / `pg_restore --version`. Assertions sit *after* install so an `apt-get update` failure surfaces as a repo failure, not a masked assertion failure.
- **Post-install cleanup.** The sources file, keyring, and apt lists are removed: the shipped image contains no PGDG repo definition or key, so a consumer's apt operations inside the container cannot hit a repo whose key later rotates. `--no-install-recommends` keeps the server package out (`postgresql-18` appears only in Suggests).
- **Tail placement.** Zero layers below to invalidate on introduction; future ARG bumps rebuild only this block (ARG-per-block convention); groups the image's two PostgreSQL-related blocks (client + Azure TLS roots). Full `apt-get update` in the block rather than a scoped `-o Dir::Etc::sourcelist` update (Azure CLI precedent) — the cost is that the update also refreshes the persisted `azure-cli.list` and Ubuntu indexes, so a transient third-party outage can redden this layer; triage beats engineering around it.

When the weekly rebuild goes red at this block, triage by signature:

- signature/`NO_PUBKEY` error at `apt-get update` → PGDG key rotation, or a truncated key fetch (the `curl | gpg --dearmor | tee` pipeline fails one step later than the fetch itself — retry once, then rotate; precedent: PGDG key handling change, 2022-11-11)
- `Unable to locate package postgresql-client-18` → suite decommissioned or the major dropped from `noble-pgdg`
- any other repo's fetch error → co-hosted `azure-cli.list`/Ubuntu mirror outage refreshed by this block's full update — not a PGDG problem

Against a repeat of the deletion itself: treat unrequested deletions of working blocks as misbehavior (a "Fix:" commit with no PR, issue, or body that deletes functionality is a red flag on its own), keep the removal history in the block banner, keep this learning searchable, and keep the README's advertised psql row — in a repo with no test suite, an advertised-but-absent tool and a mirror drift are the loudest signals available.

## Why This Matters

The root cause was missing tooling compounded by an unrequested deletion: the wrapper was present but had no versioned client beneath it, and the one block that supplied one had been removed. The design hardens the restore against the failure modes that make such blocks fragile in a cacheless-weekly, multi-arch, mirror-disciplined repo:

- The float pin aligns the pin strategy with the actual volatility of the source — PGDG's *index*, not the package, is what changes. Exact pins would make the weekly tripwire go red the moment PGDG pruned the pinned point release; the float makes the same rebuild deliver 18.6→18.7 silently.
- Naming `postgresql-client-common` removes the silent split-source outcome apt's dependency resolution would otherwise produce.
- The grep assertion converts "installed some psql" into "installed the advertised major" at build time — the only enforcement layer a Dockerfile-centric repo has.
- Keyring placement outside dpkg-owned paths keeps post-install cleanup safe across future PGDG wrapper upgrades; repo cleanup keeps the published image free of a live third-party apt source whose key can rotate after publication.
- The banner + this doc make the `98758e0` incident searchable — the durable defense. The build-level assertion only catches a deletion at the next build; the documented history and the README's advertised row are what tell a human or agent "this block should exist" *before* it edits.

Verification: smoke test `docker build .` passed on amd64, resolving `postgresql-client-18 18.6-1.pgdg24.04+2`, `libpq5 18.6-1.pgdg24.04+2`, and `postgresql-client-common 293.pgdg24.04+1` over `257build1.1`. Fresh-container acceptance as the non-root `vscode` user: `psql --version`, `pg_dump --version`, `pg_restore --version` all report 18.6; `/usr/bin/psql` → `/usr/share/postgresql-common/pg_wrapper` → `/usr/lib/postgresql/18/bin/psql` resolves; server packages show `un` (not installed); `pgdg.sources` and `postgresql.gpg` are absent from the image. arm64 is proven by the CI PR build.

## When to Apply

- Installing a PostgreSQL client major the base distro does not ship — reach for the vendor repo instead of settling for the distro's older major.
- Choosing a pin strategy for a third-party apt repo: classify by index volatility first. Exact pin for single-version repos and vendor-hosted binaries; major-float for rolling multi-version indexes like PGDG. A major bump stays an explicit ARG edit in both worlds.
- Adding any third-party apt source to an image that must ship clean: deb822 sources file + dearmored key outside dpkg-owned paths, both removed in the same RUN that installed from them.
- Installing a wrapper/meta package alongside the versioned package it dispatches to — name the wrapper explicitly whenever its distro build already satisfies the versioned package's floor, or you get a split-source install silently.

## Examples

Before (published image, wrapper with no client):

```text
$ psql --version
Error: You must install at least one postgresql-client-<version> package
```

After (restored image, as the non-root `vscode` user):

```text
$ psql --version
psql (PostgreSQL) 18.6
$ pg_dump --version
pg_dump (PostgreSQL) 18.6
```

Float semantics in practice:

- PGDG ships 18.7 → the next weekly cacheless build resolves it silently; the major grep still passes; `latest` carries 18.7 with no operator action.
- PG 19 goes GA and the image should move → one explicit edit, `ARG POSTGRESQL_CLIENT_VERSION=19`; the block (package name, grep, mirror entry) follows the ARG.
- Wrong-major resolution (a hypothetical stray 19 package answering to `-18`) → the grep fails the build instead of shipping quietly.

## Related

- `docs/solutions/tooling-decisions/azure-postgresql-root-cas-trust-store.md` — sibling 2026-10-15 PostgreSQL Dockerfile block; same ARG-above-RUN / in-RUN-assert / weekly-tripwire pattern family, and the same red-build signature-disambiguation discipline.
- `docs/solutions/tooling-decisions/az-cli-extensions-system-install.md` — the in-RUN grep-assertion precedent this block's version check follows.
- `docs/solutions/tooling-decisions/ansible-lint-pipx-shared-venv-installation.md` — the conscious-dependency-management counterpart: its frozen constraints prevent silent upgrades; this block consciously takes a deliberate Ubuntu→PGDG upgrade.
- `CONCEPTS.md` — "Major-float pin", "Version mirror", "Drift tripwire", "ARG-per-block convention", "Smoke test".
- Issue #14 (open) — automated `.env.example`↔Dockerfile ARG mirror check; would have caught the exact `98758e0` drift.
- PR #7 (`17bf1ec`, added) → commit `98758e0` (erroneous removal, 2026-04-27) → this restore. Plan: `docs/plans/2026-10-15-002-feat-add-postgresql-client-18-plan.md`.
