# Failure catalogue

Symptom-indexed, verbatim where the text was verbatim. Entries marked
*(2026-09-16)* were hit on `redis-operator-doks`; entries marked
*(2026-09-15)* on `redis-doks`; each at the pins in `pins.md`. The fix
commits are in `getcolors/redis-operator` unless another repository is
named.

## `check` fails on a healthy resource with `phase=Reconciling` *(2026-09-16)*

```
RedisDeployment is not Ready at its current generation: phase=Reconciling reason=Reconciling generation=1 observed=1
```
while `kubectl logs deployment/colors-redis-operator` shows, every pass:
```
2026-09-16T06:56:22.744752275Z redis profile=redis-operator-doks observe exists=true matches=true ready=true reason=converged provider-id=600954837
2026-09-16T06:56:28.564446686Z redis profile=redis-operator-doks observe exists=true matches=true ready=true reason=converged provider-id=600954837
```

Before `1de4b5c`, `check` read the resource once and required
`phase=Ready` at the current generation. With `reconcile-interval: 30s`
the controller publishes `Reconciling` at the start of every due pass and
`Ready` only after the pass's second observation (each observation is a
DigitalOcean GET, an R2 state read and an SSH `PING`; the two observation
lines above are 6 s apart, and the pass began some seconds before the
first). Two consecutive checks 20 s apart both landed in that window on a
resource the controller had just logged as converged (commit message of
`1de4b5c`; the check output itself was not retained). The message is not a
bug in the controller: the resource *was* `Reconciling` at that instant.

Fix (`1de4b5c`): `operator/wait-ready` polls every 5 s for up to 180 s
until `tools/ready?` — `phase=Ready`, the `Ready` condition `True`, and
`status.observedGeneration = metadata.generation` — treating `Reconciling`
and an unobserved generation as transient; `Invalid`, `Blocked`,
suspension and deletion are fatal at once; `Failed` is fatal except in the
create wait (45 min, 15 s) and the drill's recovery wait, which set
`transient-failure?` because the controller retries with backoff. `check`,
`rehearse`, `drill` and `restart` share it. The after-fix output reads:
```
redis-operator: waiting phase=Ready reason=Converged generation=3 observed=3
redis-operator: check phase=Ready reason=Converged generation=3 observed=3
redis-operator: check provider-id=600968621 name=redis-operator-doks ip=161.35.157.65 profile=redis-operator-doks healthy=true
redis-operator: check failures retained: 0
```

## `kubectl patch … failed (exit 1): The request is invalid` *(2026-09-16)*

```
>>> :redis-operator/destroy (delete)
<<< :redis-operator/destroy (780ms)
kubectl patch redisdeployments.colors.getcolors.ai failed (exit 1): The request is invalid: the server rejected our request due to an error in our request
```

The verb's first patch was
`[{"op":"test","path":"/metadata/resourceVersion","value":"<snapshot>"},
{"op":"add","path":"/spec/deletionPolicy","value":"Destroy"}]`. The
apiserver answers a failed `test` op with 422, and kubectl prints the line
above. Between the verb's `get` and its `patch` the controller had written
status — it does so twice per pass — and every status write moves the
resourceVersion, so the test failed. Not a concurrent edit: nothing about
the spec had changed. The rehearsal earlier that day had issued the same
kind of patch twice and passed by timing. (The build session reported
reproducing the exact message with a stale resourceVersion under
`--dry-run=server`; no artefact of that reproduction was retained.)

Fix (`7723970`): `tools/patch-resource!` catches a `patch` failure whose
message contains `the server rejected our request due to an error in our
request`, re-reads the resource and:

- re-issues the patch against the fresh resourceVersion when `spec`,
  `metadata.deletionTimestamp` and `metadata.uid` equal the snapshot's, at
  most 5 attempts 2 s apart, logging
  `patch resourceVersion moved <old> -> <new> (status write); retrying`;
- fails at once with `RedisDeployment was edited concurrently
  (resourceVersion <old> -> <new>); the patch was not applied` when the
  desired state differs;
- rethrows the original error when the resourceVersion did **not** move
  (the patch itself is invalid);
- fails with `resourceVersion kept moving through 5 attempts; the patch
  was not applied` after the bound;
- retries no other kubectl error.

The retried delete:
```
redis-operator: patched deletionPolicy=Destroy
redis-operator: finalizing phase=Ready reason=Converged generation=5 observed=3 deleting=true
redis-operator: finalizing phase=Deleting reason=Deleting generation=5 observed=5 deleting=true
redis-operator: RedisDeployment removed after finalization
<<< :redis-operator/destroy (107363ms)
```

## `kubectl exec` into the controller dies unpacking `clojure-tools` *(2026-09-16)*

```
redis-operator: waiting phase=Ready reason=Converged generation=3 observed=3
redis-operator: restart scaled to zero; waiting for the old controller to stop
redis-operator: restart phase=Ready reason=Converged generation=3 observed=3 lastReconcileTime=2026-09-16T07:57:01.507Z
kubectl exec deployment/colors-redis-operator failed (exit 1): Clojure tools not yet in expected location: /root/.deps.clj/1.12.4.1618/ClojureTools/clojure-tools-1.12.4.1618.jar
Unzipping /root/.deps.clj/1.12.4.1618/ClojureTools/clojure-tools.zip ...
Exception in thread "main" java.io.EOFException: Unexpected end of ZLIB input stream
command terminated with exit code 1
```

Two faults stacked. The `lastReconcileTime` the verb accepted
(`07:57:01.507Z`) was later than its pre-restart baseline
(`07:56:17.012Z`) but earlier than the old pod's disappearance
(`07:57:03.077Z`, `stoppedAt` in
`controller-restart-failed-attempt-1.json`): the old controller published
it while draining. The new pod rolled out at `07:57:07` and, with no
dependency cache on its volume, began downloading `clojure-tools`; the
verb's `kubectl exec … bb -m colors.probe` started a second download of
the same archive into the same path, and both processes read a truncated
ZLIB stream. The rollout status was "complete" because the controller
Deployment has no readiness probe.

Fix (`8030c7f`), three parts:

- `restart` records the old pod's UID and waits for exactly one running
  pod with a different UID whose log **since its `status.startTime`**
  contains `RedisDeployment controller running`; it accepts only a
  `lastReconcileTime` later than that start time. Evidence of the pass:
  `newPodStartTime 2026-09-16T08:03:32Z`, `lastReconcileTimeAfter
  2026-09-16T08:04:02.481Z`, old pod `…-89mm4`, new pod `…-szz5p`.
- `tools/controller-up!` (10 min bound, 5 s poll) runs before every probe
  exec, so `check`, `rehearse` and `drill` wait too; it prints
  `controller pod=<name> started=<time> still starting` until the line
  appears, then `controller up pod=<name> started=<time>`.
- The Deployment mounts `/root/.gitlibs`, `/root/.m2`, `/root/.deps.clj`
  and `/app/.cpcache` as subPaths of the existing PVC; the golden render
  changed by exactly those four mounts, and the next `create` rolled the
  controller once for the mount change.

## `converge outcome=failed step=:redis/ansible exit=2` on a fresh Droplet, then converged *(2026-09-15 ×2, 2026-09-16 ×1)*

```
2026-09-16T06:51:07.309921289Z redis profile=redis-operator-doks observe exists=false matches=false ready=false reason=absent provider-id=none
2026-09-16T06:51:07.310100554Z redis profile=redis-operator-doks converge start
2026-09-16T06:53:20.908193799Z redis profile=redis-operator-doks converge outcome=failed step=:redis/ansible exit=2
2026-09-16T06:53:30.328034714Z redis profile=redis-operator-doks observe exists=true matches=false ready=false reason=unhealthy provider-id=600954837
2026-09-16T06:53:30.328077932Z redis profile=redis-operator-doks converge start
2026-09-16T06:55:40.085900849Z redis profile=redis-operator-doks converge outcome=converged provider-id=600954837
2026-09-16T06:55:46.007107970Z redis profile=redis-operator-doks observe exists=true matches=true ready=true reason=converged provider-id=600954837
```

The compute stage had created Droplet `600954837`; the Ansible play then
exited 2 within about two minutes of the Droplet's existence. The
controller's `failure!` put the resource in `Failed/ExecutionFailed` with
a 1 s backoff, the next pass observed the host `unhealthy` (PING refused
on an unconfigured host), reran the create workflow, and it converged.
Three of the four creates across both builds behaved this way: the
2026-09-15 first create and its drill replacement (history `HANDOFF.md`,
"The first Ansible attempt failed; the controller's retry completed
successfully" and "The replacement's first Ansible attempt failed and its
automatic retry passed") and this one. The 2026-09-16 drill replacement
converged first time (`controller-log-drill.txt`).

**Cause not determined.** On 2026-09-15 the adapter dropped the play's
output by design and the cause was discarded; suspending reconciliation
and running the play by hand succeeded, so nothing was changed. On
2026-09-16 the failure preceded the retention fix by twelve minutes of
wall clock and did not recur after it (`failureLogsRetained: 0` in
`live-run.json`). The sibling single-node build on Vultr observed
`unattended-upgrade` restarting sshd six minutes after first boot; this
skill does not assert that is the same fault.

What exists now (`1de4b5c`): `colors.redis/retain-failure!` writes
`/data/work/<profile>/failures/<yyyymmdd'T'HHmmss'Z'>-<step>.log` (0600 in
0700, 20 newest) with `profile`, `event`, `step`, `exit`, `err` (the
play's or tofu's output), `recap` and `trace`, every `COLORS_PAR_*` value
masked to `***` longest-first; the adapter's log line gains
`retained=<file>`; `check` prints `failures retained: N newest=<file>`.
Read one:
```
kubectl --context <kube-context> exec -n colors-redis deployment/colors-redis-operator -- cat /data/work/<profile>/failures/<file>
```
Do not gate a create on the first `Failed` pass; the create wait tolerates
`Failed` for this reason.

## `DirectoryNotEmptyException` from `doks` delete after everything was destroyed *(2026-09-16)*

```
>>> :doks/infrastructure (delete)
<<< :doks/infrastructure (15562ms)
>>> :doks/registry (delete)
<<< :doks/registry (4485ms)
>>> :doks/cleanup (delete)
/home/ubuntu/code/getcolors/doks-dev/./.colors/doks-dev/registry/push
java.nio.file.DirectoryNotEmptyException: /home/ubuntu/code/getcolors/doks-dev/./.colors/doks-dev/registry/push
```

The cluster and the registry were already gone; only the local cleanup
failed. `redis-operator/scripts/image.sh` had run `sudo -n env
DOCKER_CONFIG=… docker buildx build` with `DOCKER_CONFIG` pointing at the
deployment's `registry/push` directory (where the `doks` `registry` verb
writes the one-hour push credential), and docker, running as root, wrote a
root-owned `buildx/` subtree beside `config.json`. The unprivileged cleanup
could not remove it.

Fix (`5f37868` in `redis-operator`, `getcolors/doks` in the same session):
`image.sh` copies `config.json` into a `mktemp -d` directory, points
`DOCKER_CONFIG` at the copy, and removes it with `sudo -n rm -rf` on exit;
`doks` delete reports leftovers instead of throwing and prints one line
per stage. The repeat delete:
```
>>> :doks/cleanup (delete)
cleanup done: removed /home/ubuntu/code/getcolors/doks-dev/./.colors/doks-dev/kubeconfig and /home/ubuntu/code/getcolors/doks-dev/./.colors/doks-dev/registry
delete complete for doks-dev; the provider removes worker machines and cluster firewalls asynchronously over the next minutes, and check is expected to fail from now on
```
Its `registry doks-dev destroyed` line on an already-empty registry state
is cosmetic. If a root-owned tree already exists, `sudo rm -rf` it before
the delete; the deployment's `.colors/` holds nothing that is not
regenerated.

## The worker and firewalls outlive the deleted DOKS cluster *(2026-09-16)*

`:doks/infrastructure (delete)` returned in 15.6 s with the cluster
resource gone. For about four minutes afterwards the account still listed
the worker Droplet `600945297` and the firewalls
`k8s-2e927b38-90a5-4d73-98af-d974f9fe9fd1-worker` and
`k8s-public-access-2e927b38-90a5-4d73-98af-d974f9fe9fd1`; DigitalOcean
removes them asynchronously. The 2026-09-16 shutdown record
(`shutdown.json`) names both as `clusterFirewallsDeletedAsynchronously`
and the account audit afterwards read 0 Droplets, 0 clusters, 0
firewalls. A delete that lists the account inside the window and finds
them is not wrong; a drill's worker exclusion (`excludedWorkerIds`)
belongs to a *running* cluster, not this window. Observed once; not
re-measured.

## `restart` passed without proving a restart *(2026-09-15; the audit's finding)*

`controller-restart.json` from 2026-09-15 records `passed: true` with the
same `convergenceRecordModifiedMs` before and after, 64.8 s including a
45 s sleep, and no `lastReconcileTime` at all. The Python `restart.py`
waited for `Ready` — which the stale status already said — and never
asked whether the new pod had reconciled. With no readiness probe and the
dependency resolution happening per start, the new pod was "ready" before
the controller had loaded. What that test proved is that the Droplet
survived and that no second convergence ran; it did not prove the new
controller was managing anything. The 2026-09-16 pod-clock proof above
replaces it.

## `finalizing phase=Ready … generation=5 observed=3 deleting=true` *(2026-09-16; not a failure)*

```
redis-operator: finalizing phase=Ready reason=Converged generation=5 observed=3 deleting=true
redis-operator: finalizing phase=Deleting reason=Deleting generation=5 observed=5 deleting=true
```

The resource was at generation 3 when `delete` began; the
`deletionPolicy=Destroy` patch and the `kubectl delete` (which sets
`deletionTimestamp`) each bumped `metadata.generation` on the real
apiserver. The controller's test fixture models deletion as not bumping
the generation (audit, green findings), so the code's "Ready at the
current generation" reads differently in tests and live. The delete verb
waits for the resource to disappear, not for Ready; anything else built on
`tools/ready?` during a Destroy would wait forever.

## Droplet `600730033` in the 2026-09-15 shutdown record *(2026-09-15; unexplained)*

`live-resources.json` at 16:19:22 UTC lists two Droplets: the worker
`600715804` and the Redis host `600724611` (the drill's replacement, at
`206.189.110.180`). `shutdown.json` at 17:11:14 UTC records
`"redisDropletDeleted": "600730033"`. No evidence file, commit message or
handoff sentence accounts for a third Redis Droplet in the 52 minutes
between. The 2026-09-16 audit lists it first among the gaps. The
2026-09-16 build's records are consistent from create to shutdown
(`600954837` → drill → `600968621` → Destroy).
