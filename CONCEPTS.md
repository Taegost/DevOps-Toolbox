# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ts-compound and ts-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Tool installation conventions

### ARG-per-block convention
Each tool's version `ARG` is declared directly above its own install block in the Dockerfile, never grouped at the top. A version bump for one tool invalidates the Docker layer cache from that tool's block downward only — the isolation property the layout exists for.
*Avoid:* version pin grouping

### Version mirror
The committed env-file template that mirrors every version `ARG`'s default value, so a local build can pass all pins as build args and a reader can see current tool versions at a glance. A Dockerfile `ARG` without a mirror entry (or vice versa) is drift; values must match exactly.

### Smoke test
The full local Docker build of the image, run before any Dockerfile change may be opened as a PR. It is the repo's only build validation step, so an in-build assertion failing is the same as a test failing. PRs are additionally gated on explicit maintainer approval after the smoke test passes — the build alone never authorizes opening a PR.
