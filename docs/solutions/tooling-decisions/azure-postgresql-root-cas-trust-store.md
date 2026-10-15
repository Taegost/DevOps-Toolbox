---
title: "Baking Azure PostgreSQL TLS root CAs into the image trust store, SHA256-pinned"
module: "Dockerfile TLS root-CA trust store (update-ca-certificates)"
date: "2026-10-15"
problem_type: "tooling_decision"
component: "tooling"
severity: "low"
track: "knowledge"
applies_when:
  - "Connecting to Azure Database for PostgreSQL Flexible Server over TLS from this image"
  - "Requiring a root CA to be present regardless of base image, not just whichever ones the distro CA store happens to ship"
  - "Pinning a root CA by SHA256 so the checksum doubles as an identity pin (CCADB-published fingerprint)"
  - "Installing a DER-encoded certificate into the Debian trust store with curl, sha256sum -c, openssl x509, and update-ca-certificates"
  - "Planning a root-CA rotation where Azure dual-signs during a transition: add the new root first, remove the old one only after the retirement date"
resolution_type: "tooling_addition"
related_components:
  - "development_workflow"
tags:
  - "tls"
  - "root-ca"
  - "ca-certificates"
  - "trust-store"
  - "docker"
  - "sha256-pin"
  - "azure-postgresql"
  - "devops-toolbox"
---
# Baking pinned vendor root CAs into a Docker image trust store (Azure PostgreSQL TLS)

## Context

The DevOps Toolbox image is a dev container consumed by many projects. Issue #15 asked that the two root CAs Azure Database for PostgreSQL Flexible Server currently chains to — DigiCert Global Root G2 and Microsoft RSA Root CA 2017 — be present in the image's system trust store, so that the `cyrilgdn/postgresql` Terraform provider works with `sslmode = "verify-full"` out of the box.

The provider is a Go binary, and that fact drives everything: Go's crypto/x509 verifies server certificates only against the container's system trust store and never downloads missing CAs. When a root is absent, `terraform plan/apply` fails with `x509: certificate signed by unknown authority` — a runtime error whose cause lives in the image build, far from where it surfaces.

The uncomfortable part of this issue was that it was raised pre-emptively. Both roots already ship in the distro CA package on every ubuntu-24.04-based image: re-verified 2026-10-15 against the pristine base (`mcr.microsoft.com/devcontainers/base:ubuntu-24.04`, `ca-certificates 20240203`), both `DigiCert_Global_Root_G2.crt` and `Microsoft_RSA_Root_Certificate_Authority_2017.crt` are present in `/usr/share/ca-certificates/mozilla/` (an earlier check had wrongly reported DigiCert Global Root G2 absent — always re-verify against the pristine base before acting on an "it's missing" report). So the "missing CA" story did not hold on its face, and the issue's first requirement was conditional: use the distro package if it already includes the roots, add them explicitly otherwise.

The plan deliberately took the explicit-add branch anyway, for one reason: the requirement is that both roots are **always present regardless of base image used**, and distro presence is not a durable fact. `Dockerfile:45` installs `ca-certificates` unpinned — a weekly rebuild, a distro update, or a base-image swap can drop a root Azure still chains to, silently. The explicit add is churn insurance, not a gap fill. The rejected alternative — an assert-only tripwire (`openssl verify` of both roots against the distro store, no install, weekly cron goes red if one vanishes) — was turned down because it detects rather than prevents: the store goes red and stays incomplete until an operator acts, while explicit pins keep it complete through a distro drop.

Beyond that fork, four decisions had to be made before the block was worth committing: how to pin the downloads when the cert publishers ship no `SHA256SUMS` file; what to assert in-build, in a repo with no test suite; where to place the block so a future rotation doesn't invalidate half the Docker cache; and how to rotate a baked root when Azure retires one.

## Guidance

1. **Bake vendor roots explicitly even when the distro already ships them.** Distro presence is an accident of the CA package's current contents, not a contract. The image installs `ca-certificates` unpinned, so what the store carries can change under any rebuild. Explicit copies under `/usr/local/share/ca-certificates/` guarantee presence through distro churn and base-image swaps. Duplicates are harmless — see guidance #5.

2. **Roots only — never intermediates or server certificates.** Microsoft rotates intermediates and server certs without notice; pinning one breaks on the next rotation, with no signal. Roots are the stable anchors. Microsoft's TLS guidance (Microsoft Learn, *TLS in Azure Database for PostgreSQL Flexible Server*, ms.date 2026-07-14) says clients should hold exactly these two roots and nothing more. This is the boundary between "trust anchor" and "snapshot of a rotating chain".

3. **Pin downloads with SHA256 `ARG`s, and let the pin double as an identity pin.** Cert publishers ship no `SHA256SUMS` file, so the hashes are hardcoded as `ARG`s directly above the `RUN` (repo ARG-above-RUN convention). The trick that makes this cheap: for a DER cert file, the file hash equals the certificate hash, which equals the CCADB-published SHA256 fingerprint. Cross-check your computed hash against CCADB once, and the checksum gate is simultaneously an integrity gate (bytes unchanged in transit) and an identity gate (this exact certificate, not merely some well-formed one) — no separate subject-string assertion needed.

4. **One `&&`-chained `RUN`, every step loud.** The canonical Debian flow, gated at each step:

   - `curl -fsSL <url> -o /tmp/<name>.der` — both vendor URLs serve DER;
   - `echo "<PIN>  /tmp/<name>.der" | sha256sum -c` — fails the build on any byte drift;
   - `openssl x509 -inform DER -in <der> -out /usr/local/share/ca-certificates/<name>.crt` — convert to PEM into the directory `update-ca-certificates` sweeps;
   - `update-ca-certificates` — rebuilds the bundle and hash-symlink directory;
   - `openssl verify /usr/local/share/ca-certificates/<name>.crt` — the assertion;
   - `rm` the DER temps in the same `RUN` — layer hygiene, matching every other download block.

   Nothing parses or greps `update-ca-certificates` output text; the only contract is the `openssl verify` result.

5. **Assert via `openssl verify` only. Know what `update-ca-certificates` stdout does and does not tell you.** With pre-existing distro copies of the same roots, a real run reported `2 added, 0 removed` plus two `rehash: warning: skipping duplicate certificate` warnings — and the added-count **tallies created symlinks**, so it stays `2 added` even for full duplicates. The warning count shifts with distro contents. stdout is not a stable contract; never parse it. `openssl verify` (trusted-first) of each installed `.crt` returns OK iff that root is in the store — deterministic, and proven available in the base image. Note precisely what it proves: store membership, not *which* copy (distro or explicit) supplied the trust.

6. **Place the block late and isolated: own banner block directly before `USER vscode`.** A trust-store change is cross-cutting system infrastructure, kin to the other late system-level blocks, not an adjunct of one tool. Bump-isolation is the property the ARG-per-block layout exists for: a future pin or URL change rebuilds only this block. Collocating it after the `ca-certificates` install layer — the az-ssh "next to the thing it extends" precedent — was explicitly rejected: it would invalidate all ~25 tool layers below on every future cert change. Write the banner to carry the knowledge a future maintainer needs: why (Go provider, `verify-full`), roots-only rationale, the expected duplicate warnings ("do not 'fix' them"), arch-independence, the cache caveat, and the rotation rule.

7. **Mirror the hashes in `.env.example` — in their own group, because hashes are not versions.** These are the image's first non-version `ARG`s; the mirror invariant (every Dockerfile `ARG` has an exactly-matching `.env.example` entry) holds, but a `VERSION=`-style grouping would misrepresent what the values are. New group, explicit comment (`# Azure PostgreSQL TLS root CAs — sha256 pins, not versions`), plus source links (Microsoft Learn TLS page, both vendor cert URLs) in the version-reference header.

8. **Treat rotation as a one-unit edit with add-before-remove ordering.** URL + sha256 `ARG` + `.env.example` mirror are edited together — a hash-only bump cannot fix a moved URL, and the `pkiops` URL layout has changed historically. Azure rotates roots with dual-signed chains, so **add the new root first and remove the old one only after Azure's retirement date passes** — both anchors must coexist during transition. A moved URL fails at `curl` (exit 7/28/60), not at the checksum gate; know which signature you are looking at when the weekly build goes red.

9. **Know the cache blind spot, and name the tripwire.** A cached `RUN` does not re-execute — the checksum gates run only when the layer rebuilds. A warm-cache local build or a PR build reading the GHA layer cache proves nothing about current vendor bytes. The weekly Monday 04:00 UTC cron build (no cache-from) is the vendor-drift tripwire; a red weekly build with a checksum or curl failure means the vendor changed something. Distinctly: a curl TLS error (exit 60) on the downloads themselves means the *bootstrap* store could not verify the vendor host — not a checksum mismatch. Don't misdiagnose.

10. **No `TARGETARCH` handling for PEM artifacts.** The downloads are converted to PEM before installation, so one code path serves both `linux/amd64` and `linux/arm64` under QEMU/Buildx. Arch remapping is only for native binaries — check what the artifact actually is before adding a conditional.

## Why This Matters

The failure mode this block exists to prevent is the worst-shaped one for a shared image: **a runtime error whose cause is a build-time absence**, surfacing on someone else's machine as `x509: certificate signed by unknown authority` under `sslmode = "verify-full"`. Go never fetches a missing CA, so no amount of client-side cleverness fixes it — the root must be in the image.

Relying on distro presence would have "worked" the day the PR merged and quietly stopped being guaranteed at some unpredictable later rebuild — the same build-green-but-trust-incomplete shape as the az-ssh per-user install trap, one abstraction level up. Explicit pins convert that slow drift into a determinism guarantee: every rebuild carries both roots regardless of what the base image or the CA package decides. The accepted cost is real and is disclosed in the banner: pinned roots bypass future distro/Mozilla distrust decisions for these CAs, so watching CCADB bulletins and treating root *removal* as a deliberate image change is part of the maintenance contract, never a passive drift.

The checksum gate converts vendor-side change or in-transit tampering into a loud build failure. Both failure paths were verified empirically on 2026-10-15: corrupting the DigiCert pin failed the build with `sha256sum: WARNING: 1 computed checksum did NOT match` and `/tmp/az-postgresql-digicert-global-root-g2.der: FAILED` (exit 1; pin restored via `git checkout`, tree clean), and `openssl verify` of an untrusted self-signed cert returned `error 18 at 0 depth lookup: self-signed certificate` with exit 2. Given this repo has no test suite and the CI build is the validation step, assertions inside the `RUN` are the only executable checks that will ever run here.

One honest residual: the gate is only as fresh as the last cacheless build. That residual is why guidance #9 exists — the weekly cron is the named tripwire, not an afterthought. And the duplicate roots (distro entry + explicit entry coexisting in the bundle) are harmless for verification; the rehash warnings that result are expected behavior, documented in the banner so nobody "fixes" them.

## When to Apply

- A Go (or other) client that verifies **only** against the system trust store and never downloads missing CAs — the root must ship in the image or the client fails under `verify-full`.
- A vendor publishes **stable root CAs** with fingerprint references (CCADB or equivalent) — the pin-as-identity pattern applies whenever the file hash equals the cert fingerprint.
- **Pre-emptive hardening** where the roots are already present but presence is not durable — unpinned `ca-certificates`, scheduled rebuilds, or a base image you don't control. "Works today via the distro" is not a reason to skip; it's the reason the explicit add is insurance.
- Any Debian/Ubuntu-based image: the `/usr/local/share/ca-certificates/` → `update-ca-certificates` flow is canonical and the resulting bundle/hash directory is what Go reads by default.
- PEM-format artifacts generally: no arch handling needed, one `RUN` for both platforms.

Not applicable when: the artifact is an **intermediate or server certificate** (breaks on unannounced vendor rotation — Microsoft's guidance is roots-only for clients); the client keeps its **own store** (e.g. Java's `cacerts` — the system-store flow does not reach it); or the need is runtime/per-session fetch (this pattern is zero-runtime-steps by design).

## Examples

**The block as implemented (`Dockerfile:602-651`):**

```dockerfile
# -----------------------------------------------------------------------------
# Azure Database for PostgreSQL TLS root CAs (#15)
# Bakes the two root CAs Azure Database for PostgreSQL Flexible Server chains
# to into the system trust store at build time. Go clients (e.g. the
# cyrilgdn/postgresql Terraform provider) verify server certificates only
# against the system trust store and never download missing CAs, so
# sslmode = "verify-full" fails with "x509: certificate signed by unknown
# authority" unless these roots are present.
#
# Root CAs only, no intermediates or server certificates: Microsoft rotates
# intermediates and server certs without notice — pinning them breaks on
# rotation. Roots are the stable anchors.
#
# The distro CA package also ships both roots, so update-ca-certificates
# emits "skipping duplicate certificate" warnings during rehash. Those
# warnings are expected — do not "fix" them. The explicit copies guarantee
# both roots stay present regardless of what the base image's CA package
# carries.
#
# Arch-independent: the certs are converted to PEM, so no TARGETARCH
# handling is needed.
#
# The sha256 gates re-execute only when this layer rebuilds — a cached RUN
# does not re-download. The weekly Monday cron build (no cache-from) is the
# vendor-drift tripwire.
#
# Rotation rule: URL + sha256 ARG + the .env.example mirror are edited as
# one unit. Azure rotates roots with dual-signed chains — add the new root
# first, remove the old one only after Azure's retirement date passes.
# The pins are the CCADB-published SHA256 fingerprints (equal to the file
# hash), so the checksum also pins the certificate's identity.
# -----------------------------------------------------------------------------
ARG DIGICERT_GLOBAL_ROOT_G2_SHA256=cb3ccbb76031e5e0138f8dd39a23f9de47ffc35e43c1144cea27d46a5ab1cb5f
ARG MICROSOFT_RSA_ROOT_CA_2017_SHA256=c741f70f4b2a8d88bf2e71c14122ef53ef10eba0cfa5e64cfa20f418853073e0

RUN curl -fsSL https://cacerts.digicert.com/DigiCertGlobalRootG2.crt \
        -o /tmp/az-postgresql-digicert-global-root-g2.der \
    && curl -fsSL \
        "https://www.microsoft.com/pkiops/certs/Microsoft%20RSA%20Root%20Certificate%20Authority%202017.crt" \
        -o /tmp/az-postgresql-microsoft-rsa-root-ca-2017.der \
    && echo "${DIGICERT_GLOBAL_ROOT_G2_SHA256}  /tmp/az-postgresql-digicert-global-root-g2.der" | sha256sum -c \
    && echo "${MICROSOFT_RSA_ROOT_CA_2017_SHA256}  /tmp/az-postgresql-microsoft-rsa-root-ca-2017.der" | sha256sum -c \
    && openssl x509 -inform DER -in /tmp/az-postgresql-digicert-global-root-g2.der \
        -out /usr/local/share/ca-certificates/az-postgresql-digicert-global-root-g2.crt \
    && openssl x509 -inform DER -in /tmp/az-postgresql-microsoft-rsa-root-ca-2017.der \
        -out /usr/local/share/ca-certificates/az-postgresql-microsoft-rsa-root-ca-2017.crt \
    && update-ca-certificates \
    && openssl verify /usr/local/share/ca-certificates/az-postgresql-digicert-global-root-g2.crt \
    && openssl verify /usr/local/share/ca-certificates/az-postgresql-microsoft-rsa-root-ca-2017.crt \
    && rm /tmp/az-postgresql-digicert-global-root-g2.der /tmp/az-postgresql-microsoft-rsa-root-ca-2017.der
```

**The `.env.example` mirror (`.env.example:63-65`, header source links at lines 30-32):**

```bash
# Azure PostgreSQL TLS root CAs — sha256 pins, not versions
DIGICERT_GLOBAL_ROOT_G2_SHA256=cb3ccbb76031e5e0138f8dd39a23f9de47ffc35e43c1144cea27d46a5ab1cb5f
MICROSOFT_RSA_ROOT_CA_2017_SHA256=c741f70f4b2a8d88bf2e71c14122ef53ef10eba0cfa5e64cfa20f418853073e0
```

Header additions in the version-reference block:

```
#   Azure PostgreSQL TLS:        https://learn.microsoft.com/en-us/azure/postgresql/security/security-tls
#   DigiCert Global Root G2:     https://cacerts.digicert.com/DigiCertGlobalRootG2.crt
#   Microsoft RSA Root CA 2017:  https://www.microsoft.com/pkiops/certs/Microsoft%20RSA%20Root%20Certificate%20Authority%202017.crt
```

**Acceptance — fresh container as the shipping (non-root) user, the check that proves store membership:**

```bash
docker run --rm -u vscode devops-toolbox:local bash -c \
  "openssl verify /usr/local/share/ca-certificates/az-postgresql-digicert-global-root-g2.crt \
                  /usr/local/share/ca-certificates/az-postgresql-microsoft-rsa-root-ca-2017.crt"
# both print: OK
```

**Negative test 1 — corrupted pin fails the build (verified 2026-10-15):** change one hex digit in `DIGICERT_GLOBAL_ROOT_G2_SHA256`, build:

```
sha256sum: WARNING: 1 computed checksum did NOT match
/tmp/az-postgresql-digicert-global-root-g2.der: FAILED
```

Build exits 1. Restore with `git checkout -- Dockerfile`; tree clean.

**Negative test 2 — untrusted cert fails the assertion (verified 2026-10-15):** `openssl verify` of a self-signed, store-absent cert:

```
error 18 at 0 depth lookup: self-signed certificate
```

Exit 2 — inside the `&&` chain, this fails the build.

**The rejected alternative, for contrast — assert-only tripwire (detection, not prevention):**

```dockerfile
# REJECTED: goes red weekly if a distro root vanishes, but the store stays
# incomplete until an operator acts. Kept as reference only.
RUN openssl verify /usr/share/ca-certificates/mozilla/DigiCert_Global_Root_G2.crt \
    && openssl verify /usr/share/ca-certificates/mozilla/Microsoft_RSA_Root_Certificate_Authority_2017.crt
```

**Expected `update-ca-certificates` output on a distro that already ships both roots (do not parse, do not "fix" the warnings):**

```
Updating certificates in /etc/ssl/certs...
2 added, 0 removed; done.
Running hooks in /etc/ca-certificates/update.d...
rehash: warning: skipping duplicate certificate in az-postgresql-digicert-global-root-g2.pem
rehash: warning: skipping duplicate certificate in az-postgresql-microsoft-rsa-root-ca-2017.pem
rehash: warning: skipping ca-certificates.crt,it does not contain exactly one certificate or CRL
done.
```

**Rotation, when it comes — one unit, new before old:** edit the vendor URL, the matching sha256 `ARG`, and the `.env.example` mirror in the same commit; if Azure introduces a new root, add it (its own CCADB-verified pin) and keep the old one until Azure's published retirement date passes. A red build at `curl` (exit 7/28/60) means a moved URL — fix the URL, not the pin; a red build at `sha256sum -c` means the vendor's bytes changed — verify the new fingerprint against CCADB before updating the pin, because the pin is the identity.

## Related

- `docs/solutions/tooling-decisions/az-cli-extensions-system-install.md` — pattern-family precedent for bake-vendor-artifact-at-build-time (ARG-above-RUN, explicit pin, in-RUN assertions, verify as shipping user, disclosed residual risk). Documents issue #11.
- `docs/solutions/tooling-decisions/ansible-lint-pipx-shared-venv-installation.md` — the drift-guard theme: frozen constraints there, sha256 checksum gate here.
- Issue #15 — the feature request this documents (pre-emptive; the plan records the explicit-add override of the issue's distro-first conditional).
- Issue #14 — automated `.env.example`/ARG sync check; the sha256 pins expand the surface it would cover.
- Plan: `docs/plans/2026-10-15-001-feat-azure-postgresql-root-cas-plan.md`
