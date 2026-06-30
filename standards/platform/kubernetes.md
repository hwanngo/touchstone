# Kubernetes Standards

The canonical home for **how a workload runs on Kubernetes**: manifests, resources, probes, pod
hardening, networking, scaling, rollouts, and the policy that enforces them. [./devops.md](./devops.md)
summarises k8s as one layer of the platform and **defers the depth here**; the image you ship is
governed by [./docker.md](./docker.md), telemetry by [./observability.md](./observability.md),
supply-chain/admission by [../practices/security.md](../practices/security.md), and in-process
failure behaviour (timeouts, retries, graceful shutdown) by [../design/resilience.md](../design/resilience.md).

> **One law:** the cluster is a control loop, not a server — declare the desired state, make every
> object reconcilable from git, and let the scheduler converge. If a fix only exists as a live
> `kubectl edit`, it doesn't exist.
>
> **Scope:** items tagged _(scale-up)_ are for teams running real production traffic on a shared
> cluster — adopt them as you grow. Workload shape, resources, probes, and `securityContext` apply
> to any deployed pod.

---

## 1. Pick the right workload kind

Default to a **Deployment**; reach for the others only when the workload's identity or lifecycle
demands it. The wrong kind is a rollout that corrupts data or a job that never stops.

| Kind | Use for | Why not a Deployment |
|---|---|---|
| **Deployment** | stateless services (HTTP/gRPC, workers) | the default — fungible, interchangeable pods |
| **StatefulSet** | stable identity / ordered start / per-pod PVC (databases, brokers, quorum systems) | needs stable network ID + own volume; ordered, non-fungible |
| **DaemonSet** | one pod per node (log shipper, CNI, node agent) | scheduling is per-node, not by replica count |
| **Job** | run-to-completion batch (migration, backfill) | a Deployment restarts a finished pod forever |
| **CronJob** | scheduled Jobs (reports, cleanup) | set `concurrencyPolicy: Forbid` + `startingDeadlineSeconds` |

- **Prefer an external managed datastore over a self-hosted StatefulSet** unless you have the
  operator expertise — running stateful systems on k8s is a senior commitment, not a default.
- **Standard `app.kubernetes.io/*` labels on every object** (name/instance/version/component/
  part-of/managed-by) — they drive selectors, dashboards, cost allocation, and NetworkPolicy/PDB.

## 2. Resources: requests always, limits with nuance

Getting this wrong is the #1 cause of both throttled-but-idle services and OOMKills.

- **Always set CPU + memory requests** — they drive scheduling and the QoS class. No requests means
  `BestEffort`, the first pod evicted under pressure.
- **Don't set a CPU limit on latency-sensitive services.** CPU is compressible; a limit throttles
  you via CFS *below* available idle capacity for no benefit, adding tail latency. The request
  already guarantees a floor.
- **Set memory limit = memory request.** Memory is non-compressible — over-request and you get
  OOMKilled unpredictably; equal request/limit gives a `Guaranteed` QoS pod that's evicted last.
- **Right-size from data, not vibes** — run **VPA in recommender-only mode** (or Goldilocks) to size
  requests; never run VPA and HPA on the same metric (they oscillate — see §7).

```yaml
resources:
  requests: { cpu: "250m", memory: "256Mi" }
  limits:   { memory: "256Mi" }            # mem limit == request; NO cpu limit
```

## 3. Probes: the three do different jobs — don't conflate them

| Probe | Question | On failure | Hard rule |
|---|---|---|---|
| **startup** | finished booting? | keep waiting, then kill | use this for slow boots, **not** a huge `initialDelaySeconds` |
| **liveness** | wedged and unrecoverable? | **restart the pod** | **never check an external dep** |
| **readiness** | ready for traffic *right now*? | pull from Service endpoints | **does** check deps it can't serve without |

- **Liveness must be cheap, local, and dependency-free.** If liveness pings the DB or a downstream,
  one dep outage restarts every pod at once — a self-inflicted cluster-wide crash loop. It answers
  "is *this process* deadlocked?", nothing more.
- **Readiness is the traffic gate** — fail it when a dependency is down so the pod drains instead of
  serving errors, and it recovers without a restart. (`/healthz` = liveness, `/readyz` = readiness,
  per [./observability.md](./observability.md).)
- **Pair readiness with graceful shutdown:** a `preStop` sleep + `SIGTERM` drain so in-flight
  requests finish before the pod exits — connection draining is a [../design/resilience.md](../design/resilience.md)
  concern the manifest must honour.

## 4. Hardened pods, enforced by Pod Security Admission

Every pod runs as the locked-down default; the namespace *enforces* it so a careless manifest can't
opt out.

```yaml
securityContext:                    # pod or container level
  runAsNonRoot: true
  runAsUser: 10001
  allowPrivilegeEscalation: false   # neuter setuid escalation
  readOnlyRootFilesystem: true      # immutable rootfs; mount an emptyDir for scratch
  capabilities: { drop: ["ALL"] }   # add back only what genuinely breaks
  seccompProfile: { type: RuntimeDefault }
```

- **Label every namespace `restricted`** with Pod Security Admission — the in-tree successor to the
  removed PodSecurityPolicy (gone since 1.25):

  ```yaml
  # namespace labels
  pod-security.kubernetes.io/enforce: restricted
  pod-security.kubernetes.io/enforce-version: latest
  ```
- **PSA is a coarse baseline, not the whole story.** Use **Kyverno or OPA Gatekeeper** for policy it
  can't express — block `hostPath`, `:latest`, missing probes/limits, and unsigned images (§11).
- This is the runtime half of the [./docker.md](./docker.md) image hardening (non-root, read-only,
  `cap_drop: [ALL]`); the two must agree or the pod won't start.

## 5. Images: pinned by digest, verified at admission

- **Reference images by digest** (`image@sha256:…`), never `:latest` — tags are mutable and get
  silently re-pushed. Let Renovate/Dependabot raise PRs as digests move.
- **Verify signatures at admission so an unsigned or foreign-built image never schedules.** CI signs
  (keyless cosign) per [../practices/security.md](../practices/security.md); the cluster must *check*
  it — Kyverno `verifyImages` with the pinned keyless `subject`/`issuer`, which also mutates tag →
  verified digest in one step. Full policy in [./devops.md](./devops.md).

## 6. Config and secrets: ConfigMaps in git, secrets never

- **Non-secret config → ConfigMap** (or a baked default), mounted as files or env. Treat a ConfigMap
  change as a deploy: **roll pods on change** (checksum annotation, or Reloader) — k8s does *not*
  restart pods when a mounted ConfigMap updates.
- **No plaintext Secrets in git — non-negotiable.** A base64 `Secret` is *encoded*, not encrypted.
  Pick per context: **External Secrets Operator** + a cloud secret manager (the GitOps default),
  **SOPS+age** (platform-agnostic file encryption), **Sealed Secrets** (simple, cluster-locked), or
  **Vault** (dynamic, short-lived). Pair with rotation. Full posture: [../practices/security.md](../practices/security.md).
- **Enable etcd encryption-at-rest** (KMS provider, not `aescbc` with a static key) and lock Secret
  RBAC down — `get secrets` is a credential-theft primitive.
- **Mount secrets as files over env vars** — env leaks into crash dumps, `/proc`, and child
  processes; a `tmpfs`-backed file also rotates without a restart.

## 7. Scaling: autoscale on SLO signals, protect availability

- **HPA scales replicas on the metric that reflects user pain**, not raw CPU. Drive it from
  **custom/external SLO metrics** (RPS, p99 latency, queue depth) via Prometheus Adapter or
  **KEDA** _(scale-up)_ for event-driven sources (Kafka lag, SQS depth, cron).
- **PodDisruptionBudgets cap voluntary disruption** so a node drain or rollout can't evict the whole
  service. Size it against the rollout surge: `replicas − maxUnavailable ≥ minAvailable`. _(scale-up)_
  PDBs don't protect against node *failure* — only voluntary evictions.
- **Spread replicas across failure domains** with `topologySpreadConstraints` (zone + node) so one
  AZ or node loss doesn't take a quorum:

  ```yaml
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
      labelSelector: { matchLabels: { app.kubernetes.io/name: checkout } }
  ```
- **Keep node headroom** (Karpenter/cluster-autoscaler + low-priority pause Pods) so a scale-up
  isn't gated on cold node boot _(scale-up)_.

## 8. Rollouts: readiness-gated, surge-bounded

- **`RollingUpdate` with explicit surge math.** `maxSurge`/`maxUnavailable` decide how fast and how
  safely; the rollout only advances as new pods pass **readiness** (§3) — a broken build that never
  goes Ready stalls instead of taking traffic.

  ```yaml
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 25%, maxUnavailable: 0 }   # never drop below desired during a roll
  ```
- **`minReadySeconds`** stops a Ready-then-crash pod counting as healthy; set `revisionHistoryLimit`
  so rollback targets exist without piling up.
- **Database migrations are expand/contract / N-1 compatible** — a rolling update runs two versions
  at once. Schema changes follow add-new → backfill → switch → drop-old across releases (see
  [./devops.md](./devops.md)).
- **Metric-gated progressive delivery** (Argo Rollouts / Flagger) auto-rolls-back on golden-signal
  breach _(scale-up)_ — the canary gate *is* your SLO burn-rate query ([./observability.md](./observability.md),
  [./devops.md](./devops.md)).

## 9. Networking: default-deny, then allow what you mean

- **A default-deny NetworkPolicy per namespace** on a policy-capable CNI (**Cilium**/Calico) — pods
  are flat-network-reachable by default, which is an east-west breach waiting to happen. Deny all
  ingress *and* egress, then **always allow DNS egress** (or every pod breaks), and add explicit
  allows per dependency.

  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata: { name: default-deny }
  spec:
    podSelector: {}                 # all pods in the namespace
    policyTypes: [Ingress, Egress]  # empty rules below = deny both directions
  ```
- **Services:** `ClusterIP` for internal; never `NodePort` in production; `LoadBalancer` only at the
  edge. Use a **headless** Service for StatefulSet peer discovery.
- **Ingress → Gateway API.** The **Gateway API** is the GA successor to Ingress (role-oriented,
  expressive, portable) — prefer it for new clusters; Ingress-NGINX remains fine for existing ones.
  Terminate TLS with **cert-manager** (ACME / DNS-01 for wildcards).
- **mTLS east-west** via a service mesh (Linkerd / Istio ambient) so identity is cryptographic, not
  network-position _(scale-up)_ — see [../practices/security.md](../practices/security.md).

## 10. Packaging: Helm for third-party, Kustomize for your own

Pick per source — **don't blur the two**, and don't template YAML with `sed`.

| You're shipping | Tool | Why |
|---|---|---|
| a third-party chart, or anything needing `helm rollback`/release lifecycle | **Helm** | versioned releases, hooks, ecosystem charts |
| your own app across dev/stage/prod | **Kustomize** | base + per-env overlays, no templating language, `kubectl`-native |

- **Render, don't trust blindly.** `helm template` / `kustomize build` in CI and lint the *output*
  (§11) — review the YAML that actually applies, not the inputs.
- **Pin chart and `appVersion`**; vendor third-party charts or pin by digest so an upstream re-push
  can't change prod. GitOps (Argo CD/Flux) renders and reconciles — promotion is a PR
  ([./devops.md](./devops.md)).

## 11. Policy and lint: gate manifests in CI

The manifest is code — it gets the same shift-left treatment as [../practices/security.md](../practices/security.md).

```bash
kubeconform -strict -summary manifests/        # schema + CRD validation
kube-linter lint manifests/                    # best-practice / security (no limits, root, etc.)
kubectl apply --dry-run=server -f manifests/   # admission-time validation against the live API
```

- **`kubeconform -strict`** (schema) + **`kube-linter`** (security/best-practice) as blocking CI
  jobs. _(kubeval and datree are unmaintained — don't adopt either.)_
- **Admission policy is the runtime backstop:** **Kyverno** (Kubernetes-native YAML policies) or
  **OPA Gatekeeper** (Rego) reject privileged/`hostPath`/`:latest`/unsigned/limit-less pods at the
  API server. Run policies in `Audit` first, then flip to `Enforce`.
- **Built-in `ValidatingAdmissionPolicy`** (CEL, GA in 1.30) covers simple rules with no external
  controller — prefer it for the basics, Kyverno/Gatekeeper for the rest.

## 12. Namespaces and multi-tenancy

- **Namespace per team/service-group as the unit of isolation** — it scopes RBAC, quota, network
  policy, and PSA labels. One flat `default` namespace is a blast-radius and noisy-neighbour problem.
- **`ResourceQuota` + `LimitRange` per namespace** _(scale-up)_ so one tenant can't starve the
  cluster, and pods without explicit requests inherit a sane default instead of `BestEffort`.
- **RBAC is least-privilege and namespaced.** No wildcard `cluster-admin`; humans authenticate via
  OIDC, workloads via pod-bound ServiceAccount tokens ([../practices/security.md](../practices/security.md));
  disable default-SA token automount where unused.
- **Hard multi-tenancy needs more than namespaces** — vCluster or separate clusters for untrusted
  tenants; a namespace is a *soft* boundary _(scale-up)_.

## 13. Observability hooks

Wiring only — the signal model, SLOs, and alerting policy are owned by [./observability.md](./observability.md).

- **Scrape via annotations or a `ServiceMonitor`/`PodMonitor`** (Prometheus Operator); expose
  `/metrics` (OpenMetrics) on every workload. Emit **RED** per service, **USE** per resource.
- **Logs are JSON to stdout** — the platform ships them; the pod never writes files. Required fields
  incl. `trace_id`/`span_id`; the OTel Collector (agent DaemonSet → gateway) is the single egress.
- **Alert on SLO burn-rate, never raw pod CPU.** A throttled pod with no CPU limit (§2) is *fine* by
  design — paging on it is a false alarm. Every page links a runbook.

## Definition of done

- [ ] Correct workload kind (Deployment default; StatefulSet/Job/DaemonSet/CronJob only when
      justified); standard `app.kubernetes.io/*` labels on every object
- [ ] **Requests always set; no CPU limit on latency-sensitive svcs; memory limit = request**;
      right-sized via VPA-recommender (not VPA+HPA on one metric)
- [ ] Probes correct: **liveness dependency-free**, readiness gates traffic, startup for slow boots;
      `preStop` drain for graceful shutdown
- [ ] `securityContext` hardened (runAsNonRoot, readOnlyRootFilesystem, drop ALL, seccomp
      RuntimeDefault, no privilege escalation); namespace **PSA `enforce: restricted`**
- [ ] Images **digest-pinned**, signatures **verified at admission** (Kyverno `verifyImages`)
- [ ] Config in ConfigMaps (pods roll on change); **no plaintext Secrets** (ESO/SOPS/Sealed/Vault);
      etcd encryption-at-rest; secret RBAC locked down
- [ ] **Default-deny NetworkPolicy** per namespace (DNS egress allowed); ClusterIP internal; Gateway
      API/Ingress with cert-manager TLS
- [ ] HPA on SLO/custom metrics (KEDA for events); **PDB sized against surge**; topology spread
      across zones _(scale-up)_
- [ ] `RollingUpdate` surge bounded + readiness-gated; `minReadySeconds`; migrations N-1 safe;
      progressive delivery SLO-gated _(scale-up)_
- [ ] Manifests gated in CI: **kubeconform -strict + kube-linter + server dry-run**; admission policy
      (Kyverno/Gatekeeper/VAP) in Enforce
- [ ] Namespace-per-tenant with RBAC + ResourceQuota/LimitRange _(scale-up)_; no wildcard admin
- [ ] Metrics scraped (ServiceMonitor, RED/USE); JSON logs to stdout with `trace_id`; **SLO burn-rate
      alerts, not raw-CPU pages**

**Sources:** [Kubernetes docs — Configuration best practices](https://kubernetes.io/docs/concepts/configuration/overview/) · [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) · [Production best practices (Learnk8s)](https://learnk8s.io/production-best-practices) · [Gateway API](https://gateway-api.sigs.k8s.io/) · [Kyverno](https://kyverno.io/policies/)
