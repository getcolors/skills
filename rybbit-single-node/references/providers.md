# The provider layer

Everything above this layer — the playbook, the compose stack, the Caddyfile,
the backup unit, the acceptance checks — contains no provider concepts. Porting
to a new cloud means writing one `main.tf` that satisfies a small contract.

## The contract

A provider implementation must:

1. **Create one machine** running a current Ubuntu LTS, with your SSH key
   installed for `root`.
2. **Allow inbound** TCP 22, 80 and 443, **plus UDP 443**, and nothing else. The
   datastores are already confined to the private compose network, so the
   firewall is a second layer rather than the only one.

   UDP 443 is HTTP/3, which Caddy advertises via `alt-svc` whether or not the
   port is reachable. Omit it and browsers attempt QUIC, get nothing, and fall
   back to TCP — so it presents as intermittent slowness rather than as a
   failure, and it is easy to carry for months. Upstream's own compose publishes
   `443:443/udp` for this reason.
3. **Allow outbound** freely — image pulls, ACME, and the backup upload all need
   it.
4. **Emit an IPv4 address** that Ansible can reach over SSH as `root`.

That is the whole interface. Both bundled implementations export the same shape:

```hcl
output "params" {
  value = { ip = <address>, user = "root", sudoer = "root", name = "<deployment>" }
}
```

Keep that shape and the rest of the stack does not know which cloud it is on.

**Guard the machine against accidental destruction.** Both implementations carry
`lifecycle { prevent_destroy = true }`. Lifting it should be a deliberate,
single-run decision, not an edit that stays in the file.

## SSH: one disposable agent, one disposable key

Do not put your long-lived personal key on a machine you intend to delete. Use
a per-deployment key that is created, used, and destroyed with the stack:
generate a fresh keypair, load it into its own dedicated agent, and register
the public key as a tofu resource (`vultr_ssh_key` / `digitalocean_ssh_key`)
so `tofu destroy` removes it from the account. Uploading a key by hand instead
leaves an orphan whose id survives only in someone's notes. Inside the Colors
ecosystem the companion package owns the profile-named machine keypair per the
workspace SSH Keypair Standard.

**One agent, because the two tools disagree about where identity comes from.**
OpenTofu's `remote-exec` provisioner uses a Go SSH client that ignores
`~/.ssh/config` and reads `SSH_AUTH_SOCK`. Ansible uses OpenSSH, which reads the
config. An agent is the one channel both accept, so they cannot drift apart.

**The host-config trap.** A `~/.ssh/config` containing

```
Host *
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  IdentityAgent none
```

stops OpenSSH consulting any agent — `IdentityAgent none` disables it, and
`IdentitiesOnly yes` would restrict it to keys matching a configured
`IdentityFile` even if it were enabled. Command-line `-o` beats the config, so
`ANSIBLE_SSH_ARGS` must set **both**:

```
-o IdentityAgent=<sock> -o IdentitiesOnly=no
```

Setting only one fails to authenticate. And because `ANSIBLE_SSH_ARGS`
*replaces* Ansible's default rather than extending it, the value must repeat
the `ControlMaster`/`ControlPersist` options — drop them and every task pays
for a fresh handshake.

Verify the override actually took, rather than assuming:

```sh
ssh -G $ANSIBLE_SSH_ARGS <host> | grep -E 'identityagent|identitiesonly'
```

**Two failure modes worth knowing.** A Unix socket path is capped near 108
bytes and `ssh-agent -a` fails above it, so a deeply nested deployment
directory needs the socket elsewhere — `$XDG_RUNTIME_DIR` is the reliable
fallback. And a stale socket from a dead agent makes
every later connection *block* rather than fail, which is worse than having no
agent; remove any stale socket before starting a fresh one.

## DigitalOcean — verified

The companion's `tools/infrastructure/digitalocean/main.tf` in
`getcolors/rybbit`. This is the implementation the whole skill was verified
against.

| Concern | How |
|---|---|
| Machine | `digitalocean_droplet` — `image`, `region`, `size`, `ssh_keys` |
| Network | `vpc_uuid` from a `digitalocean_vpc` data source looking up `default-<region>` |
| Firewall | one `digitalocean_firewall` with inline `inbound_rule` / `outbound_rule` blocks taking **CIDR lists** |
| Address | `digitalocean_droplet.<name>.ipv4_address` |
| Rename | in place — the droplet and its firewall keep their address and volumes |

The VPC is discovered at plan time rather than configured, so no UUID is
persisted in desired state and the config stays portable between accounts.

**Resizing.** A droplet may only move to a plan whose disk is at least its
current disk, so a downsize is refused with
`422 This size is not available because it has a smaller disk`. `resize_disk =
false` does **not** work around it — that was verified against the live API, not
reasoned about. Moving down a plan is a delete, a recreate and a restore. Size
conservatively at the start.

## Vultr — verified live

The companion's `tools/infrastructure/vultr/main.tf` in `getcolors/rybbit`.
Originally written from the Vultr provider's own documentation and
schema-checked only; since 2026-08-24 it has been converged for real — the
`rybbit-vultr` deployment built from it serves production analytics for every
getcolors page. Two mechanics differ from the DigitalOcean file and both
destroy data if guessed wrong: `hostname` and `ssh_key_ids` are ForceNew on
Vultr (a hostname change is an OS reinstall, a key-set change recreates the
instance), so the playbook owns the hostname and keys last the life of the
deployment. The companion also generates its firewall rules into
`firewall.tf.json` (one resource per protocol, family, and port — including
the UDP 443 HTTP/3 hole) rather than looping in HCL.

| Concern | How |
|---|---|
| Machine | `vultr_instance` — required `region` and `plan`; `os_id` for the image |
| OS | the companion pins `os_id` from desired state; matching by name via `data "vultr_os"` with a `filter` is the portable alternative to hardcoding a numeric id |
| Firewall | `vultr_firewall_group` plus **one `vultr_firewall_rule` per (protocol, ip_type, port)** |
| Address | `vultr_instance.<name>.main_ip` — *not* `ipv4_address` |
| Console name | `label` |

Four differences that matter, all of which change how you write the file:

**Firewall rules are separate resources, and subnets are split.** DigitalOcean
takes a list of CIDRs per rule. Vultr takes `subnet` and `subnet_size` as
distinct fields, one rule at a time, per IP version. `0.0.0.0/0` becomes
`subnet = "0.0.0.0"` with `subnet_size = 0`. Opening three ports to v4 and v6 is
six resources.

**Vultr firewalls are default-deny inbound and do not model outbound.** There is
no outbound block to write — where the DigitalOcean config needs three explicit
outbound rules to avoid locking the machine out of the internet, this one needs
none.

**`vultr_firewall_rule` accepts `source = "cloudflare"`.** Vultr maintains the
edge ranges for you. If you serve the origin through Cloudflare — which the
bundled DNS config does by default — this is a stronger posture than
`0.0.0.0/0` on 80 and 443, and it costs one attribute. It has the same
consequence as any origin lock: direct access to the origin stops working, so
keep SSH open to yourself and remember it when debugging.

**Do not set `hostname` on the resource.** The provider documents a `hostname`
change as `force new`, because the API implements it as an OS reinstall. The
playbook sets the hostname on the machine anyway, so leave the attribute unset
and let the converge own it. This is the sharpest difference from DigitalOcean,
where renaming is a harmless in-place operation — the same intent, and on Vultr
it destroys the host.

**The instance has a root password, and it lands in state.** `vultr_instance`
exports `default_password` — the provider documents it in the attributes
reference — so it is written into the state file whether or not you reference
it. DigitalOcean has no equivalent. Two consequences: treat the state file as a
credential (it already holds one), and check on a converged machine whether SSH
password authentication is actually enabled, because attaching an SSH key does
not by itself imply it was disabled. The second half of that is **unverified** —
it is the thing to check on your first converge, and to write down here
afterwards.

Unknown until someone converges it: whether Vultr permits a plan downgrade, and
what its equivalent of the smaller-disk refusal is. Find out before you size up,
not after.

## DNS is a separate choice

The companion's `tools/dns/` is independent of the compute provider — it takes
an address and publishes a record, and works unchanged behind either
implementation above. Using a provider's own DNS instead is fine, with one
consequence:

**The Caddyfile's `trusted_proxies` must describe whatever is actually in front
of the origin.** It currently lists Cloudflare's ranges. Serve the origin
directly and the block is inert but misleading. Move to a different CDN and it
is wrong — Caddy will attribute every request to the edge, and the access log
becomes useless for the only question it is read for, without erroring.

The proxied record is the default deliberately: an unproxied record publishes
the machine's address and leaves the firewall as the only thing in front of it.
The trade is that SSH to the hostname stops resolving to the machine. Converges
are unaffected — Ansible uses the address the provider emitted — but ad-hoc SSH
needs the origin address.

## Adding a third provider

1. Copy the DigitalOcean file; it is the shorter of the two and it is verified.
2. Replace the machine and firewall resources, keeping ports 22, 80 and 443 and
   nothing else inbound.
3. Export `params` in the shape above, with the provider's own address
   attribute. Getting this name wrong is the single most likely error — it is
   `ipv4_address` on DigitalOcean and `main_ip` on Vultr.
4. Check whether the machine has a hostname attribute and whether changing it is
   destructive. If in doubt, do not set it: the playbook does.
5. Check the resize and rename policies before you choose a size.
6. Converge, then run the acceptance checks in `acceptance.md`. Nothing above the seam should
   need to change; if something does, that is the interesting finding and it
   belongs in this file.
