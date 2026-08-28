# The netstack client contract, as observed

What the 0.77.1 NetBird client actually does in netstack/SOCKS5 mode,
verified in-pod on the live VKE deployment 2026-08-28. The upstream FaaS
document describes the mode's intent; this records the behaviour the
build had to be shaped around. The control-plane REST contract is owned by
`agent-network-single-node`'s `references/api.md` and is unchanged on
Kubernetes.

## Configuration surface

| Setting | Works | Notes |
|---|---|---|
| `NB_USE_NETSTACK_MODE=true` | yes | userspace WireGuard; no TUN, no capabilities, non-root, read-only rootfs all hold |
| `NB_SOCKS5_LISTENER_ADDRESS=0.0.0.0` | yes | required for cross-pod use; the listener is unauthenticated — NetworkPolicy is the only gate on who reaches it |
| `NB_SOCKS5_LISTENER_PORT=1080` | yes | |
| `NB_DAEMON_ADDR=unix:///var/lib/netbird/daemon.sock` | yes | daemon AND CLI honour it |
| `NB_LOG_FILE=console` | yes | |
| `--daemon-addr`, `--log-file` on `service run` | **no — silently ignored** | they parse (present in `--help`) and do nothing; verified with the flag before and after the subcommand |
| `--setup-key-file`, `--management-url` on `up` | yes | the parent build's enrollment path, unchanged |
| `USER`, `HOME` env | required | `netbird up` fails `get current user: user: Current requires cgo or $USER set in environment` under a passwd-less uid |

Profile config defaults to `/var/lib/netbird/default.json` — put the state
volume there and the default is already right.

## Resolution and reachability

- **The SOCKS5 listener serves hostname CONNECTs**, resolving through the
  client pod's OS resolver — `/etc/hosts` (`hostAliases`) included. The
  FaaS doc's "The DNS feature is not supported. You can reach the peers by
  IP address only" is about the NetBird DNS feature (management-pushed
  custom zones), which indeed never materializes in netstack mode — it is
  not about the listener's own resolution. Live proof: with the endpoint
  hostname aliased to the proxy's overlay address in the client pod, a
  `--socks5-hostname` CONNECT to the endpoint completes TLS through the
  tunnel (the proxy answered the bare probe with its pre-identity 403);
  with no alias and no DNS egress, hostname CONNECTs to public names fail.
- **Only the overlay is dialable.** CONNECTs through the listener to
  public IPs, the metadata address, the API server, ClusterIPs, and
  overlay-adjacent guesses all fail; the registered proxy peer's address
  answers. This is netstack routing behaving as designed — but it is a
  property the acceptance suite probes on every converge rather than
  assumes, because NetworkPolicy cannot constrain what a CONNECT names.
- The management-pushed **network map is the client's one source of peer
  addresses** (`netbird status --json`, `.peers.details[]`): the embedded
  proxy peer appears there and nowhere in the management REST API. Peer
  entries carry a synthesized fqdn `proxy-<xid>-<ip-suffix>` whose xid is
  k-sortable — the basis of newest-registration selection when stale
  entries linger (see the failure catalogue).

## Identity and state

- Enrollment truth is the daemon's status (`NeedsLogin` = no identity),
  never the existence of `default.json` — the daemon writes that file at
  first start, before any login, with the default `api.netbird.io`
  management URL in it.
- An enrolled identity on the state volume reconnects with a plain
  `netbird up`; the one-off key is needed exactly once, which is what
  makes single-use-and-revoke possible. State whose management URL is not
  this deployment's is poison from a failed first enrollment: wipe it and
  enroll fresh.
- A surviving peer record over a lost state volume blocks re-enrollment
  (the mint is guarded by group occupancy): remove the stale peer by id
  first.
