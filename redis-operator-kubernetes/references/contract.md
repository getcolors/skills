# The `RedisDeployment` contract

What the resource and the controller promise, as the pinned source defines
them — `crd.yml`, `green.kubernetes` (`reconcile-locked!`, `due?`,
`status`), `colors.redis` (`observation`, `converge`, `delete`,
`identity`) and `tools.clj` (`ready?`, `acknowledged-suspension?`,
`phase-line`). Nothing here is copied; read the files for the shape, this
for what the shape means.

## The resource

`redisdeployments.colors.getcolors.ai/v1alpha1`, namespaced, short name
`rd`, status subresource, printer columns `State`, `Phase`, `Profile`.

| Field | Default | Meaning |
|---|---|---|
| `spec.state` | `running` | the only value the CRD enum admits; the adapter's `validate` refuses anything else with `This release supports running state only` |
| `spec.suspend` | `false` | no new convergence; a pass in flight finishes. Never rendered by `build`, never reset by `create`; `rehearse` is the only verb that sets it |
| `spec.reconcileInterval` | `60s` | `^[1-9][0-9]*(ms|s|m|h)$`; `30s` on the verified deployment |
| `spec.deletionPolicy` | `Retain` | `Retain` removes the finalizer and leaves the Droplet; `Destroy` runs the package delete first. `delete` patches `Destroy` regardless of the committed value, because reaching `delete` means the guard was lifted |
| `spec.config` | required | the Redis package's flat desired state: `redis-image` (`tag@sha256:…`), `redis-port`, the five `redis-backup-*` keys, `digitalocean-region`/`-size`/`-image`, `digitalocean-ssh-sources` (public IPv4 `/32`s, at least one), `r2-bucket`, `r2-endpoint`; `provider-compute` and `provider-backend` are enums of one value |
| `spec.config.profile` | `<namespace>--<name>` | immutable once present (`self == oldSelf`), and presence itself is immutable (`has(self.profile) == has(oldSelf.profile)`) |
| `spec.config.r2-bucket`, `r2-endpoint` | required | immutable: the state backend identity |
| `metadata.annotations["colors.getcolors.ai/reconcile-request"]` | absent | an opaque token; a changed value schedules a pass and resets backoff; an unchanged manifest forces nothing |

Secrets never enter the resource. The controller reads exactly five
`COLORS_PAR_*` variables from the `redis-credentials` Secret and refuses
any other `COLORS_PAR_*` at startup (`Unexpected COLORS_PAR environment
override; desired configuration must come from the resource`). The
adapter fixes `workdir` to `/data/work`, the provider to DigitalOcean, the
backend to R2, `redis-storage-managed` to false, and keeps the package's
`compute-prevent-destroy` true during every converge; putting
`compute-prevent-destroy` in `spec.config` is a validation error (`Use
spec.deletionPolicy`).

## Status

Only controller-selected fields, never an exception message, a workflow
error or the opts map:

`phase`, `profile`, `stateIdentity` (a SHA-256 of `["r2" endpoint bucket
profile]`), `observedGeneration`, `lastHandledRequest`,
`lastReconcileTime`, `nextReconcileTime`, `retryCount`,
`deletionObserved`, and one condition `Ready` with `status`, `reason`,
`observedGeneration` and a `lastTransitionTime` that moves only when
status or reason change.

| Phase / reason | When |
|---|---|
| `Reconciling` / `Reconciling` | from the start of a due pass until its second observation; written before any side effect |
| `Ready` / `Converged` | the post-pass observation reports `matches?` and `ready?`; `nextReconcileTime = now + reconcileInterval` |
| `Failed` / `NotReady` | converged (or matched) but the post-pass observation is not ready; exponential backoff from 1 s to 60 s |
| `Failed` / `ExecutionFailed` | the converge or delete threw or returned non-zero; same backoff; also written after a transport error on the final publish, since the 409 branch never fires with the real client |
| `Failed` / `ValidationFailed` | the validator threw |
| `Invalid` / `InvalidConfiguration` | validation errors, a bad interval, state or policy; stays until spec or the request token changes |
| `Invalid` / `ImmutableStateIdentity` | the profile or state identity in status differs from the spec's; the original is preserved in status so a second edit cannot reset it |
| `Blocked` / `DestructionProtected` | deleting with `compute-prevent-destroy` true in the resource's config; unreachable through this adapter, whose validator refuses that key in `spec.config` (`Use spec.deletionPolicy`), so the resource goes `Invalid` first |
| `Suspended` / `Suspended` | `spec.suspend` true and not deleting; not due again until the spec changes |
| `Deleting` / `Deleting` | a Destroy pass in flight |

Two status writes per pass is the invariant every verb must survive:
`Reconciling` at the start, one of `Ready`/`Failed` at the end, each
moving `metadata.resourceVersion`. A no-op periodic pass writes both.

## Predicates the verbs use

- **`ready?`**: `metadata.generation` present and equal to
  `status.observedGeneration`, `phase = Ready`, and the `Ready` condition
  `True`. Polled, never read once (`wait-ready`).
- **`acknowledged-suspension?`**: `spec.suspend` true, not deleting,
  `phase = Suspended`, `observedGeneration = generation`. It means the pass
  that was running when suspension was requested has finished. It is
  checked once by `colors.probe/require-suspended!` before the rehearsal
  workflow runs, and not again.
- **`phase-line`**: `phase=<p> reason=<r> generation=<g> observed=<o>`
  plus ` suspended=true` and ` deleting=true` when set — the line every
  wait prints on each transition, and the text inside every wait error.

## Observation

`colors.redis/observation` returns `{:exists? :matches? :ready?}` from:

| Compute state (`compute-inspection/read-deployment`) | Result |
|---|---|
| `absent` or `destroyed` | `exists? false`, reason `absent`/`destroyed` — a create will run |
| `partial` | `exists? true`, `matches? false`, reason `partial` — a create may resume through the library's ownership protocol; a Destroy is refused by inspection |
| unreadable, or any exception | thrown: `Owned infrastructure state could not be read`; the pass fails, nothing is created |
| `present`, DigitalOcean GET `/v2/droplets/<id>` 404 | `exists?` false unless the event is `:delete` (shared firewall, key and state still exist), reason `droplet-absent` — the drill's recovery path |
| `present`, GET 200 with a different id or name | thrown: `Provider identity does not match owned state` |
| `present`, GET any other status | thrown: `DigitalOcean observation failed` |
| `present`, GET 200 | `ready?` = Droplet `active` and an authenticated `PING` over SSH (`BatchMode`, 10 s connect, 20 s overall) answers `PONG`; `matches?` = ready, and the PVC marker's config hash and provider ID equal the current ones, and `provider-matches?` (name, region slug, `size_slug`, `image.slug`, recorded public IP) |

Reasons logged: `converged`, `unhealthy`, `provider-drift`,
`new-provider-id`, `config-changed`. The controller converges when
`matches?` is false and reports `Ready` only when both `matches?` and
`ready?` are true afterwards; a matching but unhealthy Droplet is
`Failed/NotReady` without a converge.

`converge` runs the Redis package's create workflow with the merged
options and `:green/event :create`; on success it re-reads the compute
state, requires `present` with a provider ID, and writes the marker
atomically. `delete` requires `spec.deletionPolicy = Destroy` (`Destroy
must be explicitly selected`), lifts `compute-prevent-destroy` for that
run, and — when the Droplet answers 404 — runs a two-step
`ssh-config → compute` workflow instead of the package's full delete,
because no host exists to run the cleanup play on. Neither returns
workflow opts, credentials or captured output: `{:green/exit 0|1}`.

## Finalization

The controller adds `colors.getcolors.ai/infrastructure` before its first
side effect and removes it only after `observe` reports `exists? false`
following a `Destroy` delete, or immediately under `Retain`. The delete
verb removes the namespace after the resource is gone and the CRD only
when `kubectl get redisdeployments.colors.getcolors.ai -A` is empty. The
controller must outlive the finalizer: removing the Deployment first
leaves a resource nobody can finalize and a Droplet nobody manages.

## What the controller does not promise

One controller process, one worker, a process-local identity lock; no
distributed lease, no fencing of a disconnected old controller, no
checkpointing of a workflow, no exactly-once. Human or CI runs of the
Redis package against the same profile are not coordinated with the
controller beyond `colors-compute`'s journal lock on the infrastructure
stages; `rehearse` under acknowledged suspension is the sanctioned way to
run the package against a managed profile.
