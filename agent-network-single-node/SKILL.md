---
name: agent-network-single-node
description: Everything a single-node NetBird Agent Network deployment needs that the docs and the quickstart installer will not tell you - the four-container gateway stack plus one network-isolated agent, the endpoint that is minted by POSTing the settings resource and not by connecting a provider, the reverse proxy whose per-name ACME is defective on 0.77.1 ("no viable challenge type found") and burns Let's Encrypt rate limits while failing, and the acceptance gates that prove an isolation claim instead of assuming it. Use this whenever the user mentions NetBird Agent Network, a keyless or identity-gated LLM endpoint, the netbird reverse proxy, running an AI agent that must not reach the internet, or is building or debugging that stack - even if they do not say "single-node". Also use it when someone reports that the generated endpoint hostname returns HTTP 000 or has no certificate, that creating a provider returns 422 "is not a known catalog provider", that no endpoint hostname was ever generated, that the proxy container cannot reach signal or management from inside its own host, that PROXY protocol traffic arrives from an untrusted source, that a request was denied with llm_policy.model_blocked or llm_policy.model_not_routable, that an isolated container escaped after a Docker restart or reboot, or that an external request to a "tunnel-only" endpoint got an Anthropic 401 instead of being refused.
---

# Single-node NetBird Agent Network

NetBird's Agent Network gives autonomous agents keyless, identity-gated access
to LLM providers: the agent joins a WireGuard overlay, calls a generated
endpoint hostname with no API key, and the gateway attaches its peer identity,
enforces a model allowlist and budget caps, injects the provider key
server-side, and writes an attributed access log. Upstream ships a quickstart
installer and prose docs, and they get a stack *running*.

The gap this skill covers is the one after that: **the distance between a
stack that runs and a deployment whose isolation claim you can prove, tear
down, and converge again from nothing.** That distance was measured on a live
single-node build — eight converges against the real platform, a four-round
adversarial plan review, and a two-round post-build inspection — and nearly
everything load-bearing turned out to be either absent from the prose docs or
contradicted by them. Where this skill and the docs disagree, the pinned
source was read and the source is the authority; every such point names the
function it was verified in.

Everything here was verified against a running deployment unless it says
otherwise.

## The reference implementation, and why this skill ships no assets

The working files live in the
[`getcolors/agent-network`](https://github.com/getcolors/agent-network)
Package Skill — compose, Ansible converge, control-plane bootstrap, firewall,
smoke gates — under `src/resources/io/github/getcolors/agent-network/tools/`,
covered by that repo's tests and golden fixtures and consumed by the
`agent-network-vultr` deployment. This skill deliberately does **not** carry
copies of them: a second, untested copy of a compose file drifts, and this
workspace has a documented history of exactly that failure. Read the
templates there; read *why they are shaped that way* here. If you are
building this stack outside the Colors ecosystem, the topology and the traps
below transfer wholesale — only the OpenTofu/Ansible packaging is local.

For the exact REST surface, `references/api.md`. For the version set and the
rules that generated it, `references/pins.md`. For symptom-first debugging,
`references/failure-catalogue.md` — search it for your error string. For
what a trustworthy converge actually checks, `references/acceptance.md`.

## The topology

One host, Docker Compose, two networks:

```
gateway-net (egress)              agent-net (internal: true — no egress route)
┌──────────────────────────┐      ┌────────────────────────────────────┐
│ traefik ──────────────── │ ─────│ traefik      (bootstrap 443/80)    │
│ netbird-server (combined:│      │ reverse-proxy (WireGuard leg)      │
│  mgmt+signal+relay+STUN) │      │ agent        (netbird client +     │
│ dashboard (AN-only mode) │      │               headless Claude Code)│
│ reverse-proxy (private)  │      └────────────────────────────────────┘
└──────────────────────────┘
```

- **Traefik** terminates TLS for the base domain (TLS-ALPN-01) and runs a
  TCP `HostSNI(*)` passthrough with PROXY protocol v2 for everything else —
  which is how generated endpoint hostnames reach the reverse proxy without
  Traefik holding their certificates.
- **`netbird-server`** is the combined single binary: management, signal,
  relay, STUN, embedded IdP. The dashboard runs with
  `NETBIRD_AGENT_NETWORK_ONLY=true`.
- **The reverse proxy** runs `NB_PROXY_PRIVATE=true` and registers itself as
  an *embedded proxy peer* on the overlay. It is attached to both networks:
  the gateway side for its own control-plane bootstrap, the agent side for
  the WireGuard leg to the agent.
- **The agent** sits on the internal network only. Its container has
  `NET_ADMIN` and `/dev/net/tun` for the NetBird client, whose embedded DNS
  serves the zones management pushes.

The public firewall is TCP 22/80/443 and UDP 3478 (STUN) — **no WireGuard
port**, because the only peer pair (agent ↔ proxy) shares `agent-net` and
negotiates on-host candidates, with relay through `netbird-server` as the
automatic fallback.

## Isolation is two boundaries, and the claim is probed, not assumed

The internal Docker network denies the agent an egress route. That alone did
not survive adversarial review: the agent shares a network with two
egress-capable containers and holds `NET_ADMIN`. So a DOCKER-USER iptables
ruleset confines the agent subnet independently — ordered allows (TCP 443/80
to Traefik's agent-net address, anything to/from the proxy's agent-net
address because ICE negotiates ephemeral UDP ports on both sides, established
conntrack) and then a catch-all DROP for the subnet.

Two operational facts about that second boundary:

- **A Docker restart rebuilds the DOCKER-USER chain and silently discards
  your rules.** The ruleset must be reinstalled by a systemd unit with
  `PartOf=docker.service`, and acceptance must re-probe isolation after a
  real `systemctl restart docker` and a real reboot — not merely list the
  rules.
- **A probe suite that can only fail proves nothing.** Every isolation run
  pairs negative probes (raw TCP to multiple external IP:ports with fixed
  timeouts — not HTTPS, which can fail on certificate grounds and
  masquerade as isolation — plus route-table and IPv6 inspection) with a
  **control probe that must succeed** against the allowed overlay endpoint,
  so a broken agent cannot pass as an isolated one.

## The five discoveries the docs will not give you

These cost the live build most of its converge failures. Full entries with
verbatim symptoms are in `references/failure-catalogue.md`.

1. **The endpoint is minted by `POST /api/agent-network/settings
   {proxy_address}`** — not by connecting the first provider, whatever the
   quickstart prose implies (that is the dashboard's flow, not the API
   contract). A 409 means a concurrent bootstrap won, which is success.
   Ordering: proxy registered → settings → providers/policies → agent.
2. **Per-name proxy ACME is defective on the pinned 0.77.1 build.** Every
   order dies `no viable challenge type found` against authorizations that
   *offer* tls-alpn-01, under every accepted `NB_PROXY_ACME_CHALLENGE_TYPE`
   value, on production and staging Let's Encrypt alike — and each
   deactivated authorization burns the CA's failed-authorizations-per-hour
   limit, locking the name out of issuance in sliding one-hour windows.
   Endpoint TLS must come from a **wildcard certificate issued via DNS-01**
   (lego) that the proxy file-watches from a static certificate directory.
   Re-test per-name ACME on staging before dropping the wildcard on an
   image bump.
3. **The proxy's embedded netbird client hairpins.** From inside the host it
   cannot reach signal at the public hostname; it needs `extra_hosts`
   mapping the base domain to Traefik's gateway-network address. The agent
   needs the same mapping for its bootstrap — and **only** the base domain:
   management pushes authorized peers a DNS custom zone resolving the
   endpoint hostname to the proxy's *overlay* address plus a synthesized ACL
   on TCP 80/443 (`SynthesizePrivateServiceZones`,
   `injectPrivateServicePolicies` in management source), so mapping the
   endpoint via `extra_hosts` would route the metered path around the
   identity boundary.
4. **Traefik picks an arbitrary shared network to dial a container it routes
   to.** With PROXY protocol trust pinned to one source address, that choice
   must not float: set `traefik.docker.network` on the proxy and give the
   compose networks explicit names (renaming a network requires a
   `compose down`, or the old one lingers and the label points at nothing).
5. **A caller without a tunnel has no identity, and the proof is exact.**
   Private services enforce `ValidateTunnelPeer`; a request through the
   public `HostSNI(*)` passthrough gets a bare pre-identity `403` and writes
   *no access-log entry*. An external probe must require exactly that 403 —
   an Anthropic `401` from outside means server-side key injection just
   served an unauthenticated caller, which is the vulnerability, not the
   proof. And run the probe from a machine with no NetBird/WireGuard
   interface, or it is not external.

## The setup key's whole life

One-off type (`type:"one-off"` — single-use is server-enforced), short
expiry, `auto_groups` placing the peer straight into its group. It travels as
a **file on tmpfs** into `netbird up --setup-key-file` — never argv, never
compose configuration, never an image layer. After enrollment: verify the
peer and its group membership, revoke the key, remove the file, and scan
`docker inspect` and bounded container logs for the **literal key value**
(searching for a phrase finds nothing; the value is what leaks). An enrolled
peer reconnects from its state volume and never needs a key again — that is
what makes single-use possible.

The same create-once discipline applies to every minted credential: the proxy
admin token and the automation PAT are reconciled by name, persisted
atomically (temp file + rename) *before* first use, and orphans are
enumerated and revoked on retry — a crash between mint and persist otherwise
leaves an undiscoverable live credential.

## Deny-by-policy is free; use it

Have the provider claim **two** models and the guardrail allow **one**. Then
both denial classes are demonstrable at zero upstream cost: the claimed but
disallowed model draws `llm_policy.model_blocked` (guardrail) and an
unclaimed model draws `llm_policy.model_not_routable` (routing) — and each
must leave a correctly attributed denial record in the access log.

Two corollaries:

- **A deliberately fake provider key is a supported mode, not a degraded
  one.** The keyless call then expects the upstream's own 401 *relayed
  through the proxy* — which proves isolation, tunnel DNS, policy
  authorization, and server-side key injection reaching the upstream, with
  nothing billable. A real key upgrades the same gates to require
  completions; the provider PUT rotates the stored key.
- **Pin every model knob the payload can use.** For Claude Code that is
  `ANTHROPIC_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL`, the three
  `ANTHROPIC_DEFAULT_*_MODEL`s and `CLAUDE_CODE_SUBAGENT_MODEL`, all set to
  the allowlisted model, with telemetry and auto-update traffic disabled.
  One unpinned tier lets the payload name a model the guardrail rejects,
  and the happy path dies on its own policy.

## Limits bind groups, not users

The autonomous caller is a *peer*, not an IdP user, so per-user policy caps
do not bind it. Put the budget and token caps **per-group on the peer
group**, add an account-wide budget rule as the ceiling, and read both back
at acceptance against desired state — a cap that was never read back is a
cap you hope exists.

## Disposable is a decision, not an omission

This deployment holds real state — datastore, keys, PATs, TLS material,
usage history — and none of it is worth outliving the box. Declaring it
disposable is coherent **only** with the consequences stated: recovery is
delete + create, which regenerates the endpoint hostname and every peer
identity, and anything that memorized the old endpoint name breaks. Either
write that down and test the full rebuild, or build backups; the incoherent
middle (no backups, plus an assumption that state survives) is what review
rejects.
