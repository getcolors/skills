---
name: submit-package-skill
description: Submit an existing Colors Package Skill to the getcolors.ai Package Skills Catalog by validating it, adding a catalog recipe, and opening a pull request.
---

# Submit a Package Skill

Submit an existing Package Skill to the PR-curated catalog at `https://www.getcolors.ai/skills`. The catalog provides discoverability only: GitHub remains the source, `npx skills` remains the installer, and the catalog does not build or host artifacts.

## Qualifying definition

A Package Skill is a deterministic infrastructure and platform automation module built for AI coding agents using the Colors SDK (available in TypeScript/Bun, Clojure/Babashka, or Python/uv). It provisions and manages production resources—such as Kubernetes clusters, databases, dev machines, or personal PaaS environments—by reading a non-secret desired state file (`colors.yml`), enforcing mandatory dry-run boundaries before contacting live providers, maintaining strict credential indirection through environment variables (`COLORS_PAR_*`), and managing resource lifecycles through execution graphs (DAGs).

Do not submit an ordinary Agent Skill, shell-script collection, prompt library, or package that fails any part of this definition.

## Authorization boundary

Before changing files or using GitHub, identify:

- the public `owner/repository`;
- every Package Skill name, `SKILL.md` path, and Colors runtime;
- a short product summary and infrastructure-oriented search keywords;
- whether the user authorizes creating a branch, commit, push, fork if needed, and pull request.

Do not infer publication authorization from permission to inspect a repository. Never request, read, or copy provider credentials. Catalog submission requires no cloud credentials and must not provision or contact infrastructure providers.

## Validate the source

For every proposed entry:

1. Read its complete `SKILL.md` and repository instructions.
2. Verify YAML frontmatter declares the same Package Skill name and a useful description.
3. Verify the name starts with `package-`.
4. Verify the implementation uses red, green, or blue and pins the Colors library to a real Git commit.
5. Verify it reads non-secret desired state from `colors.yml`.
6. Verify build and mandatory dry-run paths finish before live provider operations.
7. Verify provider credentials are indirected through `COLORS_PAR_*`, apart from explicitly documented ambient SDK credential chains.
8. Verify lifecycle operations are execution graphs (DAGs), including guarded deletion where deletion exists.
9. Verify no secret or generated `.colors/` content is tracked.
10. Verify the existing command shape is valid:

```sh
npx skills add https://github.com/<owner>/<repository> --skill <package-skill>
```

A successful source inspection is not a security audit. Stop and report concrete qualification failures rather than weakening the definition.

## Add the recipe

Work in `getcolors/colors-website`. Read its `CLAUDE.md` before editing. Recipes live at `recipes/<product>.yml`; use one recipe for a product and group interchangeable runtime variants.

```yaml
name: Example
repository: owner/repository
summary: Operate the production resource this Package Skill manages.
keywords:
  - platform
  - provider
  - production resource

package-skills:
  - name: package-example-green
    path: skills/package-example-green/SKILL.md
    runtime: green
```

Recipe rules:

- Keep `summary` concise and specific to what the Package Skill operates.
- Add keywords people will actually search for: platform, provider, resource, and common product names.
- Use `branch` only when the source branch is not `main`.
- Do not add `featured`; catalog maintainers control editorial featuring.
- Do not copy `SKILL.md` or add generated artifacts.
- Do not add editorial content from skills.sh. The site uses skills.sh only for installation counts.

## Verify and submit

From the website repository run:

```sh
pnpm typecheck
pnpm build
```

Both commands fetch the referenced public `SKILL.md` and validate recipe metadata. Inspect the generated catalog, source, and Package Skill routes when practical.

A new recipe adds catalog routes whose social cards must exist in `public/` — `pnpm build` fails on the `requireLocalImage` gate until they do. Run `scripts/generate-og-image.py` (the setup block at its top documents the one-off Python environment), then check `git status`: exactly the new recipe's card(s) should appear, and they belong in the submission commit. The generator is deterministic, so unrelated cards do not change.

If authorized, create one focused commit — the recipe plus its generated og card(s) — push it, and open a PR against `getcolors/colors-website:main`. The PR body must include:

- the Package Skill definition checklist;
- source repository and Package Skill paths;
- runtimes;
- the existing `npx skills` installation commands;
- the generated og card(s) for the new routes;
- verification commands and results;
- any missing skills.sh installation count, which is allowed and must not block submission.

Do not merge the PR. Catalog maintainers decide admission. Return the PR URL and a concise validation summary.
