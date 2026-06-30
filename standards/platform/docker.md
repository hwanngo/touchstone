# Containerization & Runtime Standards

Containerise the stack so `docker compose up -d --build` brings the whole app up
reproducibly. These are the rules every `Dockerfile`, compose file, and reverse-proxy config
should follow.

---

## 1. Golden rules

1. **Small, current base images, pinned by digest.** Prefer Debian `-slim` or `-alpine` (or
   distroless/Wolfi for runtime — §2). **Pin by digest** `image:tag@sha256:…` as the *default*,
   not just "when reproducibility matters" — tags are mutable and get silently re-pushed. Let
   Renovate/Dependabot raise PRs when digests move.
2. **Multi-stage builds.** Compile/build in a fat stage; copy only artifacts into a lean
   runtime stage (e.g. build with the SDK image, serve from a tiny runtime/web image).
3. **Run as a non-root user.** Every container drops privileges before `CMD`.
4. **Layer for cache.** Copy dependency manifests + install *before* copying source. Use
   BuildKit **cache mounts** for package managers and **secret mounts** for build-time creds —
   never build `ARG`s (§4).
5. **One `.dockerignore` per build context, at its root.** Exclude deps (`node_modules`,
   `.venv`), `.git`, build output, tests, and **secrets** (`.env`, `*.pem`, `*.key`, `.npmrc`)
   — keep `!.env.example`. (There is no per-directory `.dockerignore` — it's a single
   context-root file.) Verify with `docker run --rm <img> ls -la /`.
6. **Reproducible installs.** Use frozen/locked installs (`uv sync --frozen --no-dev`,
   `pnpm install --frozen-lockfile`). No unpinned `latest` *application* dependencies.
7. **Healthchecks** on long-running services; order startup with
   `depends_on: condition: service_healthy`.
8. **Least exposure.** Publish only the ports you must. Put app servers behind a reverse
   proxy on an internal network rather than exposing them directly.
9. **Proper PID 1.** Run an init (`init: true` / `--init`, or vendored `tini`) so signals
   forward and zombies get reaped — otherwise `docker stop` hangs 10s then SIGKILLs mid-request.

## 2. Base image policy

- Pick the **smallest image that still has what you need**. Reach for `-slim` first; use
  `-alpine` for static binaries, Node, and web servers where musl is fine. Be cautious with
  Alpine for ecosystems with heavy native wheels/binaries (e.g. some Python packages expect
  glibc/manylinux) unless you've verified them.
- **Prefer distroless / Wolfi for the runtime stage** of compiled or runtime-only services
  (`gcr.io/distroless/*:nonroot`, `cgr.dev/chainguard/*`): no shell or package manager → no
  in-container RCE pivot and near-zero CVE count. Both are glibc (Debian-compatible). Use
  `-slim`/`-alpine` when you need a shell or apk/apt at runtime; treat Alpine as an exception,
  not the default (musl causes subtle CGO/wheel/DNS issues).
- Track a **current** base (active distro release / language LTS) and bump it deliberately so
  you keep getting OS security patches — stale base images are the #1 source of image CVEs.
- Pin tool binaries you copy in (e.g. an installer image) by digest, not `latest`.

## 3. Security & runtime hardening

- **Non-root:** create a dedicated uid/gid and `USER` it before `CMD`; for web servers, run
  as the image's built-in unprivileged user (fix pid-file/cache/served dirs ownership as
  needed). New containers must do the same. Use `COPY --chown` to set ownership in a single
  layer — cleaner than a separate `RUN chown`:
  ```dockerfile
  COPY --chown=10001:10001 --link dist/ /app/
  ```
  `--link` decouples the layer from the base image filesystem, so the copy layer is
  cache-stable across base-image bumps (BuildKit only). Use it for artifact copies in the
  runtime stage.
- **No secrets in images or layers.** Configuration comes from runtime env vars (compose
  `environment:` / an ignored `.env`, with a committed `*.example` template). Never `COPY` a
  real `.env` or any secret into an image.
- **Writable paths are explicit and owned by the runtime user** (upload/output dirs);
  everything else stays read-only where possible.
- **Runtime hardening baseline** (compose) — defense-in-depth against post-exploitation:
  ```yaml
  services:
    app:
      read_only: true                          # immutable rootfs; blocks dropping a payload
      tmpfs: ["/tmp:size=64m,mode=1777"]        # writable scratch only where needed
      cap_drop: [ALL]                           # cap_add only what genuinely breaks
      security_opt: ["no-new-privileges:true"]  # neuter setuid escalation
      user: "10001:10001"
      init: true
      deploy: { resources: { limits: { cpus: "1.0", memory: 512M, pids: 200 } } }
  ```
  (`deploy.resources.limits` now applies under plain `docker compose up` — prefer it over the
  old `mem_limit`/`pids_limit`.)
- **Never** `privileged: true`, and **never** bind-mount `/var/run/docker.sock` (= host root,
  read-only doesn't help). Keep backend services on an `internal: true` network.

## 4. Backend / service images

- **Start every Dockerfile with `# syntax=docker/dockerfile:1`** — it unlocks BuildKit
  `--mount` features and decouples Dockerfile syntax from the Engine version.
- **BuildKit cache mounts** speed installs without bloating layers; **secret mounts** replace
  the build-`ARG`-secret anti-pattern (ARGs are permanently recoverable from the image):
  ```dockerfile
  # syntax=docker/dockerfile:1
  RUN --mount=type=cache,target=/root/.cache/uv uv sync --locked --no-dev
  RUN --mount=type=secret,id=token,env=TOKEN  pip install --extra-index-url=...   # never an ARG
  ```
  ```bash
  docker build --secret id=token,env=TOKEN .
  ```
  (On Debian, `rm -f /etc/apt/apt.conf.d/docker-clean` or the apt cache mount is defeated.)
- Set the build context to whatever the image legitimately needs (sometimes the repo root,
  not the service subdir) — and document the exact `docker build -f … <context>` command.
- For Python: enable bytecode compile and copy-link mode for the installer, and run
  unbuffered (`PYTHONUNBUFFERED=1`).
- **Match worker/replica count to the app's state model.** An app holding in-memory state or
  streaming SSE may require a single worker — scale via shared state + replicas only after
  that constraint is removed. Make this explicit in the `CMD`/comments.

## 5. Frontend / static + reverse proxy

- Build the SPA bundle, then serve it from a tiny web server (e.g. nginx-alpine).
- The web server config should do **SPA history-API fallback** to `index.html` **and reverse-
  proxy the API** (including SSE — disable proxy buffering, raise read timeouts for streams).
  Keep the fallback and API proxy in sync with the app's routes.
- Content-hashed assets are safe to long-cache; **never long-cache `index.html` or the
  service worker.**
- **Don't expose source maps.** Deny them at the web server as defense-in-depth
  (`location ~ \.map$ { return 404; }`) — production builds shouldn't emit `.map` files, but
  this guards against a regression leaking original source. Pair with security headers
  (`X-Content-Type-Options: nosniff`, a strict `Content-Security-Policy`, `server_tokens off`).

## 6. Compose

- One file for the whole stack, plus named volumes for persistent/writable data.
- Give long-running services a **healthcheck**; have dependents wait on
  `condition: service_healthy`.
- Publish only the user-facing entry point; keep internal services on the compose network.
- Surface tunables via an ignored `.env` with a committed `*.example` template; document new
  knobs there.

```bash
docker compose up -d --build      # build + run everything
docker compose logs -f <svc>      # tail logs
docker compose down               # stop (add -v to drop volumes)
```

## 7. Healthcheck depth

A mistuned healthcheck is worse than none (it flaps slow-booting apps into restart loops):
```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --start-interval=2s --retries=3 \
  CMD ["/app", "--health"]    # exec form, shell-free — `curl`/shell form fails on distroless
```
`--start-interval` (Engine 25+) keeps a generous start grace while flipping healthy in seconds.
A compose `healthcheck:` is required for `depends_on: service_healthy` to fire. Set `STOPSIGNAL`
when the app drains on a non-default signal (e.g. nginx → `SIGQUIT`).

## 8. Build pipeline (CI)

- **Lint the Dockerfile** with **hadolint** (catches `latest` tags, unpinned installs, root) —
  also a pre-commit hook.
- **Scan the built image** with Trivy/Grype (see [security.md](../practices/security.md)); fail on
  high/critical.
- **Attach SBOM + provenance and sign** for published images:
  `docker buildx build --sbom=true --provenance=mode=max --push` then `cosign sign` the digest.
  Attestations are unsigned by default — pair with cosign or they convey no trust. `mode=max`
  embeds build-args, so only use it alongside secret mounts (§4).
- **Multi-arch** where the fleet is mixed (Apple Silicon dev / arm64 prod):
  `docker buildx build --platform linux/amd64,linux/arm64 --push`.
- **OCI labels** auto-generated by `docker/metadata-action` make images self-describing
  (source repo, revision, version).

## 9. Image-size budget

"Keep images small" is not actionable. Set hard numbers and check them in CI.

| Language / role | Target | Hard fail |
|---|---|---|
| Go + distroless | < 30 MB | > 50 MB |
| Node runtime (distroless/slim) | < 200 MB | > 300 MB |
| Python slim | < 250 MB | > 350 MB |
| Nginx static server | < 50 MB | > 80 MB |

**Measure in CI** after every build:
```bash
# Quick gate — fails the step if size exceeds threshold
SIZE=$(docker image inspect "$IMAGE" --format '{{.Size}}')
MAX=$((30 * 1024 * 1024))
[ "$SIZE" -le "$MAX" ] || { echo "Image too large: $((SIZE/1024/1024)) MB"; exit 1; }
```

**Drill into layers with `dive`** _(scale-up — run locally or as a non-blocking CI step)_:
```bash
CI=true dive "$IMAGE"   # exits non-zero if image efficiency < 90 %
```
`dive` surfaces wasted space — duplicate files, `.git` blobs left in a layer, un-cleaned
package caches. Fix by moving the clean step into the same `RUN` or using BuildKit cache mounts (§4).

What balloons images: copying `node_modules` into the runtime stage, leaving build tools
(`gcc`, `cargo`) in the runtime stage, and multi-step `RUN` chains that install then delete
in separate layers (each `RUN` is an immutable layer — delete in the same `RUN` or it stays).

## 10. Registry hygiene / retention

Tag sprawl and stale images are a cost, attack-surface, and cognitive-load problem.

**Immutable tags** — never re-push `latest` or a version tag in production registries.
Use content-addressed refs (`image@sha256:…`) or unique build tags (`git-<sha>`, `v1.2.3-build.42`).
`latest` is fine as a convenience alias locally; ban it in deploy manifests.

**Lifecycle policy (IaC — not a one-time console click):**

| Policy | Recommended default |
|---|---|
| Untagged / dangling images | Delete after **7 days** |
| Tagged non-release builds | Keep last **20** per repo/branch; delete the rest |
| Release tags (`v*`) | Keep **all** (or last 90 days + N releases) |
| Total repo size cap | Alert at 10 GB, hard cap at 20 GB _(scale-up)_ |

Example (AWS ECR lifecycle, Terraform-managed — adapt to GCR/GHCR/Harbor):
```hcl
resource "aws_ecr_lifecycle_policy" "default" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 20 non-release tagged images"
        selection    = { tagStatus = "tagged", tagPrefixList = ["git-"], countType = "imageCountMoreThan", countNumber = 20 }
        action       = { type = "expire" }
      },
    ]
  })
}
```

Also:
- **Prune build-node local cache** in CI (`docker buildx prune --keep-storage 10gb`) to
  avoid disk exhaustion on long-lived runners.
- **GHCR / GCR / Harbor** equivalents exist as `packages` retention policies or GCP Artifact
  Registry cleanup rules — manage them in the same IaC repo as the registry resource.
- Cross-link lifecycle policy to [ci-cd.md](ci-cd.md) build/publish job that creates the tags.

## Definition of done

- [ ] Base image is `-slim`/`-alpine`/distroless, current, and **digest-pinned**
- [ ] `# syntax=docker/dockerfile:1`; secrets via mounts, never ARGs
- [ ] Multi-stage; runtime stage contains only what it needs
- [ ] Runs as a non-root user (`COPY --chown=10001:10001`) with `init`, read-only rootfs, `cap_drop: [ALL]`, `no-new-privileges`
- [ ] Dependency install is `--frozen` / `--frozen-lockfile`
- [ ] One root `.dockerignore` excludes deps, VCS, secrets, build output, tests
- [ ] No secrets baked into image or layers; no `privileged`/docker.sock
- [ ] Tuned healthcheck (exec-form); `depends_on: service_healthy`
- [ ] hadolint clean; image scanned; published images carry signed SBOM + provenance
- [ ] Image size within budget for language (§9); `dive` efficiency ≥ 90 %
- [ ] Registry has an IaC lifecycle policy: untagged → 7 days, non-release → keep last 20 (§10)
- [ ] `docker compose up --build` brings the stack up clean
