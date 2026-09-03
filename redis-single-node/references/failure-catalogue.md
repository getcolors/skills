# Failure catalogue

Symptom-indexed, verbatim where the text was verbatim. Entries marked
*(this build)* were hit or deliberately reproduced on `redis-vultr` at the
pins in `pins.md`; entries marked with another build name were paid for
there and are carried here because a single-node Redis deployment meets
them too.

## A restored `dump.rdb` loads zero keys *(this build, reproduced)*

```
DBSIZE
(integer) 0
```
with, in the container log:
```
* Creating AOF base file appendonly.aof.1.base.rdb on server start
* Creating AOF incr file appendonly.aof.1.incr.aof on server start
* Ready to accept connections tcp
```

The instance was started with `appendonly yes` and there was no
`appendonlydir/` beside `dump.rdb`. Redis 7 with AOF enabled loads **only**
the AOF manifest; finding none, it creates an empty base and an empty
increment file and never reads the RDB. The directory afterwards holds a
fresh `appendonlydir/` next to the untouched `dump.rdb`, and the server
answers `PONG` as if all were well. Reproduced deliberately with the
just-restored 288-byte set: `--appendonly no` → 2 keys; `--appendonly yes`
→ 0 keys.

Fix for a restore *check*: run the scratch with `--appendonly no --save ""
--dir /data --dbfilename dump.rdb`. For a real recovery onto a live host:
stop Redis, place `dump.rdb`, remove `appendonlydir/`, start with AOF on so
Redis rewrites the AOF base from the loaded RDB — a procedure that follows
from the rule above but was **not** executed on this build.

## `NOAUTH Authentication required.` with exit 0 *(this build)*

```
$ docker compose exec -T redis redis-cli --no-auth-warning PING
NOAUTH Authentication required.
$ echo $?
0
```
```
$ docker compose exec -T -e REDISCLI_AUTH=not-the-password redis redis-cli --no-auth-warning PING
AUTH failed: WRONGPASS invalid username-password pair or user is disabled.
NOAUTH Authentication required.
$ echo $?
0
```

Error replies are text on stdout and redis-cli exits 0 in non-interactive
mode. A converge gate that keys on the exit code reads both refusals as
success and an accepted anonymous `PING` as success too. Every gate must
capture the reply and grep it (`PONG`, `NOAUTH`, `WRONGPASS`), and a
negative gate must additionally fail on a `PONG` in the reply.

## A health check reading the reply with `head -c` prints nothing *(langfuse-multi-node)*

```
FAIL  A3 unauthenticated Redis PING answered 'nothing'
```

`head -c 64` on the 33-byte `NOAUTH Authentication required.\r\n` reply
blocks waiting for the remaining bytes until the timeout kills it, and the
buffered bytes are lost with it. Read a line (`head -1`, `read -t`) or
capture the whole reply; never a byte count larger than the reply.

## `ufw status` admits only 22 but the published port answers *(langfuse-multi-node; bindings verified here)*

Docker's published ports bypass ufw through the DOCKER chain, so ufw's
rule list is not the exposure boundary for a container port. What bounds
exposure is the **bind list in the Compose `ports:`** and the provider
firewall. On this build: `ss -ltnH "sport = :6379"` listed exactly
```
LISTEN 0      4096   10.60.0.3:6379 0.0.0.0:*
LISTEN 0      4096   127.0.0.1:6379 0.0.0.0:*
```
and a bounded connect from the internet to `<public-ip>:6379`
(`timeout 5 bash -c 'exec 3<>/dev/tcp/<ip>/6379'`) failed while the tunnel
round-trip succeeded. Publish on `127.0.0.1:` and the private address, and
gate on the kernel's listener list — never on `ufw status`.

## `UNREACHABLE` on a host booted minutes ago *(this build)*

```
[ERROR]: Task failed: Failed to connect to the host via ssh: kex_exchange_identification: read: Connection reset by peer
Connection reset by 78.141.212.44 port 22
fatal: [redis-vultr]: UNREACHABLE! => {"changed": false, "msg": "…", "unreachable": true}
PLAY RECAP: redis-vultr : ok=0 changed=0 unreachable=1 failed=0
```
and on the host:
```
sshd[10188]: Received signal 15; terminating.
sshd[10685]: Server listening on 0.0.0.0 port 22.
```
with `/var/log/apt/history.log` showing `Commandline: /usr/bin/unattended-upgrade`
entries for libpam-* and libssl3t64 at that minute, and
`unattended-upgrades.log` ending `All upgrades installed` two minutes later.

Ubuntu 24.04's `apt-daily-upgrade.timer` ran six minutes after the host's
first boot and the libpam/libssl upgrades restarted sshd; the play's one
connection attempt landed in that second. The host was reachable a minute
later with nothing wrong. Fix: `[ssh_connection] retries = 3` in
`ansible.cfg` and `wait_for_connection` ahead of every play, not only the
converge. (A `/etc/ssh/ssh_config line 53: Unsupported option
"gssapiauthentication"` line printed alongside is workstation noise from a
nix-built ssh reading the distro config; it appears on every successful
connection too.)

## `docker inspect` RestartCount never goes down *(langfuse-multi-node)*

`RestartCount` is cumulative for the life of a container. A monitor
threshold on the raw count flags a container that once crash-looped and
has been healthy for hours — and keeps flagging it exactly because the
container was never recreated, which is the idempotence working. Pair the
count with `.State.StartedAt`: restarting *now* means a recent start.

## rclone → R2: `AccessDenied` on allowed writes, `501` from `rcat` *(neon-single-node)*

```
ERROR : … Failed to copy: AccessDenied: Access Denied
	status code: 403
```
```
NotImplemented: Not Implemented
	status code: 501
```

Ubuntu 24.04's rclone 1.60.1 precedes the first upload with a bucket
check/create that a bucket-scoped R2 token denies, and streams
unknown-size uploads (`rcat`) in a way R2 rejects. Set
`RCLONE_CONFIG_<REMOTE>_NO_CHECK_BUCKET=true`,
`RCLONE_CONFIG_<REMOTE>_NO_HEAD=true`, and always `copyto` a known-size
file. This build ran with all three from the start and did not re-test
without them.

## Ansible: `failed at splitting arguments` on a fine-looking shell task *(langfuse-multi-node, neon-single-node)*

```
Error loading tasks: failed at splitting arguments, either an unbalanced jinja2 block or quotes
```

A `shell:` block whose comment carries an odd number of apostrophes.
Ansible counts quotes across the whole block, comments included, before
the shell ever sees it. Keep quoting-heavy shell in installed scripts and
run `ansible-playbook --syntax-check` on the rendered tree offline; the
companion package's `bb syntax` does both in a second.

## A keygen deployment refuses its own provider SSH key *(langfuse-multi-node; preflight re-proven here)*

```
vultr already has an SSH key named <profile> (id …) that is not in this
deployment's state and matches ~/.ssh/<profile>.pub: a previous delete left
it behind. Verify no host for <profile> survives, delete that key at the
provider, and retry.
```

Not a leftover key: the deployment's own state held it, but the package's
`state-fn` had normalized the tofu output to kebab-case and ONCE's create
matrix reads `:ssh_key_id` **with the underscore**. Return the keywordized
params untouched; add derived keys beside the originals. The redis
package's second converge passed this preflight with the key in state.
