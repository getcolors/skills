# The management API, as the source defines it

Verified in netbirdio/netbird@v0.77.1 (management) and
netbirdio/dashboard@v2.91.1 (the authority for the agent-network REST
shapes), 2026-08-26, and exercised end to end by a live bootstrap. Where the
prose docs disagree with this file, the source was read and this file wins —
the two known disagreements (endpoint minting, tunnel DNS) are marked.

Auth on every call: `Authorization: Token <PAT>`.

## Bootstrap sequence

1. `POST /api/setup` — one-shot (requires `NB_SETUP_PAT_ENABLED=true`);
   mints the local owner account and a **short-lived** PAT. Persist that PAT
   immediately, then exchange it:
2. `GET /api/users` → the entry with `.is_current` for your own user id;
   `POST /api/users/{id}/tokens` `{name, expires_in}` → `.plain_token`, the
   durable automation PAT. Reconcile by token *name*; revoke orphans bearing
   the managed name; rotate before expiry.
3. Proxy admin token (not REST): `netbird-server admin token create --name
   <name> --config /etc/netbird/config.yaml`, run inside the server
   container. Create-once, delete-by-name first, persist atomically before
   the proxy starts.

## Setup keys

`POST /api/setup-keys`:

```json
{"name": "...", "type": "one-off", "expires_in": 3600,
 "usage_limit": 1, "auto_groups": ["<groupID>"],
 "ephemeral": false, "allow_extra_dns_labels": false}
```

`type:"one-off"` is enforced single-use server-side
(`setup_keys/setupkeys_handler.go:71-76` in v0.77.1). `auto_groups` places
the enrolling peer straight into the group your policy sources — no
follow-up call, no window where the peer exists ungrouped. Revoke after
confirmed enrollment.

## The agent-network module

Routes from dashboard v2.91.1 `src/modules/agent-network/`:

### `GET/POST/PUT /api/agent-network/settings` — the endpoint itself

**`POST` with `{"proxy_address": "<domain>"}` is what mints the endpoint
label** (docs disagreement #1: "generated when you connect your first
provider" is the dashboard's flow, not the API contract). The body is
exactly one of `proxy_address` (labeled mode — the server allocates a label
beneath the cluster domain) or `endpoint` (dedicated/BYOP).

- The POST fails until the proxy cluster has registered — retry.
- **409 = a concurrent bootstrap won = success.**
- `GET` returns `{endpoint, proxy_address, dedicated,
  enable_log_collection, enable_prompt_collection, redact_pii,
  access_log_retention_days, ...}`; an empty `endpoint` means not yet
  bootstrapped.
- `PUT` is **full-replace** and must echo `endpoint`/`proxy_address`
  unchanged (422 on mismatch).

### `GET/POST/PUT/DELETE /api/agent-network/providers`

```json
{"provider_id": "anthropic_api", "name": "...", "upstream_url": "...",
 "api_key": "...", "enabled": true,
 "models": [{"id": "...", "input_per_1k": 0.0, "output_per_1k": 0.0,
             "cache_read_per_1k": 0.0, "cache_creation_per_1k": 0.0}]}
```

- `provider_id` must be a **catalog id** from
  `GET /api/agent-network/catalog/providers` — for Anthropic that is
  `anthropic_api`; bare `anthropic` draws a 422.
- `api_key` is write-only; a `PUT` carrying it rotates the stored key.
- Claim more models than you allow (see policies) so denial classes are
  demonstrable at zero cost.

### `GET/POST/... /api/agent-network/guardrails`

```json
{"name": "...", "description": "...",
 "checks": {"model_allowlist": {"enabled": true, "models": ["..."]},
            "prompt_capture": {"enabled": false, "redact_pii": false}}}
```

### `GET/POST/... /api/agent-network/policies`

```json
{"name": "...", "enabled": true,
 "source_groups": ["<groupID>"],
 "destination_provider_ids": ["<providerID>"],
 "guardrail_ids": ["<guardrailID>"],
 "limits": {"token_limit": {"enabled": true, "group_cap": 0,
                            "user_cap": 0, "window_seconds": 86400},
            "budget_limit": {"enabled": true, "group_cap_usd": 0.0,
                             "user_cap_usd": 0.0, "window_seconds": 86400}}}
```

The autonomous caller is a **peer**, not an IdP user — bind the caps with
`group_cap`/`group_cap_usd` on the peer group, not the per-user fields.

### `GET/POST/... /api/agent-network/budget-rules`

Account-wide ceilings: `{name, enabled, target_groups?, target_users?,
limits: <same limits shape>}`.

### `GET /api/agent-network/access-logs`

Paged `{data: [...]}`; each entry carries `timestamp, user_id, model,
provider, decision, deny_reason, status_code, input_tokens, output_tokens,
total_tokens, cost_usd, session_id, group_ids, ...`. Acceptance reads
decisions, deny reasons (`llm_policy.model_blocked`,
`llm_policy.model_not_routable`), models, and attribution here — `user_id`
is the peer id for tunnel callers. An external caller denied pre-identity
writes **no entry at all**.

### `GET /api/agent-network/usage/overview?granularity=day`

Usage buckets, for read-back and dashboards.

## The packet path (docs disagreement #2)

How a peer's keyless call actually reaches the proxy, from management
source (v0.77.1, `management/server/types/account.go` unless noted):

- The reverse proxy in `NB_PROXY_PRIVATE=true` registers as an **embedded
  proxy peer** (`peer.ProxyMeta.Embedded`; cluster = its domain).
- `injectPrivateServicePolicies` (account.go:1702) synthesizes an in-memory
  ACL: access groups → the cluster's proxy peers, **TCP 80/443**.
- `SynthesizePrivateServiceZones` (account.go:242) pushes authorized peers
  an in-memory DNS custom zone: A records resolving each private service's
  hostname to the cluster's proxy-peer **overlay** IPs.
- `ValidateTunnelPeer` (proxy `service.go:254-255`) denies any request that
  did not arrive over a peer's WireGuard tunnel — the public `HostSNI(*)`
  passthrough still exposes TCP 443, and requests through it carry no
  identity: a bare pre-identity 403, no access-log entry.

Consequences: no `extra_hosts` for the endpoint hostname, ever (the pushed
zone + synthesized ACL are the metered path); no public WireGuard port when
the only external peer pair shares a Docker network; and the strict external
probe contract in `references/acceptance.md`.

## Client mechanics

- Enrollment: `netbird up --setup-key-file <path>` — file-based, mutually
  exclusive with `--setup-key` (client/cmd/root.go:157). No argv, no env.
- The client needs `NET_ADMIN` and `/dev/net/tun`; its embedded DNS is what
  serves the pushed custom zones inside the container, so the container's
  DNS must not be overridden away from it.
