# Verifying a converge

The governing rule: **the deployment's product is an isolation claim, so
acceptance proves the claim or the converge fails.** A gateway that runs but
whose agent can reach the internet is not a degraded success; it is the
failure the whole design exists to prevent.

In the reference implementation (`getcolors/agent-network`), `smoke.sh` runs
gates 1–5 on the host, the converge reruns gate 1 after a real Docker
restart and (once per host) a real reboot, and the workflow's acceptance
step runs gate 6 from the converge machine — which is the only place an
external probe can honestly run.

## Checks that do not work, and why

| Check | Why it passes anyway |
|---|---|
| `docker compose ps` showing every service healthy | Health probes say the processes answer themselves. The proxy can be healthy with no registered cluster, the dashboard healthy while serving `$NETBIRD_*` placeholders, the agent healthy while fully able to reach the internet. |
| The endpoint hostname resolving | Public DNS resolves it for everyone — the wildcard record is contract. Resolution says nothing about the tunnel path or identity. |
| A 401 from the public endpoint, read as "denied" | That is the **upstream's** 401 relayed through the proxy: server-side key injection just served an unauthenticated caller. The correct external outcome is the proxy's bare pre-identity 403. |
| `iptables -L DOCKER-USER` showing the rules | Presence now proves nothing about survival: Docker rebuilds the chain on restart. Only a re-probe after a real restart/reboot counts. |
| An isolation probe suite that only contains probes that must fail | A broken agent (dead client, wrong DNS, no route to anything) passes it perfectly. Every negative suite needs a control probe that must succeed. |
| HTTPS-based "cannot reach the internet" probes | An IP-literal HTTPS request can fail on certificate/SNI grounds while routing works fine. Probe raw TCP. |
| Access-log entries "having a user" | Any attribution passes that. The entries must carry the *enrolled agent's* peer id — and a missing recorded peer id must fail, not skip. |
| The setup key "revoked" per the API | Revocation does not un-leak it. Scan `docker inspect` and bounded logs for the literal key value before discarding it. |

## The gates

1. **Isolation.** Raw-TCP probes with fixed timeouts to multiple external
   IP:ports (all must fail), route-table and IPv6 inspection, a socket
   enumeration of what *is* reachable — and a **control probe that must
   succeed** against the allowed overlay path. The reachable surface should
   be exactly the attachment matrix: Traefik's agent-side 443/80 and the
   proxy's agent-side address.
2. **The tunnel.** The agent's NetBird status shows Connected with the
   expected peer; the endpoint hostname resolves to the proxy's **overlay**
   address through the client's embedded DNS.
3. **The keyless call.** From the agent, an API call to the endpoint with
   no credential. With a real provider key: a completion, from the
   allowlisted model. In **fake-key mode**: the upstream's own 401 relayed
   through the proxy — which still proves isolation, tunnel DNS, policy
   authorization, and server-side key injection reaching the upstream, with
   nothing billable. Anything else (especially transport-level HTTP 000)
   fails.
   - **3b — guardrail denial**: a request for the claimed-but-disallowed
     model must be denied with `llm_policy.model_blocked` and leave a
     correctly attributed denial record.
   - **3c — routing denial**: a request for an unclaimed model must be
     denied with `llm_policy.model_not_routable`, likewise recorded. Both
     denials cost nothing upstream.
4. **The payload.** Headless `claude -p` inside the agent container, on the
   same governed path — proving the real workload, not just curl, traverses
   endpoint DNS, tunnel, policy, and (in fake-key mode) draws the same
   relayed 401.
5. **Attribution and limits.** Every access-log entry's `user_id` equals
   the persisted enrolled peer id (fail-closed: no persisted id is a
   failure), and the configured budget/token caps read back from the policy
   and budget-rule APIs equal desired state.
6. **The external probe.** From a machine **outside the overlay** — refuse
   to run if the probing machine has a NetBird/WireGuard interface — the
   public endpoint hostname must return **exactly HTTP 403** (the
   pre-identity denial), fail-closed on any other outcome, and the access
   log must show **zero** unattributed entries afterward (the pre-identity
   denial writes no entry; an entry would mean the request got further).

## Resilience proofs

Gate 1 is re-run after `systemctl restart docker` (every converge) and
after a real reboot (once per host, recorded in a state file) — because the
DOCKER-USER chain is rebuilt by Docker and the compose networks are
recreated, and "the rules were installed" is a different claim from "the
rules survive the events that actually happen to servers."

## Fake-key mode is a mode, not a shortcut

With a deliberately fake provider key, gates 3 and 4 assert the relayed
upstream 401 and everything else is unchanged — the denial gates never
reach upstream and the external probe never involves the key. Swapping in a
real key is a secrets-file edit plus a re-converge (the provider `PUT`
rotates the stored key), which upgrades gates 3 and 4 to require real
completions from the allowlisted model. Record which mode a converge ran
in; a green run in fake-key mode has never proven a billable completion.
