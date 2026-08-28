# Failure catalogue

Every entry was hit on a real converge of a live VKE Agent Network
deployment (netbird-server/reverse-proxy/client 0.77.1, dashboard v2.91.1,
VKE v1.36.2+1), 2026-08-28, across eighteen create runs — except the two
entries labelled otherwise. **Search for your symptom string first** —
most are verbatim error text. None of these were reachable by unit tests
or golden fixtures; they only appear against the real platform.

## Contents

- [The client in netstack mode](#the-client-in-netstack-mode)
- [The embedded proxy peer and the churning endpoint](#the-embedded-proxy-peer-and-the-churning-endpoint)
- [The combined server on Kubernetes](#the-combined-server-on-kubernetes)
- [TLS, the edge, and the provider surface](#tls-the-edge-and-the-provider-surface)
- [Cluster and manifest mechanics](#cluster-and-manifest-mechanics)
- [Verification that would have lied](#verification-that-would-have-lied)

---

## The client in netstack mode

### The daemon binds /var/run/netbird.sock and logs to /var/log/netbird, whatever the flags say

**Symptom.** In a read-only-rootfs pod:

```
Failed to write to log, can't make directories for new logfile: mkdir /var/log/netbird: read-only file system
Error: listen daemon interface: listen unix /var/run/netbird.sock: bind: read-only file system
```

although the entrypoint passed `--daemon-addr unix:///var/lib/netbird/daemon.sock
--log-file console` — and the CLI's own `status` then dials the same wrong
default socket, also ignoring its flag.

**Cause.** The pinned 0.77.1 client **silently ignores `--daemon-addr` and
`--log-file` on `service run`**. Verified in-pod with the flag before and
after the subcommand, against a `--help` that lists both.

**Fix.** Configure by environment: `NB_DAEMON_ADDR`, `NB_LOG_FILE` (and the
netstack set: `NB_USE_NETSTACK_MODE`, `NB_SOCKS5_LISTENER_ADDRESS`,
`NB_SOCKS5_LISTENER_PORT`) as pod env, so the daemon, the CLI, readiness
probes, and every `kubectl exec` inherit one truth. The profile config path
conveniently defaults to `/var/lib/netbird/default.json` — already on the
state volume.

### `netbird up` fails: "get current user"

**Symptom.**

```
Error: get current user: user: Current requires cgo or $USER set in environment
```

**Cause.** A `restricted` pod runs a uid with no passwd entry; the static
binary cannot resolve the current user without `$USER`.

**Fix.** Set `USER` and `HOME` env on the container (any value with a
writable `HOME`; the state volume works).

### The client dials api.netbird.io forever

**Symptom.** After what looked like a routine restart, the daemon loops:

```
grpc: addrConn.createTransport failed to connect to {Addr: "api.netbird.io:443", …}
Err: … dial tcp: lookup api.netbird.io: i/o timeout
```

with your `--management-url` apparently ignored, in a pod whose
NetworkPolicy (correctly) denies that route.

**Cause.** A **failed first enrollment persisted the default management
URL**. The daemon writes `default.json` at startup ("not trying to connect
when configuration was just created") with `"Host": "api.netbird.io:443"`;
if the first `up` then fails for any reason (here: the `$USER` failure
above), the poison stays on the state volume and every later start resumes
it. A config file's existence is **not** evidence of enrollment.

**Fix.** Two rules in the entrypoint: decide enrollment by the daemon's
status (`NeedsLogin` = no identity), never by file presence; and treat
state whose management URL is not this deployment's as poison — wipe
`default.json` (and profile state) and enroll fresh. An enrolled identity
always carries the right URL.

### Recovery after state loss hangs waiting for a key

**Symptom.** The state volume was lost or wiped; the replacement pod sits
in `NeedsLogin` waiting for a setup key that never arrives, while the
control plane refuses to mint one.

**Cause.** The peer record survived the state it described. A mint guarded
by "no peer enrolled in the group" reads the stale record as an enrolled
agent.

**Fix.** When the pod reports `NeedsLogin` with no key staged and the
group shows an enrolled peer, remove the stale peer by id and re-run the
bootstrap. Confirm `NeedsLogin` twice with a settling delay first — a
healthy pod passes through login states transiently, and this path deletes
a peer record.

## The embedded proxy peer and the churning endpoint

### The reverse proxy is nowhere in /api/peers

**Symptom.** The proxy runs, the endpoint was minted, but `GET /api/peers`
lists only real clients; automation that expected to find the proxy's
overlay address there fails with its own version of
`no proxy peer is registered on the overlay`. There is no proxies listing
to fall back on: `/api/agent-network/proxies` and
`/api/agent-network/proxy-clusters` are both `404 page not found` (probed
live).

**Cause.** Private-mode proxies register as **embedded proxy peers**
(`peer.ProxyMeta.Embedded`, per the source reading recorded in the
single-node skill) — a class the peers API does not list.

**Fix.** Read the overlay address from an **enrolled client's network
map**: `netbird status --json`, `.peers.details[].netbirdIp`. That is the
same data management's synthesized DNS zone serves TUN-mode peers, and it
is the only consumer-visible source. Order the converge accordingly:
enroll the client first, read the map, then render whatever static mapping
netstack mode needs.

### The endpoint dies after a reverse-proxy restart; the map shows two proxies

**Symptom.** After a proxy pod restart, eviction, or node drain, the
keyless path fails; drift checks report the overlay address changed
(observed live: `100.78.28.93 → 100.78.13.102 → 100.78.103.55 →
100.78.176.82` across three bounces). The client's map may list two proxy
peers at once:

```
proxy-da8m2h102g8c73cbis5g-13-102.netbird.selfhosted   100.78.13.102  Connecting
proxy-da8me7902g8c73cbj3l0-103-55.netbird.selfhosted   100.78.103.55  Idle
```

**Cause.** Every proxy restart is a **new registration with a new overlay
address**, and **stale registrations linger** in the network map beside
their replacement — management does not promptly GC dead embedded peers.
TUN-mode peers would receive the updated DNS zone automatically; a
netstack deployment's static hostname→overlay mapping goes stale the
moment the pod bounces.

**Fix.** Two rules. Selection: "exactly one peer" is not a fact the map
offers — the live proxy is the **newest registration**, and the ids in the
synthesized fqdn (`proxy-<xid>-<suffix>`) are k-sortable xids, so the
greatest id wins; validate the pick with a CONNECT through the tunnel
rather than trusting it. Reconciliation: after any gateway restart (and a
node drain, which restarts everything), re-read the map, re-render the
mapping, roll the client — and make acceptance check for drift before
every probe run so a stale mapping fails loudly instead of letting probes
lie.

## The combined server on Kubernetes

### Crashloop: "illegal base64 data at input byte 40"

**Symptom.**

```
FATL management/internals/server/boot.go:95: failed to create field encryptor: decode encryption key: illegal base64 data at input byte 40
```

after migrations ran fine.

**Cause.** The datastore encryption key (and the session cookie key) must
be **strict base64 — padding included**. A generator that strips `=` (an
easy habit, since the relay auth secret tolerates it) produces a 43-char
unpadded value the field encryptor rejects. The single-node build never
saw this because its host-side generator kept padding.

**Fix.** `openssl rand -base64 32` with only newlines stripped for the
datastore and cookie keys; strip padding only where the consumer is a
plain shared string (relay auth). If the bad key ever booted nothing
(crashloop from first start), the datastore is empty: regenerate key +
config and start clean. If a server ever *ran* with a key, that key is
create-once forever — a regenerated one orphans the peer database
silently.

### Crashloop: "could not initialize geolocation service"

**Symptom.**

```
FATL management/internals/server/modules.go:50: could not initialize geolocation service: failed to get database filename: Head "https://pkgs.netbird.io/geolocation-dbs/GeoLite2-City/download?suffix=tar.gz": dial tcp: lookup pkgs.netbird.io: i/o timeout
```

**Cause.** The combined server **refuses to boot without its GeoLite
database**, fetched from `pkgs.netbird.io` on first start. In a
default-deny namespace the server has neither DNS nor internet egress.
The single-node build never surfaced this: its server sat on a docker
network with full egress.

**Fix.** Give the server pod an explicit egress allowance — kube-dns plus
CIDR-bounded TCP 443 (private/link-local/CGN space carved out) — and
document it as a deliberate row in the traffic matrix, not an exception
someone finds later. The database caches on the datastore volume, so the
fetch is a first-boot event, but the allowance must persist for redeploys
onto fresh volumes.

## TLS, the edge, and the provider surface

### HostSNI(\*) swallows the dashboard

*(From adversarial review of documented Traefik precedence, then verified
by the working deployment's routing — not hit as a live failure.)*

Traefik evaluates matching **TCP routers before HTTP routers**. A
`HostSNI(*)` TLS-passthrough catch-all therefore captures the base
hostname too, sending dashboard and API traffic to the reverse proxy.
Match endpoint **subdomains only** —
``HostSNIRegexp(`^[a-z0-9-]+\.<base>$`)`` — and keep the bare base name on
the HTTP routers. Corollary from the same review, verified live by the SAN
gate: the lego order must carry **both SANs** (`-d <base> -d '*.<base>'`);
Traefik terminates the base name from the same Secret and a wildcard alone
does not cover it. A non-root proxy binds **8443**, not 443 — the Service
maps 443 onto it, and the NetworkPolicy names the pod port.

### lego install: "1 computed checksum did NOT match"

**Symptom.** `…/lego.tgz: FAILED` — or, stranger, one `OK` line followed
by one `FAILED` line from the same verification.

**Cause.** Two distinct causes, both hit live: the launcher was **arm64**
and the URL hardcoded `linux_amd64`; and the checksums grep for
`lego_v<v>_linux_<arch>.tar.gz` **also matches the `.sbom.json` line** of
the same name, feeding sha256sum a second, wrong entry (that one produces
the OK-then-FAILED shape).

**Fix.** Map `uname -m` to the asset arch, and anchor the grep with `$`.

### vultr_container_registry: "Can't access attributes on a primitive-typed value (string)"

**Symptom.** `tofu validate` rejects
`vultr_container_registry.x.root_user[0].username`.

**Cause.** `root_user` is a `map(string)` in the provider schema, not a
block list — the registry docs' attribute listing reads like a nested
object.

**Fix.** `root_user["username"]`, `root_user["password"]`. Related
surface facts, live-verified: registry names accept lowercase
alphanumerics only (derive from the profile by stripping everything
else), and the pushed image's digest reads back with a manifest HEAD
(`docker-content-digest`) using the root user's basic auth.

## Cluster and manifest mechanics

### First kubectl: "connection … was refused - did you specify the right host or port?"

**Symptom.** Right after `vultr_kubernetes` returns:

```
The connection to the server <uuid>.vultr-k8s.com:6443 was refused - did you specify the right host or port?
```

**Cause.** The resource exists minutes before the API server answers, and
nodes join later still.

**Fix.** The first cluster contact is a bounded wait (API answers, then a
node Ready), not a call. Related, same class: the pinned VKE version must
be checked against `GET /v2/kubernetes/versions` before the apply — a
retired minor (`v1.35.2+1` on create day) fails the apply half-way,
whereas the preflight fails free with the supported list in the error.

### "cannot unmarshal object into Go struct field ExecAction…exec.command of type string"

**Symptom.** A Deployment apply rejects with the above, pointing at a
readiness probe.

**Cause.** A probe command list entry contained `: ` (here:
`grep 'Management: Connected'`) as an unquoted YAML plain scalar — YAML
parsed the list item as a map. A generic YAML load accepts the document;
only the typed Kubernetes decode rejects it.

**Fix.** Quote any command string containing `: `. Server-side dry-run
every manifest before the real apply so typed-decode and admission errors
name the file.

## Verification that would have lied

### "HTTP 000000": the probe that fails on refusal

The inner-isolation probe captured curl's `%{http_code}` write-out and
appended `|| echo 000` — but curl prints `000` itself on connection
failure *and* exits non-zero, so refused CONNECTs produced `000000`,
failing the `!= 000` comparison and reporting the **denial** as an
**escape**. Capture with `|| true` and default the empty case instead of
appending.

### "the agent has an IPv6 default route": dual-stack plumbing is not an escape

A gate ported from the single-node build failed a healthy pod: VKE pods
carry a unique-local address (`fd10:…`) and a link-local default route
(`default via fe80::ecee:eeff:feee:eeee`) as CNI plumbing, while public
IPv6 is unreachable (probed: raw TCP to `2606:4700:4700::1111` fails).
On managed Kubernetes, **reachability per address family is the claim**;
route-table shape belongs to the CNI. Probe both families' public
addresses instead of asserting route absence.

### "exactly one proxy peer": a gate the platform cannot promise

The first selection logic demanded the network map settle on exactly one
proxy peer; lingering stale registrations (see above) make that a
permanent failure after the first proxy restart. A gate must assert what
the platform guarantees — newest-registration selection validated by an
end-to-end CONNECT — not what would be convenient.
