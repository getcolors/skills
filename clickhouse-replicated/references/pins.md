# Pins

## The verified-good set

Three replicas with embedded Keeper on three Vultr instances in `ams`, every
gate in `acceptance.md` passing, the restore beside the live database
rehearsed and the replica-loss drill run. **Verified 2026-09-03**, as the
ClickHouse tier of the `getcolors/langfuse` build.

| Component | Pin |
|---|---|
| ClickHouse server, client, common-static | `26.3.29.7`, installed by exact version (`clickhouse-server=26.3.29.7` …) from `https://packages.clickhouse.com/deb`, suite `stable`, component `main` |
| Repository signing key | `https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key` into `/usr/share/keyrings/clickhouse.asc`, wired through `deb822_repository` — the key the play used; the deb repository accepted it |
| Keeper | embedded: the `<keeper_server>` block inside the server config, one voter per node, `server_id` = ordinal + 1 |
| Cluster | `default`; one shard; `internal_replication` true; `<secret>` on the cluster; ports 8123 / 9000 / 9009 / 9181 / 9234 |
| Replica path | `/clickhouse/tables/{uuid}/{shard}`, replica name `{replica}`; macros `shard=01`, `replica=node-<ordinal>` |
| Backup disk | `type=s3_plain` on Cloudflare R2, endpoint `<r2-endpoint>/<bucket>/<profile>/clickhouse/`, credentials in the disk config, `use_environment_credentials=false`; node 0 only |
| Backup schedule | nightly `02:30` UTC set on node 0 (`OnCalendar=*-*-* 02:30:00`, `Persistent=true`); monitor every 15 minutes on every node; freshness threshold 30 h |
| Instances | Vultr `vc2-4c-8gb` ×3 (4 vCPU / 8 GiB — the documented minimum is 2 CPU / 8 GiB per node), Ubuntu 24.04 (`os_id` 2284), one `vultr_vpc` (not `vultr_vpc2`, whose API Vultr has retired) |
| Host packages | Ubuntu 24.04 apt: `ufw`, `ca-certificates`, `curl`, `gnupg`, `apt-transport-https`, `jq`, `python3`, `openssl`, `rclone` (1.60.1) |
| Companion | `getcolors/langfuse` at the pin the `langfuse-vultr` deployment installs; templates under `src/resources/io/github/getcolors/langfuse/tools/` |

## The rules that generated it

### Exact version from the `stable` suite, loudly

`packages.clickhouse.com/deb` serves `stable` and `lts` and installs by exact
version. The play pins `clickhouse-common-static`, `clickhouse-client` and
`clickhouse-server` to the same string from desired state; a repository that
stops serving that version fails the converge at the apt step rather than
drifting to whatever is current. `26.3.29.7` was the LTS train served on
2026-09-03. The floor came from the application: Langfuse v4 requires
ClickHouse ≥ 25.12 (JSON type, lightweight updates, full-text search) — an
application rule, recorded here because it decided the train.

### Embedded Keeper, one voter per replica, ids from the ordinal

Three ClickHouse nodes each carry a Keeper voter inside `clickhouse-server`
(no standalone `clickhouse-keeper`), and the three make the quorum. Keeper
ids start at 1, so `server_id` is the inventory ordinal plus one; the
`raft_configuration` lists the same three ids against the VPC addresses.
Verified by the Keeper gate (`system.zookeeper` root readable) and by the
cluster count from every node.

### The replica path carries `{uuid}`

`default_replica_path` = `/clickhouse/tables/{uuid}/{shard}` is inherited
from the Hetzner ancestor and is what makes `RESTORE DATABASE default AS
restore_check` land on fresh Keeper paths: RESTORE assigns new UUIDs, and
the path is a function of the UUID, not of the database name. Verified by
the collision query in the restore check (0 rows). A path template built
from `{database}`/`{table}` would not have this property; test before
changing it.

### `s3_plain` for `BACKUP TO Disk`, credentials in the disk

`type=s3` scatters a backup into randomly named objects with local-only
metadata; `type=s3_plain` writes every file at its path. The backup disk
lives on node 0 only, with `<backups><allowed_disk>` restricting statements
to it, so no `BACKUP ... TO S3(url, key, secret)` form is ever used and the
thirty-day `query_log` holds no credential. Verified by the set-equality
check (bucket listing = `system.backups` `num_files`/`total_size`) and by
the host-side grep of the flushed query log.

### Vultr sizing and image

`vc2-4c-8gb` per node is one step above the documented 2 CPU / 8 GiB
minimum. The Ubuntu 24.04 image (`os_id` 2284) ships `ufw` enabled with
`22/tcp` alone and its system timezone at UTC (asserted by the common play,
not assumed); `SELECT timezone()` answered `UTC` without configuration.

### Retest conditions

- **Any ClickHouse bump**: re-verify that `<ttl>` on `query_log`,
  `part_log` and `error_log` still merges beside the packaged
  `partition_by` and that an `<engine>` override is still refused; that
  `s3_plain` is still the path-preserving disk type and `BACKUP ... TO
  Disk` still writes `.backup` last; that `RESTORE ... AS <db>` still
  assigns fresh UUIDs (run the `system.replicas` collision query); that the
  XML `<grants>` list — including `GRANT READ ON REMOTE` and `GRANT CLUSTER
  ON *.*` — still lets the application's `ON CLUSTER` migrations run; that
  `system.query_log` is still created lazily (the `SYSTEM FLUSH LOGS`
  gate); and that the embedded `keeper_server` block is still accepted in
  the server config.
- **Any change to the packaged `config.xml`** (a new default `partition_by`
  or `engine` on a system table) changes which override form is legal;
  rerun the offline XML parse and a real start.
- **Any Ubuntu image bump**: re-check that `ufw` still ships enabled with
  22 only (the per-peer allows assume it), and the system timezone.
- **Any Vultr firewall change**: re-verify that the group still filters the
  private interface (ICMP through, TCP dropped) — the denial gate on Keeper
  9181 from the app host is the canary.
- **rclone newer than ~1.64**: the `no_check_bucket` / `no_head` / no-`rcat`
  rules the set scripts inherit from the `neon-single-node` build may
  lapse; retest before dropping them.
