# Acceptance doctrine

The live build passed its service/recovery gates and subsequently authorized
compute cleanup on 2026-09-18. Shared storage was preserved. Raw evidence
is private; [evidence.md](evidence.md) maps every group to its source. The
package owns executable gates; this document owns their interpretation.

| Gate | Required observation | Session result |
|---|---|---|
| S1 write/read | Authenticated SET returns OK; GET returns its unique smoke value | Both creates passed |
| S2 identity/configuration | `server_name:valkey`, `valkey_version:9.1.2`, noeviction, AOF yes/everysec, aof_enabled 1 | Both complete audits confirm |
| S3 auth negatives | NOAUTH anonymously; WRONGPASS/NOAUTH with wrong password; neither negative accepts PONG | Both audits show refusals despite rc=0 |
| S4 host exposure | Kernel listener exactly loopback on configured port | Both audits show `127.0.0.1:6379` |
| S5 persistence | Restart existing container and read smoke key; AOF write status ok | Both creates passed; audit reports ok |
| A0 outside refusal | Bounded workstation public-port connect is refused or times out; other probe errors fail verification | Create acceptance passed twice; tool-error handling was separately tested offline |
| A1 tunnel control | Generated SSH alias forwards to loopback; authenticated SET/GET succeeds | Create acceptance passed twice |
| A2/A3 tunnel negatives | Anonymous and wrong-password refusals through same tunnel | Create acceptance passed twice |
| R1 set protocol | Stream RDB; pinned checker; upload/readback RDB size/hash and manifest hash; nonempty completion marker last | Rehearsal passed; audit shows completed 288-byte, two-key set |
| R2 scratch restoration | Pinned image, no published port, isolated network, AOF off, loading 0, keys and deployment smoke key present | Rehearsal passed; deliberate comparison loaded two keys |
| R3 recovery marker | Identifies the rehearsed set and reads back under the application prefix | `valkey-vultr set=20260918T154756Z at=20260918T154827Z` |
| M health | Healthy monitor, no reported problems, backup/monitor timers active | Both complete audits and describes passed |
| I convergence identity | Same instance/key/firewall/container creation identity and password | Explicit identity and password comparisons passed |
| D0 deletion guard | Refuse protected delete before destructive work | Exit 2, expected message |
| D1 authorized delete | One-run override; application cleanup, SSH-config removal, then compute destruction | Exit 0; 16:33:58–16:34:59 UTC |
| D2 absence | Owned instance/firewall/provider SSH key return 404; managed local key/pub/profile known-hosts/config absent | Independent audits passed before and after repeat-delete |
| D3 repeat-delete | Already destroyed deployment exits successfully | Exit 0; 16:37:33–16:37:36 UTC |
| D4 storage preservation | Both shared buckets readable; non-Valkey metadata preserved; profile backups retained | Before/after/repeat summaries match; 20 profile backup objects remain |
| D5 retired state | Retired coordination, idle lock, destroyed shared/node phases, removed key phase, empty resource states | Corrected state audit confirms all fields |
| E audit completeness | Every required section plus explicit terminal sentinel | Final audits have LIVE_AUDIT_COMPLETE; final scratch probe has AOF_PROBE_COMPLETE |

The preserved backup-object count does not establish byte-for-byte equality
of every profile backup object; cleanup did not rehash their contents. Three
profile state objects remain as retired coordination and empty resource states.

The package monitor checks PING, AOF status, resource pressure, recent repeated
restarts, and the newest **completed** backup's age. The live result proves
healthy operation; it does not establish that every degraded branch was
fault-injected on this VM.

## Reference adaptations

Redis identity/binary names became Valkey identity/native binary names. The
Redis AOF-empty-restore finding was treated as a hypothesis until the two
scratch comparisons reproduced it. R2 flags remained in place; necessity was
not re-proven. AWS managed bucket ownership, encryption and destruction gates
are inapplicable to this existing-bucket Vultr scope.

The recovery marker is under `<profile>/valkey/.colors-recovery-verified`,
inside this application's prefix. Retention preserves incomplete sets for
manual investigation, with failed reads blocking pruning. Those failure
paths were tested offline with mocked rclone, not by destructive operations
on shared storage.

## Passing does not prove

- AOF crash durability or a measured one-second data-loss ceiling.
- Production-host replacement recovery, recovery from losing the live volume,
  or loading the RDB into the production service.
- Destruction of shared/managed buckets or live fault injection into destructive
  backup retention. Compute deletion intentionally preserved stored backups.
- Other compute providers, managed storage, cluster replication or failover.
- Necessity of `no_head` or `no_check_bucket` under another rclone version.
- Global immutability of a shared account or state bucket. Concurrent unrelated
  activity changed non-Valkey state; only non-Valkey backup metadata stayed
  unchanged in the measured interval.
- Success of checks omitted by an audit that exited zero without its sentinel.
