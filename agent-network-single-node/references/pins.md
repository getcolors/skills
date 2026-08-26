# Pins

## The verified-good set

Running together on a Vultr `vc2-2c-4gb` with every acceptance gate passing,
including the Docker-restart and reboot isolation proofs.
**Verified 2026-08-26.**

| Component | Pin |
|---|---|
| `netbird-server` | `netbirdio/netbird-server:0.77.1@sha256:e71f39cefcd90956d818dc4179084fd47d39f0741d1211b818ec640766b5794d` |
| `reverse-proxy` | `netbirdio/reverse-proxy:0.77.1@sha256:d3f5815133542c333e7e7166e19989adcce9afb15443a8de5ecbc87ef528c8f0` |
| `dashboard` | `netbirdio/dashboard:v2.91.1@sha256:f3eb26c93ca9901a7385e88e12f6ad98d04e075e8817c664d73557fea123875f` |
| `traefik` | `traefik:v3.7.11@sha256:5203c3f39ca70de6790d964624e042463ffbd57715bc82be155cf224c0dd5144` |
| agent base image | `node:22-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5` |
| Claude Code (in the agent) | `2.1.246` (exact npm version) |
| netbird client (in the agent) | `0.77.1` (exact version, matches the server) |
| lego (DNS-01 wildcard issuance) | `5.4.0` (official release binary, checksum-verified) |

Agent-network features are **mainline in 0.77.1** — no RC/beta track is
required at or after that release.

## The rules that generated it

The specific versions above will age out; these constraints are what matter.

### Server, proxy, and client move together — one release train

The combined server, the reverse proxy, and the in-agent client are one
protocol surface. The upstream installer treats them as a set; bump
`netbird-server` and move the proxy image and the client version in the same
change, re-reading the installer for anything else the release moved.

### Pin by tag AND digest

A tag is documentation; the digest is the pin. `name:tag@sha256:...` keeps
both readable and immovable. Resolve with:

```sh
docker buildx imagetools inspect <image>:<tag> --format '{{.Manifest.Digest}}'
```

and record the date. The agent image is built on the host from the pinned
base + exact package versions, and acceptance prints the installed versions
so the record survives in the converge log.

### On any reverse-proxy bump: re-test per-name ACME before keeping the wildcard workaround

The wildcard DNS-01 certificate exists **only** because per-name ACME is
defective on 0.77.1 (`no viable challenge type found`; see the failure
catalogue). It is a workaround with real costs — a DNS-scoped token at
converge time and renewal tied to re-converges. Test per-name issuance
**against staging Let's Encrypt** on the new proxy before deciding; testing
against production burns failed-authorization rate limits and can lock the
hostname out for hours.

### Every Claude Code model knob is pinned to the allowlisted model

`ANTHROPIC_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL`,
`ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`,
`ANTHROPIC_DEFAULT_HAIKU_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL` — all six,
plus telemetry/auto-update disabled. Claude Code releases add model tiers;
on a version bump, re-enumerate its model environment variables and pin any
new one, or the payload will someday name a model the guardrail rejects and
the happy path dies on its own policy.

### lego comes from the official release, never the distro

Ubuntu packages a gutted "dev" build without the cloudflare provider.
Checksum-verify the release tarball; note the filename inconsistency
(`lego_v<version>_...` tarball vs `lego_<version>_checksums.txt` checksums)
when templating URLs. lego v5 changed the CLI (`LEGO_PATH`,
`run -a -m ... -d ... --dns cloudflare`) — pin the version so the invocation
and the binary agree.
