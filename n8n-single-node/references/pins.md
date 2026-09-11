# Pins

## The verified-good set

Running together on a Vultr `vhp-8c-16gb-amd` (Ubuntu 24.04, os id 2284) with
every acceptance gate passing, plus the load, retention, restart and restore
drills. **Verified 2026-09-01.**

| Component | Pin |
|---|---|
| n8n | `docker.io/n8nio/n8n:2.36.9@sha256:a9e2e3c8006ed453238266669ea1274be7136f515abe290a2f75a0ab9044c93d` |
| n8n task runners | `docker.io/n8nio/runners:2.36.9@sha256:99811ba57933dd77895f5fedbb555ce105bac8a82812205f6396d52a30b32e66` |
| Caddy | `docker.io/library/caddy:2.11.4@sha256:df7f1c2fb114453b951de51a98efc010db1655a92c2e86be6706714e2417a78d` |
| Neon storage | `ghcr.io/neondatabase/neon:release-9129@sha256:166022a72bf9983eba96d061d794f4740edbd4c3301e66202c1180acce9a323c` |
| Neon compute | `ghcr.io/neondatabase/compute-node-v17:release-compute-9073@sha256:ed6a613231d7026b4df8b00563444b9f33745370a3b3f0a2183e723f460ba974` |
| Postgres major | 17 (17.5 as served by the compute image) |
| n8n schema | 246 migrations applied at 2.36.9 |
| Host packages | Ubuntu 24.04 apt: `docker.io`, `docker-compose-v2`, `postgresql-client` (**16** — see below), `rclone`, `jq`, `openssl`, `python3` |

## The rules that generated it

The specific versions will age out; these constraints are what matter.

### The runner image version must EQUAL the n8n image version

Upstream requires it. A mismatch does not fail at boot — the runner connects
normally and then fails every task, so the first symptom is a Code node failing
long after a converge reported success. Make it a validator rule, not a note.

### Digest-pin, because the version tag is mutable

n8n republishes tags. `2.36.9` was pushed 2026-08-31 and is the release tagged
`stable`; the digests above are the manifest-list digests, not per-architecture
image digests.

### The host Postgres client will not match the server

Ubuntu 24.04's `postgresql-client` is **16**; the Neon compute image serves
**17.5**. `psql` is protocol-compatible across that gap and works fine — which
is why every query-based gate passes against the host client and gives no hint —
but `pg_dump` and `pg_restore` refuse outright. Run those inside the compute
container, whose image carries matching binaries, rather than adding the PGDG
repository: the client and server then stay married across a compute image bump.

### The Neon pair moves together or not at all

Storage releases (`release-NNNN`) and compute releases (`release-compute-NNNN`)
are separate trains with separate numbering; there is no shared release number.
The pair above is the last deliberate pairing upstream shipped before moving to
untagged continuous deployment. See `neon-single-node/references/pins.md` for
the storage tier's own rules.

## Retest conditions

Claims decay when pins move. These have known retest conditions:

- **Any n8n minor bump** — re-read the environment-variable reference for the
  deployed version before trusting anything in this skill's version table. Every
  claim there was true of 2.36.9 and several were *not* true of what the 2.0
  breaking-changes page says.
- **`EXECUTIONS_DATA_PRUNE` defaults** — verified `true`/336h/10000 at 2.36.9.
- **The `/rest/workflows/{id}/run` body shape** — `triggerToStartFrom` was the
  only accepted form at 2.36.9; `startNodes` and `destinationNode` were refused.
- **Credential redaction** — the API returned a 54-character sentinel for a
  27-character secret. If a future version returns plaintext, the
  "use it, don't read it" doctrine still holds but the reasoning changes.
- **Archive-before-delete** — required at 2.36.9. If a future version restores
  direct DELETE, cleanup code written against this note still works.
- **The soak numbers** — 7950 executions / p95 75 ms / p99 80 ms are specific to
  `vhp-8c-16gb-amd` with NVMe and the declared workload mix. A different disk
  class invalidates them; `vc2-*` plans are SSD, not NVMe.

## AWS port, offline validation

Offline-validated on 2026-09-11; no host has run this set. Package feature
commit `2979693f3371b69cc26d93d413bfcea18b0089d5`, launchers stamped by
`cf35a44ba4c5dc86a5a4a6dd88b004a60b82286f`; the acceptance-step sudo fix
`be6a5efbf39a9c61341139172b2924f1e78d3a47`, launchers stamped by `91a483d`;
the `n8n-aws` deployment's `skills-lock.json` records `package-n8n-green`
from that last publication. The
image pins in the table above are unchanged by the port, and the AWS fixture
carries the same five digests. See `aws.md` for what was and was not
exercised.

| Component | Pin or declared value |
|---|---|
| Green SDK | `3f33f5d4dcce1f8d97a11b6972e13eb3f0b37654` (the tofu launch-failure exit) |
| colors-compute | `09ec539e75dc21c4dafb019eb8f9da276e695f6f` (managed S3 backend); the same SHA in `green/deps.edn`, `red/package.json` and `blue/pyproject.toml` |
| Reused Neon package | `e19a213067d307b55d1b37a2e83cdc1a150b7d91` |
| ONCE dependency | `a1fe1be7a427dd2e406ff7befd1c43a53e7c3618` |
| AWS provider, storage stage | `hashicorp/aws` 6.31.0 |
| AMI | `ami-025d99823a4caad37`, declared as Ubuntu 24.04 amd64. The same AMI booted as Ubuntu 24.04.4 LTS for the `neon-multi-node` skill on 2026-09-10; that is its evidence, not this skill's |
| Instance | `t3.xlarge` (4 vCPU, 16 GiB), `us-east-1a` |
| Root volume | `aws-root-volume-size-gb: 60`; the deployment's comments call it encrypted gp3, and what the adapter renders is `colors-compute`'s to prove |
| VPC / subnet | `10.76.0.0/16` / `10.76.1.0/24` |
| Host packages | not observed; the Vultr row above is the last observation |

### Retest conditions for the AWS set

- The first live converge is itself the retest of everything in `aws.md`;
  until it runs, that file's claims stay source-derived.
- Any `colors-compute` bump that touches the managed backend, the AWS adapter
  or the finalization statuses (`destroyed`, `absent`, `skipped`): re-run a
  delete and a second delete.
- Any `hashicorp/aws` bump in the storage stage: re-run the post-apply plan.
  The clickhouse sibling saw SSE readback drift at 6.31.0 with the SSE shape
  this stage still carries.
- A Neon pin bump: the `COLORS_PAR_NEON_R2_*` lookups in the upstream play are
  the interface the managed pairs ride on; a renamed lookup silently empties
  `/etc/neon/r2.env`, and the upstream play's own "empty R2 key id" check is
  what would catch it.
- The soak thresholds: the 2026-09-01 numbers are `vhp-8c-16gb-amd` NVMe
  numbers and do not transfer to `t3.xlarge` on gp3. The AWS deployment
  inherits the same thresholds, and the first live soak decides whether they
  hold.
