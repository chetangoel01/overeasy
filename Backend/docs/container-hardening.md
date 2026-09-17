# Production container hardening

## Purpose

Keep the API, worker, Beat, and migration runtime reproducible, bounded, and
useful on platforms that supply their own HTTP port or S3-compatible storage.

## Image contract

- Python 3.12.13 slim Bookworm and the uv tool image are pinned by immutable
  multi-platform digest.
- Debian packages resolve through the 2026-09-07 snapshot. `ca-certificates`
  and `ffmpeg`, plus the libexpat1 and libpcre2 security updates, are pinned to
  exact versions, so an identical source tree
  cannot silently acquire different OS packages.
- The final process runs as UID 10001 and writes caches only beneath `/tmp`.
- uv's build cache is a BuildKit cache mount and is absent from runtime layers.
- The image has an API readiness `HEALTHCHECK`; worker services replace it with
  a Celery ping and one-shot/scheduler services disable it.
- The entrypoint validates the hosting platform's bare `PORT` variable and
  defaults to 4111.
- The build context excludes Git state, environment files, tests, docs, load
  harnesses, local Compose configuration, evaluation artifacts, cookies,
  caches, and local databases.

Changing a base digest or snapshot is a deliberate dependency update. Rebuild,
run the complete suite, produce a fresh SBOM, and scan the resulting digest
before release.

## Runtime contract

The Compose runtime anchor applied to API, worker, Beat, and migrations:

- makes the root filesystem read-only and supplies a 256 MB temporary
  filesystem;
- drops every Linux capability and enables `no-new-privileges`;
- bounds CPU, memory, processes, open files, temporary disk, and individual
  file size.

Production platform manifests must preserve equivalent or stricter controls,
including the platform's default seccomp/AppArmor profile. Writable object data
belongs in managed object storage, never in the container filesystem.

## Storage compatibility

`LADLE_OBJECT_STORAGE_ADDRESSING_STYLE` accepts `auto`, `path`, or `virtual`.
Local MinIO explicitly uses `path`; Railway-style buckets use `virtual`.
Both the internal client and public presigning client receive the same setting.

## Verification

Unit tests inspect immutable image inputs, exclusions, sandbox limits, port
validation, and storage addressing. The release pipeline builds the exact
Dockerfile, scans OS and Python packages, emits an SBOM and provenance, and
signs only the immutable production digest.

## September 17 PCRE2 repair

The image gate reported CVE-2026-86145, CVE-2026-89157, and CVE-2026-89161 in
`libpcre2-8-0` 10.42-1 inherited from the pinned Python base. Debian's
[Bookworm security update](https://security-tracker.debian.org/tracker/CVE-2026-89157)
fixes these in 10.42-1+deb12u1. The Dockerfile explicitly installs that version
from the existing September 7 snapshot, including when media tools are
disabled. No broad base-image or dependency update is needed.

Verification: the original GitHub image scan reported the three findings.
The repaired Linux amd64 image builds and Trivy 0.72.0 reports zero fixable
HIGH/CRITICAL findings across OS and Python packages. The full baseline
backend suite passes (1,107 tests), and the locked Python dependency audit
reports no known vulnerabilities. The local Compose manifest validates.
