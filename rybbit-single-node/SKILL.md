---
name: rybbit-single-node
description: Everything needed to run a self-hosted single-node Rybbit analytics stack you can actually trust - the six-container topology, the provider-independent seam that lets one converge run on DigitalOcean or Vultr or anything else with an SSH port, ClickHouse backups that restore instead of merely existing, and verification that catches a stack which looks healthy and stores nothing. Use this whenever the user mentions self-hosting, deploying, provisioning, sizing, migrating, backing up, restoring, or debugging Rybbit, or is working on a Rybbit docker-compose, Caddy reverse proxy in front of Rybbit, ClickHouse or PostgreSQL backup, or event-ingestion problem - even if they do not say "single-node" and even if they are only changing one setting. Also use it when someone reports that Rybbit returns success but records no events, that a Caddyfile or config edit had no effect, that a container is serving old configuration, that signup cannot be disabled or re-enabled, that analytics show the CDN's address instead of the visitor's, or that they want to move a Rybbit deployment to a different cloud provider.
---

# Single-node Rybbit

Rybbit self-hosts easily. Upstream ships a compose file and an install script,
and they work — which is the honest starting point, and the reason this skill is
not shaped like a rescue mission.

The gap this covers is the one after that: **the distance between a stack that
runs and a stack you can trust.** That distance was measured on a live
deployment serving real analytics, over about 35 commits. Nearly all of it is
not Rybbit-specific — it is what a single-node analytics stack costs once you
need it to survive a config change, prove its backups, and tell you the truth
about whether an event was stored.

Everything here was verified against a running deployment unless it says
otherwise. Where something was reasoned about rather than observed, it says so.

## The seam, and why this ports to any provider

The stack has exactly one provider-coupled layer, and it is small:

```
provider layer  (OpenTofu)   make a machine, open 22/80/443 + udp 443,
                             emit an address
      ↓ contract: an IPv4 address reachable over SSH as root
converge layer  (Ansible)    everything else — needs an IP and nothing more
      ↓
compose stack   (6 containers)
      ↓
verification    (acceptance) needs an HTTPS hostname and SSH
```

The Ansible layer, the compose stack, the Caddyfile, the backup unit and the
acceptance checks contain **no provider concepts at all**. Moving from
DigitalOcean to Vultr, Hetzner or bare metal replaces one `main.tf` and changes
nothing else. `assets/tofu/` ships two implementations of that one file, and
`references/providers.md` gives the contract so you can write a third.

Three things do cross the seam, and getting them wrong is quiet rather than
loud:

- **`trusted_proxies` must name whatever is actually in front of Caddy.** The
  bundled Caddyfile trusts Cloudflare's ranges because the verified deployment
  is proxied through Cloudflare. Serve the origin directly and the block is
  inert but misleading; put a different CDN in front and every access log
  attributes every visit to the edge. See the entry in the failure catalogue —
  this one produced a log that existed and was useless for the single question
  it gets read for.
- **Hostname handling is a provider policy.** DigitalOcean renames a droplet in
  place. Vultr treats a `hostname` change as `force new`, which reinstalls the
  OS — so on Vultr you let Ansible own the hostname and never set it in the
  resource. Same intent, opposite mechanics, and one of them destroys the host.
- **Resizing rules are the provider's, not Rybbit's.** DigitalOcean refuses any
  move to a plan with a smaller disk, `resize_disk = false` included — verified
  against the live API, not inferred — so a downsize is a delete and a restore.
  Check the rule before you size up, because sizing up is the decision that
  makes it expensive.

## The six containers

`assets/ansible/compose.yml` is the working file with the reasoning inline.

| Service | Image | Why |
|---|---|---|
| `caddy` | `caddy` | TLS termination; splits `/api/*` from the app |
| `postgres` | `postgres:17-alpine` | Auth and metadata — users, organizations, sites |
| `clickhouse` | `clickhouse/clickhouse-server` | The event store |
| `redis` | `redis:8-alpine` | Session state and tracking queues |
| `backend` | `ghcr.io/rybbit-io/rybbit-backend` | Fastify API; ingestion and query |
| `client` | `ghcr.io/rybbit-io/rybbit-client` | Next.js UI |

Only Caddy publishes ports — 80 and 443, **plus UDP 443**. Postgres, ClickHouse,
Redis and both application ports stay on the private compose network, so the
firewall is not the only thing keeping them off the internet.

Three configuration facts that are not discoverable from a healthy-looking
stack:

**ClickHouse needs its JSON type enabled, under the right name for the
version.** Rybbit's schema uses it, it is off by default, and it is a `users.d`
profile setting rather than a `config.d` server one. The name has already
changed once — `allow_experimental_json_type` on 24.8, `enable_json_type` on
25.x and later — and **a name the server does not recognise is ignored rather
than rejected**, so the profile looks installed and the schema still will not
build. Ask the server: `SELECT name, value FROM system.settings WHERE name LIKE
'%json_type%'`.

**UDP 443 carries HTTP/3.** Caddy advertises it via `alt-svc` whether or not the
port is reachable, so omitting it makes browsers try QUIC, fail, and fall back
to TCP — intermittent slowness, never an error. Publish it in compose *and* open
it in the firewall.

**Redis must not evict.** It carries queue state, not cache. Use `noeviction`
with `appendonly yes` — an eviction policy silently discards work.

## The three ways a converge lies to you

Ranked by how much time they cost. All three are general: none is about Rybbit.

### A single-file bind mount keeps its inode

`ansible.builtin.copy` replaces a file by rename. A container that bind-mounts
that *file* — not its directory — holds the inode it started with, and
`docker compose up -d` declines to recreate a service whose definition has not
changed. So the host file is correct, the diff is what you wanted, Ansible
reports `changed`, and the container is still serving the old configuration.

Every Caddyfile edit on the verified deployment landed on disk and never reached
Caddy until this was fixed. **Key the recreate on what the container is actually
serving**, not on a change flag:

```yaml
- name: Read the config checksum the container is serving
  ansible.builtin.shell: docker compose exec -T caddy sha256sum /etc/caddy/Caddyfile | awk '{print $1}'
  register: running_config
  changed_when: false
  failed_when: false
- ansible.builtin.stat: {path: /opt/rybbit/Caddyfile, checksum_algorithm: sha256}
  register: desired_config
- name: Recreate the service when its configuration is stale
  ansible.builtin.command: docker compose up -d --force-recreate caddy
  when: (running_config.stdout | default('') | trim) != desired_config.stat.checksum
```

Comparing observed state against desired state also repairs a container that
went stale for some reason you never diagnosed, which a change flag cannot do.

**Do this for every single-file mount, not just the noisy one.** This stack has
two — the Caddyfile and the ClickHouse `users.d` profile — and the quiet one is
more dangerous: a stale JSON-type setting surfaces as a schema that will not
build rather than as a missing header. `assets/ansible/main.yml` loops over both.
A *directory* mount is immune, so mounting the parent is the alternative fix, at
the cost of shadowing whatever the image ships there.

`docker compose restart` does not help, and this is what makes the bug hard: it
re-execs the process inside the same container against the same stale mount. A
config that is re-read at startup is re-read from the old inode, so "I restarted
it and nothing changed" reads as evidence that you are editing the wrong file
when it is entirely consistent with editing the right one.

### `env_file` is read when a container is created

Not while it runs. Generated secrets have to survive a converge, so `stack.env`
is written once with `creates:` — and that froze **every** value in it,
including the one deciding whether strangers can register an account. Flipping
the signup setting rewrote nothing and restarted nothing, silently.

Keep any value that is desired state in step with `lineinfile`, and recreate the
services that read it when it moves. Generated secrets stay write-once; policy
does not.

### An unchecked result reports success

The acceptance step captured the `/api/track` response, put it in the result map
and never branched on it, so it announced success for whatever the endpoint
answered — including a `400`. The same shape appeared in the PostHog sibling.
Compute a verdict, then make the success branch depend on it. Verdict logic is
pure and worth unit-testing; the I/O around it is not testable without a host,
and the decision rules are exactly where the mistakes hide.

## Converge order

`assets/ansible/main.yml` is the whole playbook. Rybbit's own migrations run at
backend startup and need no orchestration, so the ordering is far less delicate
than PostHog's. What matters:

1. **`update_cache: true` with no `cache_valid_time`.** A fresh cloud image
   ships apt lists old enough to name superseded versions; every create failed on
   its first task with a 404 until this was unconditional.
2. **Set the hostname from desired state.** The machine otherwise keeps whatever
   the image was built with.
3. **Write `stack.env` once**, then reconcile the policy lines as above.
4. **Install config, then bring the stack up**, then repair Caddy if it is
   serving a stale checksum, then wait on the backend's health endpoint *from
   inside the container* — that separates "the app is not up" from "the proxy or
   DNS is wrong", which look identical from outside.
5. **Enable the backup timer.** A backup path that has never run is not a backup.

## Signup has no first-run bootstrap

Rybbit will not create a first account when registration is disabled, and there
is no bootstrap path around it. So the sequence is forced, and it is a sequence
rather than a setting:

1. Converge with signup **enabled**.
2. Register the owner account immediately.
3. Set signup **disabled** and converge again.

Between steps 1 and 3 anyone who finds the hostname can register. Do not leave
it there — on the verified deployment that window was open on an instance
holding production analytics until it was closed deliberately. And because of
the `env_file` trap above, closing it only works if the playbook reconciles that
line and recreates the services; verify against the live `/api/config` rather
than against the file on disk.

## SSH: disposable agent, disposable key

Never put your long-lived personal key on a machine you plan to delete.
`scripts/ephemeral-ssh.sh` creates a per-deployment key and its own agent, and
both tofu configs accept `ssh_public_key` so the key is registered as a resource
and removed by `tofu destroy` rather than left orphaned in the account.

```sh
eval "$(scripts/ephemeral-ssh.sh start)"
tofu apply -var "ssh_public_key=$(scripts/ephemeral-ssh.sh pubkey)"
eval "$(scripts/ephemeral-ssh.sh stop)"
```

One agent rather than naming the key file everywhere, because OpenTofu's
`remote-exec` uses a Go SSH client that ignores `~/.ssh/config` and reads
`SSH_AUTH_SOCK`, while Ansible uses OpenSSH, which reads the config. The agent
is the only channel both accept.

If `~/.ssh/config` disables agents — `IdentityAgent none` with `IdentitiesOnly
yes` is a common hardening — then `ANSIBLE_SSH_ARGS` must override **both**
(`-o IdentityAgent=<sock> -o IdentitiesOnly=no`); setting one alone silently
fails to authenticate. The script emits the correct value. See
`references/providers.md` for the details and the `ssh -G` check that proves the
override took.

## Credentials

Generated on the host and never committed: Postgres, ClickHouse and Redis
passwords, and the auth secret. Supplied from the environment: the compute
provider token, the DNS provider token, and the object-storage keys the backup
uses. Keep the backup credentials in a root-only file outside both generated
output and version control — the backup unit reads them through
`EnvironmentFile`, so they never appear in a unit file or a process listing.

## Verify a converge — the checks that pass anyway

Read `references/acceptance.md` before writing any check. The short version:
**every claim the check reports must be one it actually checked.** A `2xx` from
`/api/track`, a healthy container, and a successful `systemctl start` of the
backup unit are all compatible with a deployment that stores nothing and has no
recoverable data.

`scripts/acceptance.sh` implements the checks that survived: TLS without `-k`, a
synthetic event read back out of ClickHouse into a throwaway site, and a backup
confirmed by a fresh object in the bucket.

## Backups that are actually backups

Four requirements, each of which was learned by having it wrong:

- **Use ClickHouse's own `BACKUP` statement**, not a tar of the data directory.
  A hot tar races running merges — `file changed as we read it` — and produces an
  archive that cannot be restored. The `File()` destination must sit under the
  server's `backups.allowed_path`; put it on the bind mount so the host can
  reach it, and make sure the directory is owned by the `clickhouse` user.
- **No fallback.** An unrestorable archive is worse than a failed unit, because
  it looks like a backup until the day you need it.
- **Prove the dump restores** before uploading: load it into a scratch database
  and require the schema back. A truncated dump otherwise sits in the bucket
  looking fine.
- **Apply retention to the bucket, not only the disk.** Pruning locally while
  object storage keeps everything forever is not a retention policy.

## Check configuration before it reaches a host

```sh
python3 scripts/validate_assets.py <your-config-dir>
```

Run it on your **rendered** files, not only the bundled templates. Every check
corresponds to a failure that is silent on the server: a floating image tag that
moves under the deployment, a compose file missing a service the stack cannot
run without, a Caddyfile with no access logging or no `trusted_proxies` behind a
CDN, a ClickHouse profile that never enables the JSON types the schema needs.

It reports every problem rather than the first and exits non-zero if any are
found. `PROBLEM` lines are failures; notes are advisory.

## Reference material

Read as needed rather than up front:

- **`references/failure-catalogue.md`** — 30 failures as *symptom → cause → fix*.
  Go here first when something is broken; your symptom is probably in it
  verbatim.
- **`references/acceptance.md`** — what to verify after a converge, and why the
  obvious checks pass against a broken deployment.
- **`references/providers.md`** — the contract the provider layer must satisfy,
  DigitalOcean and Vultr side by side, and how to add a third.
- **`references/pins.md`** — the verified-good image set with its date, and the
  rules for choosing a new one.

## Assets

Working files, copy and adapt:

```
assets/
├── ansible/
│   ├── main.yml           the converge playbook
│   ├── cleanup.yml        stop the stack before tearing infrastructure down
│   ├── compose.yml        six services, reasoning inline
│   ├── Caddyfile          TLS, /api split, access logging, trusted_proxies
│   ├── backup             pg_dump + ClickHouse BACKUP + restore drill + upload
│   ├── group_vars/all.yml every knob, with defaults that work
│   ├── ansible.cfg
│   └── inventory.example.ini
└── tofu/
    ├── digitalocean/      droplet + firewall          VERIFIED live
    ├── vultr/             instance + firewall group   schema-checked, not converged
    └── cloudflare-dns/    proxied A record            VERIFIED live
```

The Ansible assets are ordinary Ansible: `group_vars/all.yml` holds the
variables and the templates use `{{ }}`. Quote any YAML value that starts with
`{{` — unquoted, it parses as a flow mapping and the file becomes invalid, which
Docker only discovers on the host.

**`assets/tofu/vultr/` has never been converged.** `tofu validate` passes
against the real provider schema, so the resource and attribute names are right;
nothing the API decides at apply time has been tested. It is a strong starting
point that still owes you one `tofu plan`, and the file says so in a banner you
should delete once it has run.
