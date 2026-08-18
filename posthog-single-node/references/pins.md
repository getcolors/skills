# Image pins

## The verified-good set

Every one of these was running together on a `s-4vcpu-8gb` droplet with events
flowing end to end. **Verified 2026-08-17.**

| Service | Image |
|---|---|
| `web`, `worker` | `posthog/posthog:82ea6681305bb00ad4ca920e3ba6e8fb39157424` |
| `plugins` | `posthog/posthog-node:82ea6681305bb00ad4ca920e3ba6e8fb39157424` |
| `capture` | `ghcr.io/posthog/posthog/capture@sha256:8b07f51be1a8983c4d171b443a58c0deb3ab1e6e15202729cde85c3fa280b3e5` |
| `clickhouse` | `clickhouse/clickhouse-server:26.6.2.158` |
| `kafka` | `redpandadata/redpanda:v25.1.9` |
| `temporal` | `temporalio/auto-setup:1.26.2` |
| `db` | `postgres:17-alpine` |
| `redis` | `redis:7.2-alpine` |
| `caddy` | `caddy:2.11.4` |

The bundled `assets/ansible/checkpoint.sql` belongs to `82ea6681…` — 309 tables,
1337 applied migrations — and is refused by the commit guard against any other
image.

## The rules that generated it

Start here when the set above has aged out. These constraints are what cost the
time; the specific versions are just their current solution.

### The application and plugin server must be **one commit**

They share a Postgres schema. Floating tags on either side mean the Node process
queries columns the application's migrations never created — which surfaces as
`column posthog_person.last_seen_at does not exist`, with the consumer dying on
its first message and events silently stopping in Kafka.

`82ea668` is the commit the plugin server was built from, and it is published
for the application too. When moving, **start from a `posthog/posthog-node` tag**
and confirm `posthog/posthog` publishes the same one — the Node image is the
scarcer side.

Verify at converge time rather than trusting the tag: the image reports its
commit at `/code/commit.txt`.

### ClickHouse must be the version upstream pins

Not "recent", not "stable" — the one upstream develops against. PostHog's schema
puts TTLs on `DateTime64` columns, and older servers reject them outright:

```
TTL expression result column should have DateTime or Date type,
but has DateTime64(3, 'UTC')
```

24.8 fails this way. Read upstream's compose for the current pin rather than
picking a version yourself.

### Capture must be pinned by digest

`ghcr.io/posthog/posthog/capture` publishes `:master`, which moves under the
deployment. There is no semver tag to hold onto, so resolve `:master` to a
digest and pin that:

```sh
docker buildx imagetools inspect ghcr.io/posthog/posthog/capture:master \
  --format '{{.Manifest.Digest}}'
```

Record the date you resolved it. Whatever validates desired state should accept
the digest form — `name@sha256:…` and `name:tag@sha256:…` — because a digest is
the only pin that cannot move.

### The datastores are ordinary

Postgres, Redis and Caddy have no PostHog-specific constraint; pin them to
explicit tags for reproducibility and move them on their own schedule. Redpanda
and Temporal follow upstream's compose, but neither has bitten yet.

## When you move a pin

1. Move the application and plugin server **together**, to a commit both publish.
2. Check upstream's compose for the ClickHouse version at that commit.
3. Re-resolve the capture digest.
4. **Regenerate `checkpoint.sql`** — the old one is now from a divergent commit
   and the guard will correctly refuse it, silently costing an hour per fresh
   deployment. See the regeneration commands at the end of `SKILL.md`.
5. Re-run acceptance end to end. Read `references/acceptance.md` first: the
   checks that matter here are the ones that fail when the stack is broken, and
   several obvious ones do not.
