# skills

Agent skills for the [getcolors](https://github.com/getcolors) workspace. They
give coding agents repeatable operating procedures; they are not Colors Package
Skills and do not provision a project from `colors.yml` themselves.

## Skills

| Skill | What it does |
|---|---|
| [`create-package-skill`](create-package-skill/SKILL.md) | Guides an agent through creating a Colors Package Skill and a deployment, with explicit boundaries around credentials, infrastructure changes, and authorization. |
| [`agent-network-single-node`](agent-network-single-node/SKILL.md) | Carries what a single-node NetBird Agent Network deployment needs beyond the docs: the gateway-plus-isolated-agent topology, the endpoint minted by the settings POST rather than the first provider, the defective per-name proxy ACME and its wildcard DNS-01 workaround, and acceptance gates that prove the isolation claim. Points at `getcolors/agent-network` as the reference implementation instead of shipping file copies. |
| [`agent-network-kubernetes`](agent-network-kubernetes/SKILL.md) | The Kubernetes sibling: the two-pod netstack/SOCKS5 application (no TUN, no capabilities), the 0.77.1 client facts only a live VKE converge surfaces — flags silently ignored on `service run`, the embedded proxy peer absent from `/api/peers` whose overlay address churns per restart, the server's strict-base64 keys and mandatory GeoLite egress — and isolation probed from both sides of the SOCKS5 listener. Points at `getcolors/agent-network-k8s` as the reference implementation. |
| [`posthog-single-node`](posthog-single-node/SKILL.md) | Carries the PostHog-specific knowledge a single-node deployment needs: the ten-container topology, the ClickHouse Keeper, macro and named-collection configuration its migrations require, the capture/plugin-server ingestion chain, converge ordering, and a catalogue of ~30 failures that each report success. Points at `getcolors/posthog` as the reference implementation instead of shipping file copies. |
| [`rybbit-single-node`](rybbit-single-node/SKILL.md) | Covers the distance between a single-node Rybbit analytics stack that runs and one you can trust: the six-container topology, the one provider-coupled OpenTofu file that lets the same converge run anywhere with an SSH port, ClickHouse backups proven by restoring them, and acceptance checks that catch a stack which looks healthy and stores nothing. Points at `getcolors/rybbit` as the reference implementation instead of shipping file copies. |
| [`neon-single-node`](neon-single-node/SKILL.md) | Carries what a single-node self-hosted Neon deployment needs beyond the docs: the four-container storage/compute topology, the compute spec as the auth system (SCRAM verifiers, uid-1000 file ownership, the recreate-only compute container), Cloudflare R2 as remote storage with its rclone traps, the honestly measured single-node RPO, and rehearsed recovery at rising generations. Points at `getcolors/neon` as the reference implementation instead of shipping file copies. |
| [`langfuse-multi-node`](langfuse-multi-node/SKILL.md) | Carries what self-hosted Langfuse v4 on separate machines needs beyond the docs: the six-machine topology (a Neon storage tier, Redis, three ClickHouse replicas with Keeper, the app host), the v4 `events_only` write mode as the contract every gate must speak (OTLP in, Observations API v2 out, `events_full` in ClickHouse), the Prisma `P3005` trap a Neon-provisioned database springs, the `s3_plain` backup disk, the restore-time pairing rule, and a rehearsed restore-and-boot. Points at `getcolors/langfuse` as the reference implementation instead of shipping file copies. |
| [`clickhouse-replicated`](clickhouse-replicated/SKILL.md) | Carries what three replicated ClickHouse nodes with embedded Keeper need beyond the docs: the config.d facts that cost converges (`--` inside an XML comment, an `<engine>` override refused beside the packaged `partition_by`, the lazily created `system.query_log`), the `s3_plain` backup disk as the credential boundary with sets verified by equality against `system.backups`, a restore beside the live database proven collision-free through `{uuid}` replica paths, the grants an application documents versus the grants an operator's gates need, two firewalls filtering the VPC interface on Vultr, and the replica-loss drill. The ClickHouse-side sibling of `langfuse-multi-node`; points at `getcolors/langfuse` as the reference implementation instead of shipping file copies. |
| [`n8n-single-node`](n8n-single-node/SKILL.md) | Carries what a self-hosted n8n 2.x deployment needs that the docs and every third-party guide get wrong: the keys 2.x renamed and the defaults it did not actually make safe, the encryption key n8n persists on first boot and then refuses to start without, the API that redacts credential values so decryption can only be proven by using them, and an acceptance doctrine written after a converge reported success in 614 ms with zero gates executed. Points at `getcolors/n8n` as the reference implementation instead of shipping file copies. |
| [`submit-package-skill`](submit-package-skill/SKILL.md) | Validates an existing Package Skill and opens the recipe PR that submits it to the getcolors.ai Package Skills Catalog. |
| [`clipboard-screenshot`](clipboard-screenshot/SKILL.md) | Pulls the image on the user's clipboard into the agent's context. Reads the local clipboard bridge on `/tmp/clipboard.sock`, saves the bytes under their real image extension, and separates the failure modes — bridge down, clipboard empty, clipboard holding something that is not an image — so the agent asks for the right fix. |
| [`refresh-oci-token`](refresh-oci-token/SKILL.md) | Renews the OCI CLI session token. Extends it in place while it is still valid; falls back to a browser login when it has expired, adding the login URL to the current Emacs server's kill ring so a headless host can complete the flow. |

## Use create-package-skill

Give the skill to your coding agent for its next request:

```sh
npx skills use "https://github.com/getcolors/skills" --skill "create-package-skill"
```

This is the primary way to use it. The command reads the skill directly from
GitHub and prints the instructions for the agent; it does not install files into
the current project.

## Submit a Package Skill

After a Package Skill is complete and publication is explicitly authorized:

```sh
npx skills use "https://github.com/getcolors/skills" --skill "submit-package-skill"
```

The workflow adds a catalog recipe and opens a PR; it does not merge the PR,
build artifacts, or provision infrastructure.

## Install refresh-oci-token

`refresh-oci-token` includes a script that must remain available after the skill
is loaded, so install the whole directory with your agent's skill mechanism.
Install roots are agent-specific (for example, `~/.claude/skills/` for Claude
Code and `~/.pi/agent/skills/` for Pi) and may be copies or symlinks into a
shared personal skills directory. Pulling this repo does not necessarily update
the installed skill; compare the directory at the location reported by your
agent when troubleshooting.

The script runs under [babashka](https://babashka.org/) and also needs the `oci`
CLI on `PATH`.

## Install clipboard-screenshot

`clipboard-screenshot` carries a script too, so install the whole directory the
same way — the same caveat about install roots and stale copies applies. The
script is bash and needs `nc`, `file` and `timeout` on `PATH`, plus the clipboard
bridge listening on `/tmp/clipboard.sock` (override with `CLIPBOARD_SOCKET`).
Without the bridge the skill reports that it cannot reach the clipboard rather
than guessing at the image.

## These are not Package Skills

The Colors stack has a second, unrelated thing called a skill: `package-once-*`
and `package-walter-green`, which ship inside
[`once`](https://github.com/getcolors/once) and
[`walter`](https://github.com/getcolors/walter) and are installed into a
*project* with `npx skills add getcolors/once`. Those converge real
infrastructure from a `colors.yml`, are pinned to a library by git SHA, and are
recorded in a `skills-lock.json`.

Nothing in this repo works that way. A skill here has no lockfile, no pin, and no
desired-state file — it is a script and the prose telling an agent when to reach
for it.

## Adding a skill

```
<skill-name>/
    SKILL.md              frontmatter (`name`, `description`), then the prose
    <skill-name>.clj      the script, when there is one
    references/           docs the agent reads on demand, not up front
    assets/               working files it copies and adapts
    scripts/              checks and helpers it runs
    evals/                prompts, expected outputs and assertions for the skill
```

Some skills here are just `SKILL.md`. The three optional directories exist for a
skill carrying more than an agent should hold in context at once: keep `SKILL.md`
the map, and point at `references/` for the detail. The Context Skills use
`references/` and `evals/` (never `assets/` — their companions own the working
files); `clipboard-screenshot` uses `scripts/` alone.

The `description` is routing text: it is all an agent sees when deciding whether
the skill applies, so name the symptoms someone would actually hit — the error
message, the command that failed — rather than describing how the skill works.
Save that for the body.

Scripts should guard their entry point so the file can be loaded without running
anything:

```clojure
(when (= *file* (System/getProperty "babashka.file")) (main *command-line-args*))
```
