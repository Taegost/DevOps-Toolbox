---
title: "Bitwarden CLI as the first fully-unpinned tool: build-time GitHub release resolution with digest gate"
module: "Dockerfile Bitwarden CLI install (unpinned GitHub release resolver)"
date: "2026-11-27"
problem_type: "tooling_decision"
component: "tooling"
severity: "medium"
track: "knowledge"
applies_when:
  - "Adding a tool to the DevOps-Toolbox image without a version ARG so each cacheless build resolves the newest release itself"
  - "Deciding whether a tool version should be pinned (ARG plus .env.example mirror) or resolved at build time, and documenting the trade-off"
  - "Resolving a GitHub release inside a docker build RUN via one unauthenticated API call to /repos/<owner>/<repo>/releases with an age floor"
  - "Vetting a downloaded artifact without an independent checksum host: using the release API's own assets[].digest sha256 as a fail-closed gate"
  - "Diagnosing a weekly cacheless build failing in an unpinned resolver (BW_RATE_LIMIT, BW_ASSET_RENAME, BW_NO_ARCH_ASSET, BW_SHA_MISMATCH, BW_NO_RELEASE, BW_DIGEST_ABSENT, BW_VERSION_MISMATCH)"
symptoms:
  - "Security patches for a secrets tool wait on a manual version bump in a fully pinned image"
  - "A build that resolves latest at build time can install a release published seconds earlier that the vendor may pull"
root_cause: "missing_tooling"
resolution_type: "tooling_addition"
related_components:
  - "development_workflow"
  - "documentation"
tags:
  - "bitwarden"
  - "bw"
  - "unpinned"
  - "version-resolution"
  - "github-api"
  - "supply-chain"
  - "docker"
  - "devops-toolbox"
---

# Bitwarden CLI as the first fully-unpinned tool: build-time GitHub release resolution with digest gate

## Context

This repository pins every tool with an `ARG VERSION` declared directly above its install block, mirrored in `.env.example`. The convention keeps Docker layer caches warm across unrelated version bumps and makes every published image byte-reproducible for a given Git tag — but it also means a security patch ships only after an operator notices the upstream release and bumps the ARG by hand.

Bitwarden CLI (`bw`) deliberately breaks that convention. It is the image's first fully-unpinned tool: no version ARG, no `.env.example` mirror entry, and resolution happening inside the install `RUN` on each cacheless build. This was an explicit user decision, not an oversight: on a secrets-handling tool, security patches should arrive without a manual bump. The accepted costs are disclosed in the block banner and in `CLAUDE.md` — versioned image tags stop being byte-reproducible, and the weekly cacheless rebuild adopts whatever upstream published, unreviewed.

The channel choice is shaped by the April 2026 npm-channel compromise of `@bitwarden/cli`, where a malicious publish stayed live for roughly 90 minutes. That event rules out npm as an install channel and motivates two defenses baked into the pattern: install from GitHub release zips containing the vendor's native self-contained `bw-bit` binary (no Node, no npm, no transitive package resolution at install time), and hold every release behind a 24-hour age floor so a just-published — possibly recalled — release never lands in an image.

Two facts about the vendor's release stream drive the resolver design:

- `/releases/latest` is not usable. The `bitwarden/clients` monorepo shares one release stream across desktop, browser, and CLI clients, so "latest" is usually not a CLI release. The resolver pages `/repos/bitwarden/clients/releases?per_page=30` (newest first) and filters tags itself.
- The `bw-bit-*` asset family is the vendor's default distribution build (what bitwarden.com/download serves) and includes non-OSS features such as device approval that `bw-oss-*` lacks. Rejected channels: the archived `bitwarden/cli` repo (frozen 2022), npm (needs Node >= 22, which the image does not ship, plus the compromised-channel history), and Snap (amd64-only).

## Guidance

The pattern is a single install `RUN` that resolves, verifies, installs, and proves — with every failure mode exiting the build under a distinct, log-identifiable signature. A Dockerfile `RUN` cannot use heredocs, so the Python resolver is written into the layer with `printf '%s\n'`, one line per argument, and executed under `python3 -I` (isolated mode) because the API payload is untrusted input.

### 1. Resolve inside the install RUN, not at build-arg time

One unauthenticated GitHub API call per platform. The HTTP status is captured via curl's `%{http_code}` and checked before anything consumes the body. 403 is the unauthenticated rate limit (60 requests/hour per runner IP) and carries its own triage signature.

```dockerfile
RUN BW_API_JSON=/tmp/bw-releases.json BW_RESOLVER=/tmp/bw-resolve.py BW_ENV=/tmp/bw.env BW_ZIP=/tmp/bw.zip BW_BIN=/tmp/bw.bin \
    && HTTP_CODE=$(curl -sS \
        -H "Accept: application/vnd.github+json" \
        -o "${BW_API_JSON}" \
        -w '%{http_code}' \
        "https://api.github.com/repos/bitwarden/clients/releases?per_page=30") \
    && if [ "${HTTP_CODE}" != "200" ]; then \
        echo "BW_RATE_LIMIT: GitHub API returned HTTP ${HTTP_CODE} (403 = unauthenticated rate limit: 60 req/h per runner IP; any other code = API or network outage). Retry once; recurring failures -> authenticated CI-side resolution escape hatch"; \
        exit 1; \
    fi \
```

### 2. Python resolver with a 24-hour age floor

The resolver filters tags matching `^cli-v` (calver, `cli-vYYYY.M.P`), then applies a release-age floor via a lexicographic comparison of truncated ISO timestamps — `published_at[:19]` against `now_utc - 24h`, both in `%Y-%m-%dT%H:%M:%S` form, so no date parsing is needed.

```python
suffix = "-arm64" if arch == "arm64" else ""
asset_re = re.compile(r"^bw-bit-linux" + re.escape(suffix) + r"-\d+\.\d+\.\d+\.zip$")
floor = (datetime.now(timezone.utc) - timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%S")
```

```python
published = str(rel.get("published_at", ""))[:19]
if published > floor:
    skipped.append(tag + " (published " + published + "Z)")
    continue
```

Direction matters here, and it runs opposite to intuition: ISO timestamps compare correctly as strings, but dates run opposite to ages. A release published one hour ago has a `published_at` *newer* than the floor, so it fails the eligible comparison and is skipped (`BW_SKIPPED_TOO_YOUNG` logs each skip to stderr); the resolver falls through to the newest release that does clear the floor. The floor exists so a brand-new — possibly recalled — release never lands in an image before the community has had a day to scrutinize it. The resolver takes the first entry that passes both the tag filter and the floor, and reads tag, per-arch asset URL, and sha256 digest from that one API response — no second call.

### 3. Per-arch asset discovery with a rename probe

The asset regex is constructed per architecture. `TARGETARCH` is `amd64` (unsuffixed asset) or `arm64` (`-arm64` asset); the families are disjoint, so the regex matches exactly one asset per platform.

```python
suffix = "-arm64" if arch == "arm64" else ""
asset_re = re.compile(r"^bw-bit-linux" + re.escape(suffix) + r"-\d+\.\d+\.\d+\.zip$")
```

When no asset matches, a second probe for the bare `bw-bit-linux` family prefix distinguishes the two upstream failure modes: family entirely absent means upstream renamed the asset family (`BW_ASSET_RENAME` — precedent: `cli-v2026.11.0` renamed `bw-linux-` to `bw-bit-linux-`, with an explicit upstream warning that direct-download scripts break; recovery is a one-block regex edit in this RUN), while family present but this arch missing means the vendor dropped the architecture (`BW_NO_ARCH_ASSET` — upstream docs still point arm64 users at npm).

```python
if not assets:
    family = [a for a in (rel.get("assets") or []) if str(a.get("name", "")).startswith("bw-bit-linux")]
    if not family:
        sys.exit("BW_ASSET_RENAME: no bw-bit-linux-* asset on " + tag + " - asset family renamed upstream, update the regex in this RUN (precedent: cli-v2026.11.0 renamed bw-linux- to bw-bit-linux-)")
    sys.exit("BW_NO_ARCH_ASSET: bw-bit-linux assets exist on " + tag + " but none matches " + asset_re.pattern + " (vendor dropped this arch? upstream docs point arm64 at npm)")
```

### 4. Integrity gate: the API's own per-asset digest

The gate uses the `digest` field (`sha256:<hex>`) that the GitHub API publishes on each asset. It is validated against `^sha256:[0-9a-f]{64}$`, and the downloaded zip is checked with `sha256sum -c` before unzip and install. Failure is closed in both directions: a missing or malformed digest aborts the build (`BW_DIGEST_ABSENT`), and downloaded bytes that fail the digest abort the build (`BW_SHA_MISMATCH`) — nothing installs on a weak signal.

```python
digest = assets[0].get("digest", "")
if not re.match(r"^sha256:[0-9a-f]{64}$", digest):
    sys.exit("BW_DIGEST_ABSENT: assets[].digest missing or malformed on " + tag + " - failing closed, nothing installed")
```

```dockerfile
&& curl -fsSL "${BW_ASSET_URL}" -o "${BW_ZIP}" \
&& if ! echo "${BW_SHA256}  ${BW_ZIP}" | sha256sum -c; then \
    echo "BW_SHA_MISMATCH: downloaded bytes fail the API-published sha256 digest for ${BW_TAG} (corruption or upstream drift)"; \
    exit 1; \
fi \
```

Disclose the limit honestly: the digest comes from the same host that serves the asset, so this gate catches corruption and drift, not a malicious host. It is the same class of check as the image's terragrunt/packer SHA256SUMS gates, and it is acceptable here because the channel itself — GitHub releases over TLS — is the trust anchor. This is integrity, not provenance.

### 5. Emission hygiene: shlex.quote every value

The resolver does not print values for the shell to `eval` loosely; it writes `export VAR=...` lines to an env file, with `shlex.quote` applied to every value. The tag, version, URL, and digest all originate in an untrusted API payload — quoting guarantees none of them can break out into shell execution when the env file is sourced. The version is derived as `tag[5:]`, stripping the `cli-v` prefix.

```python
with open(env_path, "w") as fh:
    fh.write("export BW_TAG=" + shlex.quote(tag) + "\n")
    fh.write("export BW_VERSION=" + shlex.quote(tag[5:]) + "\n")
    fh.write("export BW_ASSET_URL=" + shlex.quote(assets[0]["browser_download_url"]) + "\n")
    fh.write("export BW_SHA256=" + shlex.quote(digest.split(":", 1)[1]) + "\n")
```

### 6. Post-install asserts, still inside the RUN

Two assertions prove the installed binary before the layer is cached. First, `bw --version` must string-equal the resolver's version — this catches an upstream print-format change that would otherwise silently decouple the reported version from the resolved one (`BW_VERSION_MISMATCH`). Second, `BW_NOINTERACTION=true bw status` must exit 0, proving the binary executes account-free without hanging. `BW_NOINTERACTION=true` prefixes every `bw` call in the block so a prompt can never hang the build.

```dockerfile
&& unzip -p "${BW_ZIP}" bw > "${BW_BIN}" \
&& install -m 755 "${BW_BIN}" /usr/local/bin/bw \
&& BW_GOT=$(BW_NOINTERACTION=true bw --version) \
&& if [ "${BW_GOT}" != "${BW_VERSION}" ]; then \
    echo "BW_VERSION_MISMATCH: bw --version printed [${BW_GOT}], expected [${BW_VERSION}] (upstream print format changed)"; \
    exit 1; \
fi \
&& BW_NOINTERACTION=true bw status > /dev/null \
&& rm -f "${BW_API_JSON}" "${BW_RESOLVER}" "${BW_ENV}" "${BW_ZIP}" "${BW_BIN}" \
&& echo "Bitwarden CLI installed: ${BW_TAG} (${BW_VERSION})"
```

### 7. Convention interactions

Going unpinned touches four other repo conventions; handle each deliberately:

- **Version mirror invariant.** No version ARG means no `.env.example` entry — the mirror ties entries to ARGs, and a mirror entry without an ARG would itself be drift. The absence is documented in the block banner and in the `CLAUDE.md` Key Conventions bullet. A future automated mirror check (issue #14) must treat ARG-less tools as in-scope-for-nothing, not as drift.
- **Near-tail placement.** The block sits directly before the first-party `bw-login` helper block and the final `USER vscode`. Only that thin helper COPY+RUN sits beneath, so a rename-recovery emergency edit invalidates at most two cheap layers — still the cheapest practical recovery path for the most likely upstream break.
- **Temp artifact hygiene.** The API JSON, resolver script, env file, zip, and extracted binary are all `/tmp` paths and all removed inside the same RUN — the layer ships only `/usr/local/bin/bw`.
- **No shell completion.** Scoped out by decision; nothing ships for any shell.

## Why This Matters

Unpinned delivery inverts the scheduled build's Drift tripwire. In the pinned world, the weekly cacheless build exists to *detect* upstream drift and red-flag it for an operator decision. With `bw`, that same forced re-resolve *is* the update mechanism: upstream drift is adopted, not detected. The weekly build is no longer a canary — it is the delivery pipeline — which is exactly why every failure mode needs its own signature.

Those signatures make weekly-red diagnosis mechanical. The block banner documents the full table; each name identifies the failing stage and the recovery from the log alone:

| Signature | Meaning | Recovery |
|---|---|---|
| `BW_RATE_LIMIT` | GitHub API non-200 (403 = unauthenticated 60 req/h per runner IP) | Retry once; recurring — authenticated CI-side resolution is the documented escape hatch |
| `BW_ASSET_RENAME` | Asset family renamed upstream | One-block regex edit in this RUN (near-tail placement keeps the blast radius at the bw block plus the thin helper layers) |
| `BW_NO_ARCH_ASSET` | Family present, this arch's asset missing | Vendor regression; npm is the documented but rejected fallback |
| `BW_SHA_MISMATCH` | Downloaded bytes fail the API digest | Investigate before retrying — corruption or upstream drift |
| `BW_NO_RELEASE` | Nothing in the newest 30 clears the 24h floor | Secondary; usually means upstream paused CLI releases |
| `BW_DIGEST_ABSENT` | Digest missing or malformed | None — fail closed by design |
| `BW_VERSION_MISMATCH` | `bw --version` print format changed | Update the assert's expectation |

The cache semantics trade-off is real and disclosed. Resolution happens per cacheless build — the weekly Monday cron, `workflow_dispatch` default, and `--no-cache`. PR builds and semver-tag builds read the GHA layer cache and reuse the resolved `bw` layer, so a versioned tag can ship cache-stale `bw`, and byte-reproducible versioned tags are gone as a property of the image. Both costs were explicitly accepted in exchange for patch latency on a secrets tool.

One multi-arch caveat: each platform resolves independently, so a release publishing between the amd64 and arm64 resolutions can land different `bw` versions in one multi-arch manifest. This is best-effort by design — a minutes-wide window against a roughly monthly release cadence.

## When to Apply

Apply this pattern when all three hold:

- **Security-critical tooling where patch latency beats reproducibility.** The tool handles secrets, credentials, or auth, and a pending upstream security fix is worse than a non-reproducible image tag. (`bw` is the archetype; the same reasoning would apply to a vault CLI or a signing tool.)
- **The vendor exposes a stable release API with per-asset digests.** The pattern's integrity gate depends on the API publishing `sha256:<hex>` per asset; without that field there is no fail-closed gate and the pattern degrades to trust-on-download.
- **The tool is a leaf, not a lockstep member of a toolchain.** Do not apply this to anything that must bump in lockstep with a companion. Ansible and ansible-lint are the repo's counter-example: ansible-lint tracks the last two Ansible majors, so its version is pinned and bumped in the same commit as Ansible's — unpinned resolution there would break the compatibility contract.

Do not apply it when byte-reproducible versioned tags are a requirement rather than a preference, or when the consumer needs to know exactly which version shipped before pulling.

## Examples

### The resolver core, as shipped

Quoted from the `Dockerfile` (the `printf '%s\n'` payload of the `bw` install RUN, reformatted from its one-argument-per-line form):

```python
json_path, arch, env_path = sys.argv[1], sys.argv[2], sys.argv[3]
suffix = "-arm64" if arch == "arm64" else ""
asset_re = re.compile(r"^bw-bit-linux" + re.escape(suffix) + r"-\d+\.\d+\.\d+\.zip$")
floor = (datetime.now(timezone.utc) - timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%S")
with open(json_path) as fh:
    releases = json.load(fh)
if not isinstance(releases, list):
    sys.exit("BW_RESOLVE_BAD_JSON: GitHub API response is not a release list")
skipped = []
for rel in releases:
    tag = rel.get("tag_name", "")
    if not re.match(r"^cli-v", tag):
        continue
    published = str(rel.get("published_at", ""))[:19]
    if published > floor:
        skipped.append(tag + " (published " + published + "Z)")
        continue
    assets = [a for a in (rel.get("assets") or []) if asset_re.match(a.get("name", ""))]
    if not assets:
        family = [a for a in (rel.get("assets") or []) if str(a.get("name", "")).startswith("bw-bit-linux")]
        if not family:
            sys.exit("BW_ASSET_RENAME: no bw-bit-linux-* asset on " + tag + " - asset family renamed upstream, update the regex in this RUN (precedent: cli-v2026.11.0 renamed bw-linux- to bw-bit-linux-)")
        sys.exit("BW_NO_ARCH_ASSET: bw-bit-linux assets exist on " + tag + " but none matches " + asset_re.pattern + " (vendor dropped this arch? upstream docs point arm64 at npm)")
    digest = assets[0].get("digest", "")
    if not re.match(r"^sha256:[0-9a-f]{64}$", digest):
        sys.exit("BW_DIGEST_ABSENT: assets[].digest missing or malformed on " + tag + " - failing closed, nothing installed")
    with open(env_path, "w") as fh:
        fh.write("export BW_TAG=" + shlex.quote(tag) + "\n")
        fh.write("export BW_VERSION=" + shlex.quote(tag[5:]) + "\n")
        fh.write("export BW_ASSET_URL=" + shlex.quote(assets[0]["browser_download_url"]) + "\n")
        fh.write("export BW_SHA256=" + shlex.quote(digest.split(":", 1)[1]) + "\n")
    print("BW_RESOLVE_OK: selected " + tag + " (published " + published + "Z)", file=sys.stderr)
    if skipped:
        print("BW_SKIPPED_TOO_YOUNG: below the 24h age floor: " + ", ".join(skipped), file=sys.stderr)
    sys.exit(0)
sys.exit("BW_NO_RELEASE: no cli-v release at least 24h old within the newest 30 (skipped as too young: " + (", ".join(skipped) if skipped else "none seen") + ")")
```

Execution and the rest of the shell chain, verbatim from the same RUN:

```dockerfile
&& python3 -I "${BW_RESOLVER}" "${BW_API_JSON}" "${TARGETARCH}" "${BW_ENV}" \
&& . "${BW_ENV}" \
```

### Smoke evidence from the implementing build

The resolution step selected `cli-v2026.11.1` — resolver logged `BW_RESOLVE_OK: selected cli-v2026.11.1`; the downloaded zip passed `sha256sum -c` against the API-published digest; `bw --version` matched the resolved version and `BW_NOINTERACTION=true bw status` exited 0; the dev container's acceptance checks ran green as the `vscode` user.

### Where the knowledge lives in the repo

- `Dockerfile` lines 752-887 — block banner (design, disclosures, triage table) and the install RUN; the first-party `bw-login` helper block (bash + PowerShell) follows immediately after.
- `CLAUDE.md` Key Conventions — the `bw` bullet recording the deviation decision and its accepted costs.
- `CONCEPTS.md` — the "Unpinned install" entry, which names the concept and contrasts it with the "Major-float pin" (the nearest pinned cousin, which still carries a version-bearing ARG and floats only point releases).

## Related

- `docs/solutions/tooling-decisions/postgresql-client-18-pgdg-major-float-pin.md` — nearest structural relative: the major-float pin keeps a version-bearing ARG and floats point releases; this pattern drops the ARG entirely. Both invert the weekly cacheless build into a delivery mechanism; this doc is that inversion carried one step further.
- `docs/solutions/tooling-decisions/azure-postgresql-root-cas-trust-store.md` — the sha256-gate precedent in its pinned static-artifact form, including the cache blind spot (a cached RUN does not re-execute checksum gates) that unpinned per-build resolution sidesteps inside the RUN.
- `docs/solutions/tooling-decisions/az-cli-extensions-system-install.md` — source of the supply-chain disclosure convention this pattern extends: disclose the residual trust honestly rather than engineering around a missing verification hook.
- `docs/solutions/tooling-decisions/ansible-lint-pipx-shared-venv-installation.md` — the anti-drift counterpart: frozen constraints hold versions fixed so upstream drift fails the build, where this pattern adopts drift on cacheless builds. Opposite ends of the drift-control spectrum; neither supersedes the other.
- `CONCEPTS.md` — "Unpinned install", "Major-float pin", "Version mirror", "Drift tripwire".
- `docs/plans/2026-11-27-001-feat-add-bitwarden-cli-plan.md` — the plan behind this feature (KTDs: unpinned decision, one API call, 24h floor, digest-as-same-host-integrity, tail placement).
- GitHub issue #14 (open) — proposed automated `.env.example`-vs-ARG mirror check; must treat ARG-less tools as in-scope-for-nothing.
