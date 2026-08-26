# Failure catalogue

Every entry was hit on a real converge of a live single-node Agent Network
deployment (netbird-server 0.77.1, reverse-proxy 0.77.1, dashboard v2.91.1),
2026-08-26. **Search for your symptom string first** — several are verbatim
error text. None of these were reachable by unit tests or golden fixtures;
they only appear against the real platform.

## Contents

- [TLS and certificates](#tls-and-certificates)
- [The endpoint path](#the-endpoint-path)
- [Control-plane bootstrap](#control-plane-bootstrap)
- [Credentials and their crash windows](#credentials-and-their-crash-windows)
- [Isolation boundaries](#isolation-boundaries)
- [Verification that would have lied](#verification-that-would-have-lied)
- [Cosmetic and environmental](#cosmetic-and-environmental)

---

## TLS and certificates

### Every endpoint certificate order dies "no viable challenge type found"

**Symptom.** The generated endpoint hostname resolves and routes, but TLS
never comes up. The reverse proxy's log shows every ACME order failing with
`acme/autocert: no viable challenge type found`. Retrying does not help;
switching `NB_PROXY_ACME_CHALLENGE_TYPE` between its accepted values does
not help; staging Let's Encrypt fails identically. Fetching the failed
authorization object from the CA shows it **offering `tls-alpn-01`** — the
challenge the proxy claims to speak.

**Cause.** The per-name ACME responder in reverse-proxy 0.77.1 is defective.
This is not a configuration problem: it was verified against live
authorization objects, under every accepted challenge-type value, on
production and staging alike, and with `NB_PROXY_ACME_ADDRESS` variations.

**The trap inside the trap.** Each failed order *deactivates* an
authorization, and deactivated authorizations count toward Let's Encrypt's
failed-authorizations-per-hour limit. The defect therefore also **locks the
hostname out of issuance for sliding one-hour windows** — on the live build
this alone cost ~2.5 hours, and it punishes exactly the person retrying
diligently.

**Fix.** Stop ordering per-name certificates. Issue a **wildcard certificate
for the endpoint parent domain via DNS-01** at converge time and hand it to
the proxy as a static certificate:

- `NB_PROXY_CERTIFICATE_DIRECTORY=/wildcard`, `CERTIFICATE_FILE=wildcard.crt`,
  `KEY_FILE=wildcard.key`, and ACME off. **`CERTIFICATE_FILE` is relative to
  the certificate directory**, not absolute.
- The files must be readable by the container user (uid 1000 in the shipped
  image) — root-owned 0600 files produce a proxy that silently serves
  nothing.
- The proxy file-watches the pair, so renewal is replacing the files in
  place; tie renewal to the converge (reissue under 30 days remaining).

Re-test per-name ACME **on staging** before dropping the wildcard on any
proxy image bump — the defect is version-specific and the wildcard is a
workaround, not a design preference.

### lego pitfalls while implementing the DNS-01 workaround

Three in a row on a stock Ubuntu host:

1. **Ubuntu's packaged `lego` is a gutted "dev" build without the cloudflare
   provider.** Install the official release binary, checksum-verified — the
   checksums file is `lego_<version>_checksums.txt` while the tarball is
   `lego_v<version>_...`, an inconsistency that breaks naive URL templating.
2. **lego v5 changed its CLI**: state lives under `LEGO_PATH`, and issuance
   is `run -a -m <email> -d <domain> --dns cloudflare` with the token in
   `CLOUDFLARE_DNS_API_TOKEN` (keep it out of argv and logs).
3. **Propagation checks fail on hosts with broken resolvers.** If
   `/etc/resolv.conf` lists unreachable (e.g. IPv6-only) nameservers, lego's
   pre-check never sees the TXT record. `--dns.resolvers 1.1.1.1:53
   --dns.propagation.disable-rns` makes the check use a resolver that
   exists.

The same record-edit DNS token that manages the A records suffices for the
DNS-01 TXT records — no broader scope needed.

---

## The endpoint path

### The keyless call returns HTTP 000 forever (cause 1: the proxy hairpins)

**Symptom.** From the agent, every request to the endpoint hostname fails at
the transport layer — `curl` reports `HTTP 000`, no TLS, no response.
Meanwhile the proxy container logs show its *embedded netbird client* unable
to reach signal/management at the public base hostname. Everything is
"healthy" in `docker compose ps`.

**Cause.** Hairpin NAT. The proxy's embedded client resolves the base domain
to the host's public address and dials out; the connection never loops back
into Traefik on the same host. Until the proxy's client registers, the
endpoint has no live backend.

**Fix.** `extra_hosts` on the proxy container mapping the base domain to
**Traefik's gateway-network static address**. The agent container needs the
same mapping for its own bootstrap — and *only* the base domain (see the
next-but-one entry for why the endpoint hostname must not be mapped).

### The keyless call returns HTTP 000 (cause 2: PROXY protocol from an untrusted source)

**Symptom.** The proxy's client is registered, the endpoint resolves over
the tunnel, WireGuard is up — and the call still dies. The proxy rejects
Traefik's connections because the PROXY protocol v2 header arrives from a
source address other than the one `NB_PROXY_TRUSTED_PROXIES` names.

**Cause.** Traefik and the proxy share **two** Docker networks, and Traefik
picks an arbitrary one to dial a backend. When it picks the agent-side
network, its source address is not the trusted gateway-side one.

**Fix.** Pin the dial network with the `traefik.docker.network` label on the
proxy, and give both compose networks **explicit `name:`s**. Note that
renaming a compose network is a create-new-abandon-old operation: it needs a
`docker compose down` first, or the stack keeps a stale network and the
label points at nothing.

### Mapping the endpoint hostname in `extra_hosts` "works" and bypasses everything

**Symptom.** None — that is the problem. The agent reaches the endpoint via
a Docker-network address, requests succeed, and every request arrives
without a peer identity attached, so identity, policy, and attribution are
silently not in the loop.

**Cause.** The metered path is *supposed* to ride the WireGuard tunnel:
management pushes authorized peers a DNS custom zone resolving the endpoint
hostname to the proxy's **overlay** address, plus a synthesized ACL
admitting TCP 80/443 (`SynthesizePrivateServiceZones` and
`injectPrivateServicePolicies` in management source). A static host mapping
routes around all of it.

**Fix.** `extra_hosts` carries exactly one mapping — the base domain, for
bootstrap, which precedes tunnel DNS. Assert the count in a test. The
endpoint hostname resolves through the client's embedded DNS or not at all.

---

## Control-plane bootstrap

### Creating the provider returns 422 "is not a known catalog provider"

**Symptom.** `POST /api/agent-network/providers` with
`provider_id: "anthropic"` returns 422:
`provider_id "anthropic" is not a known catalog provider`.

**Cause.** The catalog id is **`anthropic_api`**. The prose docs and the
dashboard UI both say "Anthropic"; the API does not.

**Fix.** Read `GET /api/agent-network/catalog/providers` and use the ids it
returns rather than guessing from display names.

### No endpoint hostname is ever generated

**Symptom.** Providers, guardrails, and policies exist; the dashboard shows
the Agent Network view; `GET /api/agent-network/settings` returns an empty
`endpoint`. The docs said the endpoint is "generated when you connect your
first provider". It was not.

**Cause.** That sentence describes the *dashboard's* flow, not the API
contract. The endpoint label is minted by
`POST /api/agent-network/settings {"proxy_address": "<domain>"}` — which the
dashboard happens to call for you.

**Fix.** POST settings explicitly, **after** the proxy cluster has
registered (retry while it does — the POST fails until the cluster is
visible). Treat **409 as success**: it means a concurrent bootstrap won the
race and the endpoint exists. Subsequent `PUT`s are full-replace and must
echo the immutable `endpoint`/`proxy_address` unchanged or draw a 422.

### `docker compose exec` fails because a *different* service's env_file is missing

**Symptom.** Minting the proxy token via
`docker compose exec netbird-server netbird-server admin token create ...`
fails before running anything: compose refuses to **parse the file** because
`proxy.env` (or the agent's env file) does not exist yet — even though the
exec targets a service that does not use it.

**Cause.** Compose validates every `env_file` in the project at parse time.
The bootstrap has a cycle: the proxy's env file cannot be rendered until the
token is minted, and the token cannot be minted while compose refuses to
parse.

**Fix.** Create **placeholder env files** before first parse and render the
real content over them later — the upstream installer does exactly this, and
losing that detail when re-deriving its compose is how the cycle appears.

### The dashboard serves literal `$NETBIRD_*` placeholders while "healthy"

**Symptom.** The dashboard container is up, `/` returns 200, and the served
JavaScript contains unresolved `$NETBIRD_*` placeholder strings. Login
fails confusingly later.

**Cause.** The image's `init_react_envs` exits 1 on a missing variable, but
supervisord carries on and nginx serves the un-substituted bundle.

**Fix.** Acceptance must read the *served* chunks and fail on placeholder
patterns — container health and HTTP 200 check neither.

---

## Credentials and their crash windows

### A crash between minting and persisting leaves an undiscoverable live credential

**Symptom.** Nothing visible — an orphaned proxy admin token or automation
PAT that no file records, discovered only by listing tokens server-side.

**Cause.** `admin token create` (or the PAT POST) succeeded; the write of
the env file or token file did not happen before the process died. The
"re-run converge repairs everything" guarantee is false for that window
unless repaired deliberately.

**Fix.** Reconcile credentials **by stable name**: on every converge,
enumerate existing tokens, revoke any bearing the managed name that the
persisted file does not match, then create-and-persist atomically (temp
file + rename, persist **before** first use). The durable automation PAT is
minted whenever the persisted one is missing — which also closes the
setup-PAT window: persist the short-lived setup PAT immediately on exchange,
then rotate to the durable one.

### The setup key leaks through channels you did not think of

**Symptom.** The enrollment key is visible in `ps` output (argv), in
`docker inspect` (compose environment), or in container logs.

**Fix.** The pinned client supports `netbird up --setup-key-file <path>`
(mutually exclusive with `--setup-key`) — file-based, non-argv. Deliver the
file on **tmpfs**, use a one-off key (`type:"one-off"` is server-enforced
single-use) with `auto_groups` so no follow-up group call is needed, and
after enrollment: verify the peer id and group, revoke the key, remove the
file, and grep `docker inspect` plus bounded logs for the **literal key
value** while you still hold it. Scanning for a phrase like "setup key"
finds nothing; the value is what leaks. Do not claim `shred` semantics on
overlay/CoW filesystems — tmpfs plus removal plus absence assertions is the
honest contract.

---

## Isolation boundaries

### A Docker restart silently discards the DOCKER-USER rules

**Symptom.** Isolation probes pass at converge. After `systemctl restart
docker` (or a reboot, or a Docker upgrade), the agent subnet's DROP rules
are gone. Nothing reports this.

**Cause.** Docker rebuilds its iptables chains, including DOCKER-USER, on
restart.

**Fix.** Install the ruleset from a systemd unit with
`PartOf=docker.service` so it re-fires with Docker, make the script
idempotent (`iptables -C || iptables -I`), and have acceptance **re-probe
isolation after a real Docker restart and a real reboot** — listing rules
proves presence, not survival. Record the proofs in state files so the
expensive reboot proof runs once per host, not per converge.

### The intra-subnet allow rule was broader than the design

**Symptom.** None — review caught it. A blanket
`-s <subnet> -d <subnet> -j RETURN` admits agent → anything-on-the-subnet,
wider than the attachment matrix promises.

**Fix.** Port-scope what can be scoped: TCP 443/80 to Traefik's agent-side
address. The proxy leg deliberately stays address-scoped but not
port-scoped, **and that is worth documenting rather than hiding**: ICE
negotiates ephemeral UDP candidates on both sides, so a static port list
either breaks the WireGuard leg or degenerates into all-UDP while
pretending precision. Remove the legacy broad rule explicitly on upgrade —
`iptables -I` never removes what an earlier version inserted.

### `internal: true` alone is not an isolation claim

The agent shares the internal network with two egress-capable containers
and holds `NET_ADMIN`. The compose flag removes the egress route; it does
not confine a capable container. The DOCKER-USER ruleset is the second,
independent boundary, and the acceptance probes (raw TCP with a success
control — see `references/acceptance.md`) are what turn the pair into a
claim. An adversarial-payload threat model is explicitly beyond this
design; say so rather than implying otherwise.

---

## Verification that would have lied

### The external probe accepted an Anthropic 401 as "tunnel-only"

**Symptom.** The probe hit the public endpoint hostname from outside the
overlay, got a 401, and passed — reasoning "denied, good".

**Cause.** That 401 is the *upstream's*, relayed through the proxy — which
means server-side key injection just serviced an unauthenticated external
caller. With a real key that request would have been a billable completion.
The correct external outcome is the proxy's **pre-identity bare 403**
(`ValidateTunnelPeer` fails before any provider logic), which also writes
**no access-log entry**.

**Fix.** Require **exactly** HTTP 403, fail-closed on every other outcome
(200 and 401 are the worst two), assert zero unattributed access-log
entries afterward, and refuse to run the probe from a machine carrying a
NetBird/WireGuard interface — a probe from inside the overlay is not
external, whatever the hostname resolution says.

### Attribution that trusts the log instead of the peer

**Symptom.** "Every request is attributed" verified by checking the
access-log entries have a `user_id` — any `user_id`.

**Fix.** Capture the enrolled agent's peer id at enrollment, persist it,
and require every access-log entry's `user_id` to equal it — and make a
*missing* recorded peer id a failure, not a skip. A check that skips itself
when its precondition is absent has been passing vacuously.

### Denial assertions matched prose, not codes

**Symptom.** Gates grepping for "model not allowed" / "model not available"
fail against the real responses.

**Fix.** The wire codes are `llm_policy.model_blocked` (guardrail
allowlist) and `llm_policy.model_not_routable` (no provider claims the
model). Match the codes, accept the prose as a fallback pattern, and
require each denial to leave a correctly attributed access-log record with
the matching reason.

---

## Cosmetic and environmental

### The signal gRPC stream resets about once a minute

**Symptom.** `RST_STREAM` with `INTERNAL_ERROR` in the signal stream through
Traefik roughly every minute; both sides log a reconnect and stay
Connected.

**Status.** Cosmetic on the live build — no gate ever failed on it. Worth
knowing so it is not mistaken for the cause of a real failure.

### The provider API can be globally down while your config is fine

The live build hit an account-wide Vultr API outage (HTTP 500 on every
endpoint) mid-converge, twice. Preflight failures that smell like
credentials can be the provider; check the provider's status before
rotating keys or bisecting your own change.
