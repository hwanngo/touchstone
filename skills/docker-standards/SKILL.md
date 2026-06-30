---
name: docker-standards
description: Use when writing or editing Dockerfiles, docker-compose, reverse-proxy config, base images, or container build/runtime setup in a repo that follows touchstone. Invoke before changing how images are built, run, or wired together.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# Containerization & Runtime Standards

Full standard: **`standards/platform/docker.md`** in the touchstone repo. This skill inlines the
load-bearing rules so it stays useful even when installed standalone in `~/.claude/skills/`:

## Always
- **Small, current base images pinned by digest**; prefer **distroless/Wolfi** for runtime, `-slim`/`-alpine` when you need a shell.
- **Multi-stage**; lean runtime stage. **`# syntax=docker/dockerfile:1`** + BuildKit **cache mounts** and **secret mounts** (never build-ARG secrets).
- **Non-root user** + `init` (PID 1) + **read-only rootfs** + `cap_drop: [ALL]` + `no-new-privileges` + resource limits.
- **Frozen installs**; one root `.dockerignore` (deps, `.git`, secrets, output, tests).

## Don't get burned
- **Never** `privileged: true` or bind-mount `/var/run/docker.sock`. Keep backends on an `internal:` network.
- Tune the **healthcheck** (exec-form, shell-free for distroless); required for `depends_on: service_healthy`.
- Match worker/replica count to the app's state model (in-memory/SSE may force a single worker).
- Lint with **hadolint**; scan the image (Trivy/Grype); published images get signed **SBOM + provenance**.

## Done
Digest-pinned `-slim`/distroless · multi-stage · non-root + hardened · frozen install · hadolint clean · scanned · `compose up --build` clean.
