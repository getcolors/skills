# Native runtime boundaries and dated proof

## Live runtime handoff

On September 10, 2026, native Red create finished seven external acceptance gates
at 15:15:40 UTC, then native Blue create converged the same AWS profile and finished
those gates at 15:24:01 UTC. Independent public probes passed eight gates after
each run, including the exact random witness established after Red create.
`cycle1-cross-runtime-continuity.json` proves the same five instance IDs, five
root volume IDs and six container IDs before and after the handoff. Both storage
inspections passed application/backend bucket separation and credential denial
checks; network and DNS inspections passed after readiness.

These are real AWS results at application source
`038e93d524552ef36fb0fff5f306352e68283bff`, not a translation or dry-run comparison.
The native implementations use the same colors.yml profile, colors-compute state,
role order and application payload. The runtime changes orchestration language;
it does not authorize a second concurrent lifecycle operation against the same
profile. Preserve profile identity, managed backend ownership and pinned native
SDK overrides when switching. Compare resource identities and exact SQL witnesses,
not just the final process exit or container count.

Evidence is under the separate
[red-blue evidence directory](https://github.com/getcolors/neon-multi-node-aws/tree/main/evidence/red-blue):
`red-create-1.txt`, `blue-create-1.txt`, `cycle1-public-red.txt`,
`cycle1-public-blue.txt`, `cycle1-cross-runtime-continuity.json`,
`cycle1-storage-red.json`, `cycle1-storage-blue.json`, `cycle1-network-red.json`
and `cycle1-dns-red.json`. Handoff does not itself prove recovery or deletion;
those separately observed gates follow below. The original Green acceptance
evidence remains scoped to its original source pins.

## First lifecycle: Blue recovery and deletion

Blue rehearsal1 completed all faults, including compute recreation, each
safekeeper absent during its own acknowledged write, two-member quorum loss,
broker restart, pageserver tenant-cache removal and S3 reattachment, and one
empty safekeeper rebuilt through its two surviving peers. Independent
`cycle1-recovery.json` verified three unique acknowledged outage witnesses,
one per member, through trusted external TLS after recovery; S3 attachment
generation was 2. `cycle1-public-recovered.txt` passed all eight public gates
including the original random witness. `database-version.json` observed server
PostgreSQL 17.5.

`cycle1-no-quorum.json` and `blue-rehearse-1-ansible.txt` record no acknowledgement
for 45.182715 seconds. The uncertain row was actually present after recovery.
This observation is distinct from the original Green rehearsal and again rules
out treating a client timeout as proof of rollback. Three witnesses belong to
this fresh lifecycle; do not add them to the older Green database's six witnesses
or claim six writes survived one new rehearsal.

The Blue default deletion guard refused with exit 2 (`blue-delete-guard.txt`).
Authorized `blue-delete-1.txt` then completed with exit 0, including backend
finalization. `cycle1-blue-writer-stop.txt` independently proves all five hosts
stopped Neon containers and writer processes in that same invocation before
application storage deletion. The workflow then removed aliases, DNS,
application S3/IAM, compute resources and finally its managed backend.
Independent `cycle1-resources-absent.json` then counted zero remaining
deployment resources, verified all five recorded volumes absent, both buckets
returning 404, and no scoped IAM resources. Separate DNS and local SSH absence
audits passed. `blue-delete-repeat-1.txt` passed the authoritative backend
finalizer after complete retirement. This is independent absence and repeated
delete proof, not an inference from workflow exit 0. The reverse-order lifecycle is tracked separately below.

## Second lifecycle: reverse runtime handoff

A fresh Blue create completed seven external gates at 15:55:21 UTC on September
10, then Red reconverged that same new profile at 16:03:11 UTC. Independent
public probes passed eight gates after each, including the exact random witness
created in this second database. `cycle2-cross-runtime-continuity.json` proves
the same five instances, five volumes and six containers across Blue-to-Red
reconvergence. Separate cycle2 storage, network and DNS inspections passed.

Together the two lifecycle create tests demonstrate both runtime handoff orders
at application source038e93d; the second cycle starts a fresh database after
complete first-cycle retirement. This does not combine the databases' witness
histories.

Red rehearsal then passed the same complete fault sequence as Blue. Independent
`cycle2-recovery.json` verified its three unique acknowledged safekeeper outage
witnesses through trusted external TLS; `cycle2-public-recovered.txt` retained
its original random witness and passed all eight gates. The S3 attachment
generation reached 2, and service/storage inspections found six healthy
containers and preserved storage credential isolation. `cycle2-no-quorum.json`
records 45.132080 seconds without write acknowledgement. Its uncertain row was
observed present with value possibly-committed after recovery, again proving
neither a timely acknowledgement nor rollback.

Red's default deletion guard refused with exit 2. Authorized Red deletion then
completed with exit 0. Independent `cycle2-resources-absent.json` counted zero
remaining deployment resources and zero billable resources; both buckets and
all five recorded volumes were absent. `cycle2-dns-absent.json` and
`cycle2-local-absent.json` proved DNS and local SSH cleanup. Both native Red and
Blue repeated deletion successfully against this retired profile, as recorded
in `red-delete-repeat-2.txt` and `blue-delete-repeat-2.txt`. The subsequent
`cycle2-resources-after-repeat.json`, `cycle2-dns-after-repeat.json` and
`cycle2-local-after-repeat.json` independently confirmed continued absence.

The two new lifecycles establish fresh create, convergence from the other native
runtime, recovery, guarded deletion and repeat deletion at the stated source
pins. Each new database supplied three acknowledged outage witnesses and its own
random external witness. The original Green deployment remains a separate proof
with six outage witnesses. None of these runs establishes simultaneous lifecycle
execution, multi-zone availability, automatic compute/pageserver failover or
recovery after every storage disk is lost.

## Negative subprocess status bypasses failure

This was found and verified offline before the native live deployment, not by
interrupting AWS teardown. Blue SDK `290f313ead5ca162875c33a049c880da017eae09`
returned negative timeout/signal statuses while workflow and Terraform helpers
classified only positive statuses as failures. A stubbed timeout produced
`blue/exit=-1` with `workflow_failed=false`. A stubbed Terraform init status 0
followed by destroy status -15 produced reported exit 0. Source review found
Red's corresponding timeout -1 and positive-only checks; no pre-fix live Red
interruption was performed.

Fix the execution boundary, not merely the final application's reported status:
Terraform may already have removed its rendered files before a caller normalizes
that result. The pinned native execution boundaries, Blue `runtime.exec` and Red `exec`,
now emit timeout 124 and
negative signal status as 128 + signal; normal 0/positive codes remain unchanged.
SIGTERM becomes 143. The workflow's positive-failure contract stays intact.

The actual local child-process regressions cover normal 0/7, SIGTERM and timeout.
Real fake-Terraform executables verify that interrupted destroy remains a positive
failure and preserves rendered main.tf: signal in Blue, signal and timeout in Red.
Both SDK suites passed 102 tests with one optional Floci integration skipped;
Red also passed typecheck. See `sdk-verification.json`, `blue-sdk-tests.txt`,
`red-sdk-tests.txt` in the evidence directory above, and immutable test sources:
[Blue](https://github.com/getcolors/blue/blob/e29a7fc5a7a2895eacb882fc65520c2cdbab96c9/tests/test_runtime.py),
[Red](https://github.com/getcolors/red/blob/7636bee6a7575485ebaf621f4b1834bdcea59738/test/runtime.test.ts).
Pin both direct dependencies and overrides so the package and colors-compute
resolve the same corrected native SDK. These tests prove local process/status
and scaffold retention behavior, not live interrupted cloud deletion safety.

## Bun cold Git resolution

A copied public Red launcher under Bun 1.3.10 failed before deployment with:

```text
red: resolving dependencies (first run)
red: could not resolve dependencies
error: colors-compute-red@github:getcolors/colors-compute#09ec539e75dc21c4dafb019eb8f9da276e695f6f failed to resolve
error: red@github:getcolors/red#7636bee6a7575485ebaf621f4b1834bdcea59738 failed to resolve
```

The failure was intermittent while resolving pinned direct/transitive Git
dependencies. The evidence does not isolate Bun's internal root cause. A warm
checkout or downloaded archive did not prove a copied
launcher could bootstrap. Offline repeated fresh-cache tests reproduced the Git
resolver failure. The verified fix is the launcher's `installToCache` at
`62e63a7a63ae5c5ab46cbb73b8dad06d14ab0734`: validate full 40-character Git pins,
map them to immutable codeload commit archives, and supply the same mapping in
both dependencies and overrides. It stages the installation, publishes the cache
only after success, and keys that cache by exact pins.

Eight independent fresh caches passed with the archive implementation. Evidence:
`red-build.txt`, `red-cold-archive-run0.txt` through `red-cold-archive-run7.txt`,
and `published-cold-launchers.txt`. The latter checks copied public payloads with
empty credential environment, nested profile discovery, build and four dry-run
verbs. This is offline resolver qualification; the separate live create evidence
establishes application behavior. Retest truly empty caches after Bun, launcher,
pin or dependency graph changes. Do not accept a local library override as proof
that a published install works.
