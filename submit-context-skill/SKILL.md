---
name: submit-context-skill
description: Submit an existing Colors Context Skill to the getcolors.ai catalog by validating it against the Context Skill Standard, adding a type context recipe, and opening a pull request.
---

# Submit a Context Skill

Submit an existing Context Skill to the PR-curated catalog at
`https://www.getcolors.ai/skills`. The catalog provides discoverability only:
GitHub remains the source, `npx skills use` remains how an agent loads it, and
the catalog does not build or host artifacts.

## Qualifying definition

The canonical definition is the Context Skill Standard
(`workspace/standards/context-skill.md` in the getcolors workspace;
`github.com/getcolors/workspace`). In brief: a Context Skill is distilled
knowledge from a verified build — the traps, contracts, and acceptance
doctrine that separate a stack that runs from a deployment whose claims are
proven. It routes by symptom, states its provenance, and carries no copy of
anything a tested implementation owns.

Do not submit general documentation, a tutorial, a prompt library, or a
summary of upstream docs — knowledge that was not bought from a verified
build does not qualify. Do not submit a Package Skill (that is
`submit-package-skill`) or a workflow/process skill.

## Authorization boundary

Before changing files or using GitHub, identify:

- the public `owner/repository` and the Context Skill's path within it;
- the companion repository holding the tested implementation, if one exists;
- a short summary and symptom-oriented search keywords;
- whether the user authorizes creating a branch, commit, push, fork if
  needed, and pull request.

Do not infer publication authorization from permission to inspect a
repository. Never request, read, or copy provider credentials. Catalog
submission requires no cloud credentials and must not provision, converge, or
contact infrastructure providers — admission validates the artifacts
verification left behind, not the verification itself.

## Validate the source

For every proposed entry:

1. Read its complete `SKILL.md`, every file under `references/`, and
   `evals/`.
2. Run `skills-ref validate` on the skill directory — clone the source
   repository first; validation reads a local directory, not a URL. It must
   pass, including the 1024-character description cap and the
   name/directory match.
3. Verify the `description` is symptom-first: error strings, observed
   behaviours, and situations — not mechanism. If a fuller symptom index
   exists, it sits at the top of the body.
4. Verify provenance statements: the body states what its claims were
   verified against, and names source functions where it contradicts
   upstream documentation.
5. Verify a pinned version set exists with the rules that generated it.
6. Verify a symptom-indexed failure catalogue with verbatim error text.
7. Verify evals are shaped as a user in trouble, not as quiz questions.
8. Apply the no-second-copy rule: if a companion Package Skill exists, any
   `assets/` or working-file copies are disqualifying; without a companion,
   assets are allowed and must be flagged in the recipe.
9. Verify the companion repository resolves and holds the tested
   implementation the skill points at, when one is named.
10. Verify the load command shape is valid:

```sh
npx skills use <owner>/<repository>@<context-skill>
```

A successful source inspection is not a re-verification of the skill's
claims; their truth was bought by the build that produced them. Stop and
report concrete qualification failures rather than weakening the standard.

## Add the recipe

Work in `getcolors/colors-website`. Read its `CLAUDE.md` before editing.
Recipes live at `recipes/<name>.yml`; a Context Skill gets its own recipe
with `type: context`.

```yaml
type: context
name: Agent Network Single-Node
repository: getcolors/skills
summary: Verified traps, API contract, and acceptance doctrine for
  single-node NetBird Agent Network deployments.
keywords:
  - netbird
  - agent network
  - no viable challenge type found
  - isolation
companion: getcolors/agent-network
context-skills:
  - name: agent-network-single-node
    path: agent-network-single-node/SKILL.md
```

Recipe rules:

- Keep `summary` specific to what the knowledge covers, not the product's
  marketing description.
- Keywords carry the symptoms people will actually search — including any
  high-signal error strings trimmed from the description for the spec cap.
- Set `companion:` to the tested implementation's repository; omit it only
  when none exists. Flag shipped assets in the recipe when §3 of the
  standard permits them.
- Use `branch` only when the source branch is not `main`.
- Do not add `featured`; catalog maintainers control editorial featuring.
- Do not copy `SKILL.md` content or add generated artifacts.

## Verify and submit

From the website repository run:

```sh
pnpm typecheck
pnpm build
```

Both commands fetch the referenced public `SKILL.md` and validate recipe
metadata. Inspect the generated Context Skill route when practical.

A new recipe adds catalog routes whose social cards must exist in
`public/` — `pnpm build` fails on the `requireLocalImage` gate until they
do. Run `scripts/generate-og-image.py` (the setup block at its top
documents the one-off Python environment), then check `git status`:
exactly the new recipe's card(s) should appear, and they belong in the
submission commit. The generator is deterministic, so unrelated cards do
not change.

If authorized, create one focused commit — the recipe plus its generated
og card(s) — push it, and open a PR against
`getcolors/colors-website:main`. The PR body must include:

- the Context Skill Standard checklist with each item's result;
- source repository, skill path, and companion repository;
- the `skills-ref validate` result;
- the `npx skills use` load command;
- the generated og card(s) for the new routes;
- verification commands and results.

Do not merge the PR. Catalog maintainers decide admission. Return the PR URL
and a concise validation summary.
