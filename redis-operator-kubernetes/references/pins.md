# Pins

Two verified-good sets, one per build. The 2026-09-15 set ran the
script-driven `redis-doks` deployment; the 2026-09-16 set ran the same
controller as the Package Skill `package-redis-operator-green` from
`redis-operator-doks`. Both deployments are shut down; the R2 buckets
`doks-state`, `redis-state` and `redis-backup` and their objects are the
only thing that survives either.

## The verified-good set: 2026-09-16 (`redis-operator-doks`)

| Component | Pin |
|---|---|
| Green SDK | `215e298eed1f43d85c1549ae441d03ccbf625373` (`green.kubernetes` first appears here) |
| redis package | `ec260f5dd27aa92829011e24d5d8a90e75b0b098`, `:deps/root green` (it pins green `3f33f5d`; tools.deps resolves `215e298`) |
| colors-compute | `7e1c2349388ff2ca8a3da65a0c8cb888315b57f4`, `:deps/root green` — the reviewed repair for interrupted operations; its predecessor `ae28ea7` (the 2026-09-15 pin) has no repair path for a journal lock left by a killed process |
| redis-operator launcher pin (as of the deployment's last payload refresh, `e0226fe`) | `5f378682d0ee1ca1718d5192c1f0f6b346d82a15`, stamped by `e9fe076`; the repository's HEAD `e29e84e` is documentation on top of it |
| Controller image 1 | `registry.digitalocean.com/doks-dev/redis-operator@sha256:74bfa7556c90bfa7da0f72c2c6e3320fdde0dc5caa1dd28bb53003a376629a60`, source `7e9adf0` (library `f163b48`); ran the first create |
| Controller image 2 | `registry.digitalocean.com/doks-dev/redis-operator@sha256:0308b1324fc6d2de1e5e8fd23e149861be215c577a3f5ba97f1761e1fd979a2b`, source `c461339` (library `1de4b5c`: failure retention, polled check); ran the drill, the rehearsal, both restarts and the delete |
| Image base and toolchain | `ubuntu:24.04`; Babashka `1.12.218` (from `babashka/babashka:1.12.218`); OpenTofu `1.11.5` and kubectl `v1.36.3`, both checksum-verified; the AWS CLI from the unversioned archive (no URL-addressable checksum; the image digest pins it); `openjdk-21-jre-headless`, `ansible`, `python3-boto3`, `redis-tools`, `git`, `openssh-client` from apt, unpinned |
| Redis image | `docker.io/library/redis:7.2.16@sha256:74566c6910d13ae61e7ce73ebd3127438a1fe805b309b097c323142719ec8a5b` |
| DOKS | cluster `doks-dev` `2e927b38-90a5-4d73-98af-d974f9fe9fd1`, `ams3`, `1.36.3-do.5`, one `s-2vcpu-4gb` worker `doks-dev-3fd5ld` (Droplet `600945297`, `134.209.92.109`); registry `registry.digitalocean.com/doks-dev` |
| Redis Droplet | `s-1vcpu-2gb`, `ubuntu-24-04-x64`, `ams3`; `600954837` at `206.189.98.100` (first create), `600968621` at `161.35.157.65` (drill replacement) |
| Controller Deployment | one replica, `Recreate`, `terminationGracePeriodSeconds` 10800, requests `100m`/`256Mi`, limit `2Gi`, 5Gi PVC at `/data`, `/root/.ssh`, `/root/.gitlibs`, `/root/.m2`, `/root/.deps.clj`, `/app/.cpcache` |
| Resource | `colors-redis/redis-operator-doks`, `reconcileInterval: 30s`, `deletionPolicy: Retain`, UID `d1e760f1-2d2c-404f-8365-2d643d36ebed`; backups `*-*-* 00/6:00:00`, retention 7 days, max age 8 h |
| Package caps the grace period is compared with | Ansible play 7200 s (`redis/green/src/clj/io/github/getcolors/redis/tools.clj`, `play-timeout-ms`); OpenTofu plan 1800 s and apply 1800 s per stage (`colors-compute/green/src/clj/io/github/getcolors/compute_execution.clj`) |
| Workstation | `direnv`/`devenv` toolchain; the kubeconfig rendered by `doks-dev` (24 h expiry) |

Wall times at these pins: `doks` create 356 s infrastructure + 19 s
registry, repeat create 13 s + 2 s; first operator create converged at
`06:55:40Z` from a `06:51:07Z` start including one failed Ansible attempt;
drill 5 min 21 s from delete accepted to verified; rehearsal 45 s
(suspend to resume); passing restart 54 s; `check` after the restart fix
20 s; delete 107 s finalizer + 16 s namespace + 1 s CRD; `doks` delete 15.6
s infrastructure + 4.5 s registry.

### The launcher-pin sequence of 2026-09-16

The deployment moved through five payloads in one day; each pin is what
the verbs listed beside it ran on.

| Launcher commit | Pins library | What ran on it |
|---|---|---|
| `7e9adf0` | `f163b48` (the Package Skill port) | `doks` create, image 1, the first create; the two failing `check`s |
| `c461339` | `1de4b5c` (polled Ready, failure retention) | image 2, the image roll, the drill, the rehearsal, the failed restart |
| `e59a5ab` | `8030c7f` (pod-clock restart proof, exec gate, caches on the PVC) | the passing restart, `check-after-restart-fix.log`, the failed delete |
| `cb2b5f3` | `7723970` (resourceVersion retry) | the passing delete, the `doks` delete that failed on the leftover, the repeat `doks` delete |
| `e9fe076` | `5f37868` (private `DOCKER_CONFIG` in `image.sh`) | nothing live; the payload refresh that closed the handoff |

## The verified-good set: 2026-09-15 (`redis-doks`)

| Component | Pin |
|---|---|
| Green SDK | `215e298` |
| redis package | `ec260f5` |
| colors-compute | `ae28ea74962bb1897fa6365c143c1d43ac1fe095` — no interrupted-operation repair |
| redis-operator source | `e072b43da92cf002da2d8bbd3a3615631bf06feb` (pre-Package-Skill; Python scripts drove install, self-heal, rehearse, restart) |
| doks | `399b5f3` (pre-Package-Skill; a hand-written launcher) |
| Controller image | `registry.digitalocean.com/colors-redis-20260915/redis-operator@sha256:659414485f9686a7854cda8596a3cafa6ebf99862f4373422d1469524bb2d7b7`, `linux/amd64`; the suite ran inside it on the worker: 8 tests, 50 assertions, 0 failures |
| DOKS | `colors-doks-dev-20260915` `a87775cd-de9f-4390-8dee-281f864bc9de`, `ams3`, `1.36.3-do.5`, worker `600715804` at `209.38.46.78` |
| Controller Deployment | `terminationGracePeriodSeconds` 7500 (`install.clj` at `e072b43`), dependency caches **not** on the PVC |
| Resource | `colors-redis/redis-dev`, profile `redis-doks-20260915`, UID `980b8bf0-7801-4cc7-bf4a-e1325d68dfee` |
| Redis Droplets | `600721546` at `165.22.198.189` (first create), `600724611` at `206.189.110.180` (drill replacement), `600730033` (deleted at shutdown; unexplained) |

Drill 5 min 46 s at generation 3; rehearsal generation 4 → 5; restart
64.8 s including a 45 s sleep, never reading `lastReconcileTime`.

## The rules that generated it

### Pin the image by digest, the package by SHA, the CRD by the package

`validate/image-re` refuses an `image` without `@sha256:` and 64 hex
digits. The launcher refuses to run without a stamped
`redis-operator-sha`. The CRD is a classpath resource of the pinned
library, so `build` cannot render a CRD from a working tree by accident.
A change to `src/colors/` (the controller) needs a new image; a change to
`src/io/github/getcolors/redis_operator/` (the package) needs a new pin;
a change to `crd.yml` needs both.

### The controller image never executes Babashka at build time

Babashka's native image does not run reliably under QEMU, and the image is
cross-built for `linux/amd64` on an arm64 workstation. `bb test` runs on
the host before the build; the image's `colors.main` and `colors.probe`
are proven to load by CI from a clean checkout and, on 2026-09-15, by the
suite in a pod on the worker.

### The grace period exceeds the caps it cites

10800 s is above 7200 s (one play) plus 1800 s (one plan), so a rolling
restart cannot SIGKILL a workflow inside those two. It is not above the
sum of every stage a create runs (plan and apply, shared and node, each
1800 s); see the boundary in `SKILL.md`. Pair it with a `colors-compute`
that can repair an interrupted operation.

### One controller, one worker, one replica

`colors.main` starts the controller with `:workers 1 :poll-ms 2000`; the
identity lock is process-local; neither `Recreate` nor the PVC fences a
disconnected old controller. `restart` never force-deletes and never
scales back up while a pod remains.

### Retest conditions

- **Any `green` bump past `215e298`:** re-run `restart`; the pod-clock
  proof depends on `lastReconcileTime` being written by every pass and on
  `RedisDeployment controller running` being printed after `start!`. Check
  whether `green.kubernetes.client/request!` starts surfacing HTTP status;
  if it does, the 409 branch in `reconcile-locked!` becomes live and the
  boundary entry becomes wrong in the safe direction.
- **Any `reconcileInterval` change:** the Reconciling window is per pass,
  not per interval; a longer interval widens the Ready window but does
  not remove the trap. A single-read `check` is wrong at any interval.
- **Any `redis` bump:** re-run a create on a fresh Droplet and read
  `failures retained`; the first-attempt Ansible failure has no cause and
  no retest condition other than "did it happen again, and what does the
  retained log say".
- **Any `colors-compute` bump:** re-run the drill; `droplet-absent`
  handling, the `partial` refusal and the journal repair are all library
  behaviour the adapter relies on. Re-run an authorized delete and read
  the journal as `retired`.
- **Any kubectl or apiserver bump:** confirm the 422 message for a failed
  JSON-patch `test` op still reads `the server rejected our request due
  to an error in our request`; `tools/stale-patch-message` matches that
  substring and nothing else, so a reworded message turns the retry off
  silently and the delete fails as it did before `7723970`.
- **Any DOKS version bump:** re-measure how long the worker and the
  `k8s-<cluster-id>-*` firewalls outlive the cluster; the four-minute
  figure was observed once.
- **Any `doks` or `image.sh` change touching `DOCKER_CONFIG`:** run a
  `doks` delete after an image build and confirm the cleanup stage
  removes `registry/`.
- **A base image retirement or a resize of the Droplet:** the converge
  loop in the boundaries is predicted from `provider-matches?`, not
  observed; if it is observed, move it to the catalogue with its log.
