---
name: n8n-single-node
description: Everything a self-hosted n8n 2.x deployment needs that the docs and every third-party guide will not tell you - n8n refusing to boot with "Mismatching encryption keys. The encryption key in the settings file /home/node/.n8n/config does not match the N8N_ENCRYPTION_KEY env var" after one bad first boot, "password authentication failed for user" when the password is a literal unrendered template string, /healthz returning 200 while every API call answers 503 "Database is not ready!", DELETE refused with "Workflow must be archived before it can be deleted", "To run the workflow manually, specify either a trigger to start from or a destination node", pg_dump "aborting because of server version mismatch", and WEBHOOK_URL quietly deprecated in favour of N8N_WEBHOOK_URL. Use whenever the user self-hosts n8n on Postgres, puts its database on Neon or object storage, fronts it with Cloudflare and Caddy, or hits any symptom above. Full symptom index at the top of the body.
---

# Single-node self-hosted n8n

## Symptom index

Load the rest of this skill when any of these appear; each has a full entry
with verbatim symptoms in `references/failure-catalogue.md`:

- `Mismatching encryption keys. The encryption key in the settings file
  /home/node/.n8n/config does not match the N8N_ENCRYPTION_KEY env var`
- `password authentication failed for user "n8n"` when the credential is
  correct — the container received an unrendered template string as a password
- `/healthz` returns `200` while every API call answers
  `503 {"code":503,"message":"Database is not ready!"}`
- `400 {"code":400,"message":"Workflow must be archived before it can be deleted."}`
- `400 {"code":400,"message":"To run the workflow manually, specify either a
  trigger to start from or a destination node."}`
- `pg_dump: error: aborting because of server version mismatch` /
  `server version: 17.5; pg_dump version: 16.15`
- `wget: unrecognized option: save-cookies` from a probe inside the n8n container
- a credential read back through the API that "decrypted to the wrong value"
- Ansible: `Error loading tasks: failed at splitting arguments, either an
  unbalanced jinja2 block or quotes` on a shell task that looks fine
- `rclone` against R2: `InvalidArgument: Authorization  status code: 400`
- `could not open input file "/tmp/r.dump": No such file or directory` after a
  `docker compose cp` that reported success
- a converge that reports success while `caddy` and the task runner sit in
  Docker state `created`, never started
- Cloudflare: `data.cloudflare_zone.zone ... 0 found` while
  `/user/tokens/verify` says `Invalid API Token`
- an execution stuck in `running` forever, never reaching a terminal status

## What this covers, and what paid for it

n8n is a workflow automation engine that stores workflows, encrypted
credentials and execution history in a database. Self-hosting it is widely
documented and the documentation is widely wrong in specifics, because n8n 2.x
changed defaults and key names that every guide still repeats from 1.x.

This skill was distilled from a build that put n8n **2.36.9** on one Vultr
instance with a colocated self-hosted Neon as its database — storage/compute
separated Postgres with layers and WAL in Cloudflare R2 — behind Caddy, with an
external task runner. Sixteen converges against the real platform, a
three-round adversarial plan review, seventeen acceptance gates, and five
operational drills (load soak, retention, full-stack recreate, unattended
reboot, and a restore rehearsal).

Everything here was verified against a running deployment unless it says
otherwise. Where this skill contradicts n8n's own documentation, the version's
own environment-variable reference or a live probe is the authority, and the
entry says which.

**Most of it transfers to any self-hosted n8n on Postgres.** The Neon-specific
parts are marked; the n8n 2.x parts apply whatever the database is.

## The reference implementation, and why this skill ships no assets

The working files live in the
[`getcolors/n8n`](https://github.com/getcolors/n8n) Package Skill — the Compose
overlay, the Caddyfile, the acceptance gates, the backup and restore scripts,
the drills — under `green/src/resources/io/github/getcolors/n8n/tools/`,
covered by that repository's tests, golden fixtures and validator, and consumed
by the [`n8n-vultr`](https://github.com/getcolors/n8n-vultr) deployment. The
storage tier belongs to [`getcolors/neon`](https://github.com/getcolors/neon).
This skill carries no copies of any of them, per the Context Skill Standard's
no-second-copy rule. Read the templates there; read *why they are shaped that
way* here.

## The version trap, first

n8n 2.x moved things that every guide still gets wrong. All of the following
were read from the deployed version's own environment-variable reference, and
several were confirmed by the adversarial reviewer being wrong about them too.

| Claim you will read everywhere | What 2.36.9 actually does |
|---|---|
| `WEBHOOK_URL` sets the external URL | **Deprecated since 2.35.0**, alias of `N8N_WEBHOOK_URL`, logs a startup warning |
| "any missing `DB_POSTGRESDB_*` silently falls back to SQLite" | False. SQLite is default only when `DB_TYPE` is unset or misspelled |
| 2.0 made Code-node env access secure by default | `N8N_BLOCK_ENV_ACCESS_IN_NODE` defaults to **`false`** |
| 2.0 defaults task runners to external | `N8N_RUNNERS_MODE` defaults to **`internal`** |
| execution pruning must be enabled | `EXECUTIONS_DATA_PRUNE` already defaults to **`true`** (336 h / 10000) |

**Rule this proves: for a version released days ago, only that version's own
docs count.** The 2.0 breaking-changes page and the environment-variable
reference disagree with each other; the reference matched the running binary.

### The settings that actually cause OOM

Pruning is on, so the execution table is not the danger. These two are, and
both default to the unsafe value:

- `N8N_DEFAULT_BINARY_DATA_MODE` defaults to `default`, which holds binary
  payloads **in memory**. Set `filesystem`.
- `N8N_CONCURRENCY_PRODUCTION_LIMIT` defaults to `-1`, unbounded.

A Code node duplicates its payload before and after processing, so peak memory
is roughly **3× the largest payload × the concurrency bound**. That product,
not the average workload, is what sizes the machine.

### The encryption key is a property of the operator, not the disk

n8n writes `N8N_ENCRYPTION_KEY` into `/home/node/.n8n/config` on **first boot**
and refuses to start ever after if the environment disagrees. One bad first
boot — a wrong key, or an unrendered template expression that reached the
container as a literal string — poisons the data directory permanently, and the
error appears on the *next* boot rather than the one that caused it.

Repair is not automatable. Deleting the settings file is correct only when the
database holds no encrypted credentials; when it does, that file is the only
thing that can decrypt them, and removing it destroys them silently. Fail
loudly, state both options, let a human choose.

## Topology that survived

One host, seven containers in **one** Compose project: the four Neon services
(`storage_broker`, `pageserver`, one `safekeeper`, `compute` running Postgres
17), plus `n8n`, `n8n-runners`, and `caddy`. Only Caddy publishes beyond
loopback; every Neon port stays on `127.0.0.1` and the task-runner broker is
reachable only on the project network.

- **n8n reaches the database as `compute:55433`** over the shared project
  network. Neon's loopback publications are for the operator's SSH tunnel and
  are irrelevant to container-to-container traffic.
- **External task runner, not internal.** Internal mode runs Code nodes as a
  child of the main process, under the same uid, with read access to the
  environment holding the encryption key. External mode costs one container and
  a shared token — and upstream requires the runner image version to **equal**
  the n8n image version. A mismatch connects fine and then fails every task, so
  it surfaces at first Code-node execution rather than at boot.
- **No queue mode, no Redis.** Nothing on one host can use worker scale-out.

## Reusing another package's storage tier

*(Specific to the Colors ecosystem, but the lessons generalise to any layered
infrastructure code.)*

The n8n package does not reimplement Neon. It SHA-pins `getcolors/neon` and
renders that package's Ansible templates straight off the classpath, so no copy
of the storage tier exists to drift. **Classpath access alone is not an
interface**, though — four things had to be contracted explicitly, each found by
reading the upstream play rather than assuming:

1. **The upstream play runs `docker compose` with no `-f` flags.** A downstream
   overlay passed on the command line would be invisible to every upstream task
   and handler. Install it as `compose.override.yml` beside the upstream file;
   Compose merges it automatically and every unchanged upstream command then
   operates on the merged project for free.
2. **`name:` is declared exactly once.** Two files declaring it give merged and
   unmerged commands different projects, different networks, and an
   unresolvable database host.
3. **The upstream bundle renders into its own directory**, because that play
   copies templates by *relative* `src:` name — a downstream file with the same
   basename wins silently.
4. **The upstream play owns the database credential.** It generates the role
   password on the host; minting a second one produces a password the role does
   not have.

**The general rule: a reused package's interface is its command invocations, its
file layout, its handler names, its environment-variable contract, and its files
on disk — none of which appear in its API surface.** Replacing one of its
*templated* config files with your own hand-written version silently drops
whatever conditionals it carried, and the loss surfaces as a runtime failure far
from the edit.

## Acceptance doctrine

Full detail in `references/acceptance.md`. The three lessons worth stating here:

**A gate that is never invoked is worse than no gate.** The first fully green
converge of this build reported success in 614 ms with **zero** application
gates executed — the smoke script was written, rendered, installed to the host,
and never called. Inheriting a package's acceptance *step* does not inherit its
*gates*: the step is the operator-side half, and a downstream play must invoke
its own. **Time the acceptance stage and disbelieve a fast pass** — a suite that
finishes faster than its own sleeps is not running.

**Gate end state, never task outcomes.** Two containers sat in Docker state
`created`, never started, across a converge that reported success: an earlier
run had failed their health dependency, and no later run changed a file, so the
`notify:` handler that would have started them never fired. A handler expresses
*"an input changed"*, not *"the world should look like this."* Only the gates
that checked the certificate and the runner caught it.

**Several gates can pass while proving the opposite of what they claim.**
Readiness proved a restore had worked while the scratch database was empty — n8n
migrated a blank database and reported ready. A credential comparison reported
that the encryption key had not survived, when in fact n8n returns a
fixed-length sentinel for every credential value and the comparison could never
have succeeded.

## Durability, measured

**Neon handles n8n's write pattern with large margin.** On a Vultr
`vhp-8c-16gb-amd`, with a declared mix (60% API-shaped, 25% Code-node at 8 MB to
trigger the payload duplication, 15% binary at 4 MB through the filesystem
path):

```
soak: 7950 executions, 0 failed, 10 workflows
sql round-trip p95=75ms p99=80ms
host memory 12% disk 9%
```

Reproduced across two independent five-minute runs with identical percentiles.
The p95→p99 gap of 5 ms is the informative number: storage/compute separation
adds no visible tail latency at ~26 executions per second.

**Honest scope:** five minutes, one host, ten concurrent workflows, no competing
tenant, and a Code-node tier that allocates rather than computes. It does not
establish behaviour over days, under pruning of a large execution table, or
during a pageserver restart under load. What it does establish is that the
obvious objection — that storage/compute separation is too slow for OLTP — is
false at this scale, and it was measured rather than assumed.

## Recovery, and the RPO nobody states

Neon uploads WAL to R2 continuously, which reads like continuous backup. It is
not: a **rebuilt safekeeper does not recover its offloaded WAL** — the
walproposer bootstraps it from the compute basebackup instead. (Established by
`getcolors/neon`'s own fresh-safekeeper drill; see `neon-single-node`.)

| Failure | Recovers from | RPO |
|---|---|---|
| pageserver local state lost | R2 layers + surviving safekeeper replay | ~0 |
| compute lost or corrupted | recreate from pageserver | ~0 |
| **whole host lost** | the logical backup set | **one backup interval** |

So the backup *interval* is the RPO, which makes nightly indefensible for a
system holding live third-party credentials. Six hours, and the dump is small.

The backup set is a logical dump, a tar of the n8n data directory, and a
manifest with checksums and one shared timestamp. `docker pause` is the wrong
quiesce — it can freeze a session holding locks, so `pg_dump` blocks or captures
an interrupted filesystem operation. Stop n8n properly, drain its database
sessions, capture both, resume from an always-run cleanup path.

**A restore that nobody can log into is not a recovery.** Whole-host recovery
restores the database and the data directory but *not* the host's generated
secrets, so the rehearsal must prove an operator can actually sign in — and must
prove a stored credential decrypts, which cannot be done by reading it back
(see the catalogue). Use the credential in an execution; n8n fails the node if
it cannot decrypt.

## Networking

Fronting n8n with Cloudflare and Caddy has one coupling that fails silently:
**restricting the origin firewall to Cloudflare's ranges requires the DNS record
to be proxied.** Unproxied, Caddy's ACME HTTP-01 challenge arrives from Let's
Encrypt's own addresses and is dropped — *the converge still succeeds*, and the
failure surfaces later as the first HTTPS request hitting a certificate that was
never issued.

Behind Cloudflare *and* Caddy there are two proxies, so `N8N_PROXY_HOPS` is 2,
not n8n's default of 0. And trusting `X-Forwarded-For` is only safe because the
firewall admits nothing else — trusting a header from an open origin is trusting
the header's author.

## Encoding traps as gates

The single most useful habit this build produced. A trap written down in prose
gets read once; a validator runs on every converge. The package's validator
refuses the deprecated `WEBHOOK_URL` spelling by name, refuses a runner image
whose version differs from the main image, refuses `binary-data-mode: default`,
refuses an unbounded concurrency limit, and refuses Cloudflare-only ingress
without a proxied record.

The counter-example is in this session's own history: the
`failed at splitting arguments` trap is documented by name in the sibling
`neon-single-node` skill, was copied into the build's plan, and was walked into
anyway while writing the line. **Prose gets read once. A gate runs every time.**

## References

- `references/pins.md` — the verified-good version set and the rules that generated it
- `references/failure-catalogue.md` — symptom-indexed, verbatim
- `references/acceptance.md` — what each gate checks and why
