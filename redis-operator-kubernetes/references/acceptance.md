# Acceptance doctrine

What each verb and gate checks, what its pass proves, and what it does
not. All of these ran on `redis-operator-doks` on 2026-09-16 at the pins
in `pins.md`; the 2026-09-15 rows are the script-driven predecessors and
say where they proved less.

## `create`

| Step | Checks |
|---|---|
| preflight | the five credentials present; `COLORS_PAR_PROFILE` absent; `image` carries `@sha256:`; SSH sources are public `/32`s; the config block passes the Redis package's own validators as the controller will merge it |
| namespace, Secret | the Secret goes to `kubectl apply -f -` on stdin with output suppressed |
| pull Secret | waits up to 120 s for the named Secret DOKS integration injects; an auth or context error fails at once |
| install | `kubectl wait --for=condition=Established crd/…` (60 s), `rollout status` (600 s) |
| resource | refuses (exit 1) a suspended resource — an apply would not reset `spec.suspend`, but converging over a rehearsal is what suspension forbids — and a deleting one |
| ready | polls up to 45 min, 15 s apart, tolerating `Failed` passes, until Ready at the current generation |

Verified 2026-09-16: Droplet `600954837` Ready/Converged at generation 1
after one failed Ansible attempt and a converged retry. A second create
against a healthy deployment (the image roll to digest 2) rolled the
controller and ran no Redis create: the new pod observed `matches=true`.

## `check`

| Gate | Checks | Proves |
|---|---|---|
| C1 Ready | `wait-ready`: 5 s poll, 180 s bound, Ready at the current generation; `Failed`, `Invalid`, `Blocked`, suspension, deletion are fatal | the controller has observed this spec and judged it converged at least once since — not that it is Ready at the instant you read it |
| C2 controller up | `controller-up!`: exactly one running pod whose log since `startTime` carries `RedisDeployment controller running` | the pod you are about to exec into has loaded the controller |
| C3 health probe | `bb -m colors.probe … health` inside the pod: an authenticated `PING` over SSH answers `PONG`; prints provider ID, name, IP, profile | the Droplet the state names is the one answering |
| C4 failures | `ls -1 /data/work/<profile>/failures` inside the pod; prints `failures retained: N newest=<file>` | whether a converge or delete has failed since the directory was last emptied |

Observed after the restart fix: 20 s, `failures retained: 0`.

## `rehearse`

| Step | Checks |
|---|---|
| R0 | Ready at the current generation |
| R1 suspend | `spec.suspend=true` by resourceVersion-tested patch (retried on a status-write 422); record `suspendedGeneration` |
| R2 acknowledge | poll 3 s, up to 130 min, for `phase=Suspended` at that generation, refusing a resource whose UID or generation moved |
| R3 rehearsal | `probe … rehearse` inside the pod: `require-suspended!` once, then the Redis package's `rehearse` workflow — a fresh backup set, restored into a scratch container with the AOF off, the deployment's own smoke key read back, the recovery marker written (the `redis-single-node` doctrine) |
| R4 resume | only when the resource is exactly as left and the remote outcome is certain; otherwise `resource left suspended; verify no workflow runs before resuming`, exit non-zero, and the reason in `resumeBlocked` |
| R5 | Ready again at the new generation |

Verified 2026-09-16: suspended at generation 2 (`07:55:15`), acknowledged
`07:55:18.85`, `rehearsalPassed: true`, resumed at generation 3
(`07:56:00`). 2026-09-15: generations 4 → 5. A kubectl termination during
R3 cannot prove the remote workflow stopped, so it blocks the resume
rather than mask the error.

## `drill`

| Gate | Checks |
|---|---|
| D0 authorization | `COLORS_PAR_DRILL_DELETE_OWNED_DROPLET=true` exactly, and `COLORS_PAR_DO_TOKEN`; exit 2 otherwise |
| D1 ownership | recorded `providerId` is numeric and equals the live Droplet's `id`; profile = Droplet name = probe name; the ID is not in any node pool of `doks-cluster-id` and the Droplet has no `k8s:` tag; the recorded IP is among its public v4 addresses |
| D2 marker | `SET colors:self-heal:<uuid> <uuid>` and `GET` through the authenticated probe |
| D3 delete | one `DELETE /v2/droplets/<id>`; `deleteAcceptedAt` recorded before waiting |
| D4 recovery | poll 15 s, up to 40 min: a probe with a different `providerId`, `healthy`, Ready at the unchanged UID and generation; D1 re-run on the replacement; the old ID answers 404; the prior marker read; a fresh marker written and read |
| D5 evidence | `self-healing.json` with `expectedDataRecovery: false`, `priorMarkerSurvived`, `authenticatedWriteReadPassed`, `excludedWorkerIds` |

Verified 2026-09-16: delete accepted `07:49:33.53`, controller
`droplet-absent` at `07:49:50`, converged `07:54:07`, recovered
`07:54:54.62` — 5 min 21 s; `priorMarkerSurvived: false`. 2026-09-15:
5 min 46 s at generation 3, worker `600715804` excluded, marker lost.

**A pass proves service recovery.** The replacement is a fresh Droplet
with a new password and an empty volume; backup sets survive in R2 and
nothing restores them. Anyone reading `passed: true` as data recovery is
reading it wrong, and the evidence file says so before the delete.

## `restart`

| Gate | Checks |
|---|---|
| S0 | Ready at the current generation; a healthy probe; exactly one replica; the old pod's name and UID recorded |
| S1 stop | scale to 0; wait up to 130 min for zero pods; never force-delete; on timeout leave replicas at 0 and say so |
| S2 start | scale to 1; `rollout status` (600 s) |
| S3 new pod | `controller-up!`: one running pod, UID different from the old, log since `startTime` carries `RedisDeployment controller running`; a blank `startTime` is fatal |
| S4 reconcile | poll 10 s, up to 30 min, for Ready with `status.lastReconcileTime` **later than the new pod's `startTime`** |
| S5 same world | same `providerId`, healthy, same `convergenceRecordModifiedMs` (no second converge), same UID and generation |

Verified 2026-09-16 (second attempt): old `…-89mm4` stopped `08:03:32.77`,
new `…-szz5p` started `08:03:32Z`, reconciled `08:04:02.48`, Droplet
`600968621` unchanged, 54 s. The first attempt failed at S3/S4 as the
catalogue records; the 2026-09-15 test had no S3 and no S4.

**What a pass proves:** the new process reconciled this resource after it
started, without converging. **What it does not prove:** that a
controller disconnected rather than stopped would have been fenced;
nothing does.

## `delete`

| Step | Checks |
|---|---|
| G0 guard | `compute-prevent-destroy` must be false via `COLORS_PAR_COMPUTE_PREVENT_DESTROY=false`; exit 2 otherwise, `--dry-run` included; a suspended resource is refused (exit 1) |
| G1 policy | `deletionPolicy=Destroy` by resourceVersion-tested patch (retried on a status-write 422) |
| G2 finalizer | `kubectl delete --wait=false`, then poll 15 s, up to 30 min, for absence, printing each `finalizing` transition |
| G3 namespace | `kubectl delete namespace --timeout=900s` |
| G4 CRD | deleted only when no `RedisDeployment` remains in any namespace |

Verified 2026-09-16: G1 failed once on the stale resourceVersion; the
retried run finalized in 107 s (Droplet `600968621` destroyed by the
controller), namespace 15.8 s, CRD 0.8 s; the compute journal in
`redis-state` reads `retired`. Then `doks` delete: integration unlinked,
cluster in 15.6 s, registry in 4.5 s, cleanup failed on the root-owned
`registry/push/buildx`; the repeat delete completed cleanup. Account
after the asynchronous window: 0 Droplets, 0 clusters, 0 firewalls, no
registry, no profile-named SSH keys.

## What a pass does not prove

- **That `Ready` is true now.** C1 proves a Ready pass happened at this
  generation within the poll window; the next pass may be `Reconciling`
  already.
- **Data recovery.** D4 proves a new Droplet answers with the same
  identity; the marker's loss is the proof that nothing was restored.
- **Fencing.** S1 waits for the old pod to leave; a partitioned old
  controller that keeps running is outside every guarantee here.
- **The Ansible first-attempt failure.** Three creates failed once and
  converged; one did not fail. The retained-log path is armed and empty.
- **The token-relative 404, the slug-drift loop, the partial-state
  Destroy wedge, the 409 branch, the suspension race.** Each is a source
  reading in `SKILL.md`'s boundaries; none was reproduced live.
- **DOKS asynchronous cleanup timing.** Four minutes, observed once.
- **Anything at a different pin.** Both builds were Green only; there is
  no red or blue port of `green.kubernetes`.
