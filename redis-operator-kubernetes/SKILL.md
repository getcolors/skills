---
name: redis-operator-kubernetes
description: 'A Kubernetes operator provisioning one Redis Droplet from a custom resource, verified live on DigitalOcean DOKS - `check` failing on a healthy resource with "RedisDeployment is not Ready at its current generation: phase=Reconciling reason=Reconciling", `kubectl patch ... failed (exit 1): The request is invalid: the server rejected our request due to an error in our request` from a status write moving the resourceVersion, `kubectl exec` into a restarting controller: "Clojure tools not yet in expected location" and "java.io.EOFException: Unexpected end of ZLIB input stream", `converge outcome=failed step=:redis/ansible exit=2` on a fresh Droplet then converged on retry, `DirectoryNotEmptyException: .../registry/push` after destroy, Droplets and firewalls outliving a deleted DOKS cluster, and a self-healing drill that recovers service in five minutes and no data. Use for a Green Kubernetes controller, the RedisDeployment CRD, or any operator on DOKS. Full symptom index in the body.'
---

# Redis operator on Kubernetes

## Symptom index

Load the rest of this skill when any of these appear; each has a full entry
with verbatim text in `references/failure-catalogue.md`:

- `./green check` (or a `rehearse`, `drill` or `restart` precondition) fails
  with `RedisDeployment is not Ready at its current generation:
  phase=Reconciling reason=Reconciling generation=1 observed=1` while
  `kubectl logs` shows `observe … ready=true reason=converged` every pass
- `kubectl patch redisdeployments.colors.getcolors.ai failed (exit 1): The
  request is invalid: the server rejected our request due to an error in
  our request` from a JSON patch that carries a `test` op on
  `metadata.resourceVersion`
- `kubectl exec deployment/colors-redis-operator failed (exit 1): Clojure
  tools not yet in expected location: /root/.deps.clj/…/clojure-tools-….jar`
  followed by `java.io.EOFException: Unexpected end of ZLIB input stream`
- a `restart` that "passed" because `status.lastReconcileTime` moved, when
  the write came from the old pod draining
- the controller log reads `converge outcome=failed step=:redis/ansible
  exit=2` on a Droplet that is seconds old, then `converge
  outcome=converged` about two minutes later with nothing changed
- `check` prints `failures retained: N` with `N > 0`
- `java.nio.file.DirectoryNotEmptyException: …/.colors/<profile>/registry/push`
  from a `doks` delete whose infrastructure and registry stages had already
  succeeded
- after `doks` delete reports the cluster gone, `doctl compute droplet
  list` still shows the worker and `k8s-<cluster-id>-worker` /
  `k8s-public-access-<cluster-id>` firewalls for minutes
- after a self-healing drill the resource is Ready at the same UID and
  generation, on a new Droplet, and every key written before the drill is
  gone
- `finalizing phase=Ready reason=Converged generation=5 observed=3
  deleting=true`: the generation moved when the resource was deleted, so
  "Ready at the current generation" is never true again during a Destroy
- a `RedisDeployment` whose Droplet was recreated in another team after a
  token rotation; a converge loop that restarts Redis every reconcile
  interval after an image slug retired or a resize; a `Destroy` that wedges
  on `partial` compute state

A Kubernetes operator is easy to demo and hard to prove. The gap this
skill covers is between a controller that publishes `Ready` and a
deployment whose claims survived a real cluster: that a single status read
means anything, that a patch you guarded actually applied, that a restart
was a restart, that "recovered" says what it says, and that a delete left
nothing behind. That distance was measured on two live builds of the same
controller.

The first was `redis-doks` on 2026-09-15: a DOKS cluster
`colors-doks-dev-20260915`, the controller image at source `e072b43`, one
`RedisDeployment` driven by Python scripts, one self-healing drill (5 min
46 s), one backup rehearsal, one graceful restart, and a shutdown whose
record names a Droplet no other record explains.

The second was `redis-operator-doks` on 2026-09-16, after a read-only audit
of the first: the same controller repackaged as the Package Skill
`package-redis-operator-green` on a cluster the `doks` package created.
One create, one image roll, one drill (5 min 21 s), one rehearsal, a
restart that failed and a restart that passed, a delete that failed and a
delete that destroyed everything through the finalizer, then the cluster's
own delete, which failed once on a leftover and passed on the repeat.
Four package fixes and one script fix were paid for that day; each is in
the catalogue with the commit that carries it.

Everything here was verified against one of those running deployments
unless it says otherwise, and each claim names its build where the two
differ. Where this skill contradicts the companion's README or the audit,
it names the function it read instead.

## The reference implementation, and why this skill ships no assets

The working files live in the
[`getcolors/redis-operator`](https://github.com/getcolors/redis-operator)
Package Skill, which is two things under one pin: the controller image
(`Dockerfile`, entry point `bb controller --in-cluster`) and the package
`skills/package-redis-operator-green`. The CRD is
`src/resources/io/github/getcolors/redis_operator/crd.yml`; the adapter
that turns a `RedisDeployment` into the Redis package's workflow is
`src/colors/redis.clj`; the in-pod probe is `src/colors/probe.clj`; the
launcher side is `src/io/github/getcolors/redis_operator/{validate,tools,
workflow,operator}.clj`; the image is built by `scripts/image.sh`. The
controller rides on the Green SDK's `green.kubernetes` (`src/green/
kubernetes.clj`, the polling control loop) and `green.kubernetes.client`
(`src/green/kubernetes/client.clj`, the kubectl transport), documented in
`green/docs/kubernetes.md`. The worked deployment is
[`getcolors/redis-operator-doks`](https://github.com/getcolors/redis-operator-doks)
on a cluster from [`getcolors/doks`](https://github.com/getcolors/doks);
its `HANDOFF.md`, `evidence/2026-09-16/`, `reports/audit-2026-09-16.md`
and `history/2026-09-15/` are the provenance of every claim below. This
skill carries no copies of any of it, per the Context Skill Standard's
no-second-copy rule. Read the code there; read *why it is shaped that way*
here.

## Topology that survived

Nothing Redis runs in the cluster. The cluster hosts a controller; the
controller runs the `redis` package's own Clojure workflow (OpenTofu
through `colors-compute`, then Ansible over SSH) against DigitalOcean, and
the Redis Droplet lives outside the cluster with its compute state in one
R2 bucket and its RDB backup sets in another.

- **One DOKS cluster** (`1.36.3-do.5`, region `ams3`, one `s-2vcpu-4gb`
  worker) from the `doks` package, plus a deployment-owned container
  registry integrated with the cluster; that integration is what puts the
  `doks-dev` pull Secret into every namespace.
- **One controller Deployment** (`colors-redis-operator`, namespace
  `colors-redis`, one replica, `Recreate`, `terminationGracePeriodSeconds`
  10800) with a Role scoped to `redisdeployments`, their `/status` and
  `/finalizers`, one 5Gi PVC, and a Secret of exactly five `COLORS_PAR_*`
  credentials. The controller runs as root because `/root/.ssh` is a PVC
  subPath owned by the user the workflows run as; capabilities are all
  dropped.
- **One `RedisDeployment`** whose `spec.config` is the Redis package's
  flat, kebab-case desired state. `profile`, `r2-bucket` and
  `r2-endpoint` are immutable by CEL rule; the state identity
  (`["r2" endpoint bucket profile]`) is persisted in status before the
  first side effect and refused thereafter.
- **One Redis Droplet** (`s-1vcpu-2gb`, `ubuntu-24-04-x64`, loopback-only
  Redis 7.2.16, reached over SSH), whose SSH ingress list must include the
  DOKS worker's public address — the controller's egress — and the
  developer's.
- **The controller's own dependency caches on the PVC.** `/root/.gitlibs`,
  `/root/.m2`, `/root/.deps.clj` and `/app/.cpcache` are subPaths of the
  same volume as `/data` and `/root/.ssh` since `8030c7f`; a restart
  resolves nothing and an exec'd `bb` shares what the controller fetched.
  Verified 2026-09-16: the new pod was up in about 20 s from the cached
  volume where the first pod had downloaded for minutes.

Delete this deployment before the cluster. The cluster cannot clean the
Droplet once the controller is gone; that ordering is the deployment's
`CLAUDE.md` rule and the 2026-09-16 shutdown followed it.

## How the control loop actually behaves

`green.kubernetes` is a poller, not a watch: every `poll-ms` (2000 in
`colors.main`) it lists the CRs and enqueues each; one worker reconciles
when the resource is *due* — its generation or reconcile-request
annotation changed, it is being deleted, or `nextReconcileTime` has
passed. A due pass publishes `Reconciling`, observes, converges only if
the observation does not match, observes again, and publishes `Ready`
with `nextReconcileTime = now + spec.reconcileInterval`. **Two status
writes per pass, every pass, converged or not** (`reconcile-locked!` in
`kubernetes.clj`). Each status write moves `metadata.resourceVersion`.
Every downstream trap in this skill follows from that sentence.

The adapter's observation (`colors.redis/observation`) is three
independent questions — does owned compute state name a Droplet, does the
DigitalOcean API return that exact ID with that exact name, does an
authenticated `PING` over SSH answer `PONG` — plus a marker on the PVC
holding the config hash and provider ID of the last successful converge.
`matches?` needs all of them; `ready?` is health alone; an unreadable
state, an API error or a `partial` compute record is never permission to
create. A confirmed 404 for the recorded ID is the one absence proof, and
it is relative to the token's team (see boundaries).

## Ready is a moment, not a state

With `reconcile-interval: 30s` the resource is `Reconciling` from the
instant a pass is due until its second observation completes (a DigitalOcean
GET, an R2 state read and an SSH `PING`, twice), and `Ready` only between
passes. On the first-create log of 2026-09-16 each pass's two observation
lines land 5–9 s apart, every 40-odd seconds; how much of the interval the
window covers was not measured, but two `check` reads 20 s apart both
landed in it on a resource the controller had just logged as converged,
and both failed with `RedisDeployment is not Ready at its current
generation: phase=Reconciling reason=Reconciling generation=1 observed=1`
(commit `1de4b5c`). A single read of `status.phase` proves nothing under a
short interval.

The fix, and the doctrine: `check` and every Ready precondition **poll**
(5 s, up to 180 s) until `phase=Ready`, the Ready condition is `True` and
`observedGeneration` equals `metadata.generation`; `Invalid`, `Blocked`,
suspension and deletion end the wait at once because none heals by
waiting; `Failed` ends it too, except in the create and drill waits, which
tolerate it because the controller retries with backoff. The same
generation rule cuts the other way during a Destroy: `kubectl delete`
bumps `metadata.generation` (the apiserver does; the controller's test
fixture does not), so the finalizing resource reads `generation=5
observed=3` and then `generation=5 observed=5 deleting=true` — a wait for
"Ready at the current generation" would spin until the resource is gone.
The delete verb waits for absence instead.

## A guarded patch is only guarded once

Every launcher-side write to the resource is a JSON patch that opens with
`{"op":"test","path":"/metadata/resourceVersion","value":…}`, so a
concurrent spec edit fails the operation rather than being overwritten.
The apiserver reports a failed `test` op as 422, and kubectl prints it as
`The request is invalid: the server rejected our request due to an error
in our request`. Because the controller moves the resourceVersion twice
per interval, the snapshot a verb holds is routinely stale by the time its
patch lands: the 2026-09-16 delete failed on its very first patch
(`deletionPolicy=Destroy`), and the rehearsal before it had passed only by
timing (commit `7723970`).

Since `7723970`, `tools/patch-resource!` recognises exactly that message
on a `patch`, re-reads the resource, and re-issues the patch against the
fresh resourceVersion **only when `spec`, `metadata.deletionTimestamp` and
`metadata.uid` are what the caller saw**, at most five times two seconds
apart. A changed spec fails at once as a concurrent edit; a 422 on an
*unmoved* resourceVersion is the patch itself being invalid and is
rethrown; every other kubectl error is not retried. The retried delete
patched, waited 107 s for the finalizer, then removed the namespace and
the CRD.

## A controller restart is proven by the new pod's clock

The first restart of 2026-09-16 failed in a way that had passed the day
before. `restart` scaled the Deployment to zero, waited for the old pod to
disappear, scaled to one, waited for rollout, and then accepted the first
`status.lastReconcileTime` later than the pre-restart value — which was
`07:57:01.507Z`, written by the **old** controller draining before it
stopped at `07:57:03`. It then exec'd the health probe into the new pod,
which was still downloading `clojure-tools`; two processes unpacking one
archive left both with `java.io.EOFException: Unexpected end of ZLIB
input stream`. Three things were wrong at once: the proof, the exec, and
the cache that made the exec a download.

Since `8030c7f`: `restart` records the old pod's UID, waits for exactly
one running pod with a different UID whose own log **since its
`status.startTime`** carries `RedisDeployment controller running` (the
line `colors.main` prints after the poller is up), and accepts only a
`lastReconcileTime` later than that start time. The same up-gate
(`tools/controller-up!`, 10 min bound) runs before every probe exec, so
`check`, `rehearse` and `drill` never exec into a pod still resolving
dependencies either; and the caches live on the PVC. The passing restart:
old pod stopped `08:03:32.77`, new pod `startTime` `08:03:32Z`, first
reconcile by the new controller `08:04:02.48`, same Droplet, same UID,
same convergence-record mtime, 54 s end to end. A stale `Ready` status
proves nothing about the pod that is running now; a readiness probe
would not have helped, because the controller has none and the rollout
was "complete" before the controller had loaded.

## The first Ansible attempt on a fresh Droplet fails, and nobody knows why

On three of the four creates across the two builds — both 2026-09-15
converges (the first create and the drill's replacement) and the first
create of 2026-09-16 — the controller logged `converge outcome=failed
step=:redis/ansible exit=2` on a Droplet that had existed for about two
minutes, observed the host `unhealthy` ten seconds later, converged again,
and succeeded (2026-09-16: failed `06:53:20`, retry started `06:53:30`,
converged `06:55:40`). The drill's replacement Droplet on 2026-09-16
converged on its first attempt. **The cause was not determined.** The
2026-09-15 build discarded the play output by design (the adapter
suppresses raw workflow output so no secret reaches a log), and by the
time retention existed the failure did not recur.

Since `1de4b5c` the controller keeps every failed converge or delete as
`/data/work/<profile>/failures/<UTC timestamp>-<step>.log` (0600 in a
0700 directory, 20 newest): the step, exit, the workflow's error text
with the play's or OpenTofu's output, the Ansible recap and the trace,
with the exact value of every `COLORS_PAR_*` variable replaced by `***`
before the file exists. `check` prints `failures retained: N`; read one
with `kubectl exec -n colors-redis deployment/colors-redis-operator -- cat
/data/work/<profile>/failures/<file>`. A single-node Redis build on Vultr
met `unattended-upgrade` restarting sshd six minutes after first boot
(`redis-single-node`); whether that is this failure is a guess this skill
does not make. The next occurrence is readable; until then a first-attempt
failure followed by a converged retry is the observed normal, and a gate
that fails a create on the first `Failed` pass is wrong.

## Recovery is service recovery, not data recovery

The drill proves ownership before it deletes anything: the recorded
provider ID equals the live Droplet's ID; its name, the probe's name and
the profile are one string; the ID is not in the DOKS cluster's node
pools (`doks-cluster-id`) and the Droplet carries no `k8s:` tag; the
recorded IP is among its public v4 addresses; a random marker key
round-trips through the authenticated probe. Then one `DELETE
/v2/droplets/<id>`. On 2026-09-16 the controller saw
`reason=droplet-absent` 17 s later, converged a replacement in 4 min 17 s,
and the drill's 15 s poll confirmed a different provider ID, `Ready` at
the unchanged UID and generation 1, the old ID answering 404, and a fresh
authenticated write, 5 min 21 s after the delete was accepted (5 min 46 s
at generation 3 on 2026-09-15).

`priorMarkerSurvived: false` in both evidence files is the honest part.
The replacement is a fresh Droplet with a new password and an empty data
volume; the backup sets in R2 survive, and nothing restores them. The
companion says so (`README.md`, "Observation and recovery") and the
evidence records `expectedDataRecovery: false` before the delete. Losing
the Droplet loses everything since the newest completed backup set, six
hours apart at the deployed schedule, until someone restores by hand.

## Rehearsal runs under an acknowledged suspension

The rehearsal patches `spec.suspend=true`, which bumps the generation,
and waits for the controller to publish `Suspended` **at that
generation** — `acknowledged-suspension?` in `tools.clj` — because
suspension is not acknowledged until the pass that was running has
finished. Only then does it exec the package's `rehearse` workflow in the
pod (a fresh backup set restored into a scratch container, the
`redis-single-node` doctrine), and it resumes only when the resource is
exactly as it left it and the remote outcome is certain; otherwise it
prints `resource left suspended; verify no workflow runs before resuming`
and exits non-zero. On 2026-09-16: suspended at generation 2, acknowledged
3.6 s later, resumed at generation 3, Ready again. `create` refuses a
suspended resource rather than converge over a rehearsal in progress.

The acknowledgement is a one-shot check, not a lease. `colors.probe/
require-suspended!` reads the resource once; an unsuspend or a delete
after that read runs the controller beside a rehearsal that can take two
hours. Nothing in either build exercised that race.

## Destroy, and what the provider removes later

`delete` lifts the guard (`COLORS_PAR_COMPUTE_PREVENT_DESTROY=false`,
exit 2 otherwise, dry-run included), patches `deletionPolicy=Destroy`,
deletes the resource and waits for the finalizer; the controller runs the
package's delete under `colors.getcolors.ai/infrastructure`, re-observes
until absence, removes the finalizer, and only then does the verb delete
the namespace and — if no `RedisDeployment` remains in any namespace —
the CRD. `Retain` (the committed default) removes the finalizer without
touching the Droplet. The compute journal in the state bucket reads
`retired` afterwards.

Then the cluster. The `doks` infrastructure stage returned in 15.6 s on
2026-09-16, and DigitalOcean removed the worker Droplet and the two
firewalls `k8s-<cluster-id>-worker` and `k8s-public-access-<cluster-id>`
asynchronously about four minutes later. A delete that lists the account
inside that window and finds them is not wrong; the account audit belongs
after the window, and read 0 Droplets, 0 clusters, 0 firewalls, no
registry. The same delete then threw
`java.nio.file.DirectoryNotEmptyException: …/.colors/doks-dev/registry/push`
from its cleanup: `scripts/image.sh` had run `sudo docker buildx` with
`DOCKER_CONFIG` pointing at that push directory, and docker had written a
root-owned `buildx/` subtree beside the credential. Nothing billable was
affected; `image.sh` now copies the credential into a private temp
directory it removes on exit (`5f37868`), and the repeat delete completed
every stage.

## Boundaries documented, not fixed

From the 2026-09-16 audit and the companion's own README; each is a
source reading, not a live failure, unless it says otherwise.

- **A DigitalOcean 404 is relative to the token's team**
  (`colors.redis/provider-get`, `404 nil`). A Droplet in another team also
  answers 404, so rotating the Secret to a token from a different team
  makes the operator "confirm absence" and create a second Droplet there
  while the original keeps running. No account identity is recorded or
  checked. Rotate within one team.
- **Slug drift is a converge loop.** `provider-matches?` compares
  `size_slug` and `image.slug` as the API reports them; DigitalOcean nulls
  the image slug when a base image retires, and an external resize
  changes the size. Either makes `matches?` false forever, and every
  reconcile interval reruns the create workflow, whose smoke gate restarts
  Redis. Correct `spec.config` to the live values.
- **No liveness or readiness probe on the controller**; errors are
  counted in an atom nobody reads, and only `Exception` is caught. The
  `controller-up!` log gate exists because the rollout status is not
  evidence.
- **The green controller branches on `{:status 409}` that its client
  never throws.** `reconcile-locked!` in `kubernetes.clj` skips the
  `failure!` write when `(ex-data error)` carries `:status 409`;
  `green.kubernetes.client/request!` throws `{:exit n :operation …}` and
  discards the HTTP status. The unit tests pass because the fake throws
  `{:status 409}`. Consequence: a transient conflict on the final `Ready`
  publish is followed by a `Failed/ExecutionFailed` write on a converged
  deployment, with backoff. Not observed live.
- **`Destroy` on `partial` compute state wedges**: compute inspection
  refuses it, and the only exit (`Retain`) orphans what the partial state
  declares. Finish or repair the create first.
- **The grace period is longer than the caps it cites, not than the
  workflow.** 10800 s exceeds one Ansible play (7200 s,
  `redis/green/src/clj/io/github/getcolors/redis/tools.clj`) plus one
  OpenTofu plan (1800 s, `colors-compute/…/compute_execution.clj`); that
  file bounds plan and apply at 1800 s each, per stage, so a whole create
  is not bounded by the grace period. A SIGKILL mid-stage leaves the
  compute journal locked; the pinned `colors-compute` `7e1c234` carries a
  reviewed repair for exactly that, which its predecessor `ae28ea7` (the
  2026-09-15 pin) did not.
- **Droplet `600730033`.** The 2026-09-15 `live-resources.json` (16:19 UTC)
  records `600724611` as the Redis host after every test; `shutdown.json`
  (17:11 UTC) records deleting `600730033`. No file, commit or prose
  explains a second replacement in those 52 minutes. That build's
  "recovery verified" covers less than its handoff says; the 2026-09-16
  build has no such gap.

## Colors-specific notes

- **Three pins, not one.** The launcher pins the package by SHA; the
  deployment pins the controller image by digest in `colors.yml`; the CRD
  ships inside the pinned library and is read from the classpath. A change
  to `src/colors/` needs a new image, a change to the package side a new
  pin, a change to the CRD both. On 2026-09-16 the image was built twice
  (`7e9adf0`, `c461339`) while the launcher moved five times.
- **`image.sh` refuses a dirty tree** so the `org.opencontainers.image.
  revision` label is true, needs `DOCKER_CONFIG` pointing at the push
  config the `doks` `registry` verb writes (one hour), builds
  `linux/amd64` on this arm64 host with buildx, and never runs Babashka
  under QEMU: run `bb test` on the host first, and validate the image on a
  native worker (the 2026-09-15 build ran the suite in a pod: 8 tests, 50
  assertions).
- **`KUBECONFIG` is the `doks` deployment's rendered file** and expires
  after 24 h; `./green kubeconfig` there refreshes it. Every kubectl call
  passes `--context`.
- **Only the five credentials may be `COLORS_PAR_*` in the pod.**
  `check-environment!` refuses any other override at startup so desired
  state can only come from the resource; `COLORS_PAR_PROFILE` is refused
  everywhere.
- **The audit's own trap:** `redis` at `ec260f5` pins green `3f33f5d`,
  and tools.deps resolves one copy at `215e298` because the top-level pin
  wins. The redis suite, golden and parity were never run against
  `215e298`, whose `a918861` changed `green.process` timeout semantics.
  Not observed to matter.

## References

- `references/pins.md` — the verified version sets, the launcher-pin
  sequence of 2026-09-16, and the retest conditions.
- `references/failure-catalogue.md` — symptom-indexed verbatim errors and
  log lines, with meaning and fix.
- `references/contract.md` — the `RedisDeployment` resource and the
  controller's status protocol as the source defines them.
- `references/acceptance.md` — the verbs and the gates, what each pass
  proves, and what it does not.
