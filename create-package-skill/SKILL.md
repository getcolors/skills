---
name: create-package-skill
description: Use when asked to create a getcolors Package Skill and a deployment that uses it, including desired-state configuration, provider credentials, GitHub repositories, provisioning, or end-to-end deployment.
---

# Create a Package Skill and Deployment

Act as the coding agent for the getcolors workspace. Create a new Package Skill and a deployment that uses it.

Follow all workspace and repository `CLAUDE.md` instructions. Treat each folder as an independent repository. Use the most relevant existing packages and deployments as architectural references, but do not blindly copy them.

## Mandatory three-phase workflow

### Phase 1 — conversation only

Your first response must ask for:

1. The Package Skill folder name, producing `<skill>/`.
2. The suffix for the deployment folder that uses the skill, producing `<skill>-<suffix>/`.

After receiving both values, treat `<skill>/` and `<skill>-<suffix>/` as the exact target folders. Do not infer or choose either value yourself.

Then discuss the intended behavior, requirements, naming, scope, acceptance criteria, deployment target, credentials, and authorization.

During this phase:

- Do not implement anything.
- Do not create, modify, or delete files.
- Do not run provisioning, deployment, Git, or other state-changing commands.
- Do not write a plan to disk.
- Do not present a detailed implementation plan unless I explicitly request one.
- Ask only the questions needed to remove ambiguity and establish authorization.
- Establish whether you are authorized to:
  - create repositories or folders;
  - commit and push changes;
  - update SHA pins and installed launcher copies;
  - provision paid cloud or provider resources;
  - perform a real deployment;
  - modify DNS or other external systems.
- Never request secrets in chat. Credentials must use the project’s established environment-variable and private-file conventions.

Remain in Phase 1 until I explicitly say something equivalent to:

“Proceed with credential setup and desired-state scaffolding.”

Discussion, approval of requirements, or a request for a plan does not by itself authorize file creation.

### Phase 2 — credentials setup and `colors.yml` desired state

After explicit authorization, create `<skill>-<suffix>/` and only these initial files:

- `colors.yml` containing the agreed non-secret desired state;
- `.gitignore` excluding `.envrc.private`, `.colors/`, and all other conventionally ignored local or generated files while explicitly allowing tracked dotfiles;
- `.envrc` containing the repository's standard non-secret direnv/devenv setup and sourcing `.envrc.private` when present;
- `.envrc.private`, ignored by Git, for the user to populate with credential environment variables.

Create `.gitignore` before `.envrc.private`. Follow the conventions of the closest deployment reference rather than inventing credential names or configuration structure. Never place secrets in `colors.yml`, `.envrc`, documentation, chat, or any tracked file, and never export `COLORS_PAR_PROFILE`.

After creating the four files, stop and tell the user to review the non-secret desired state in `colors.yml` and populate `.envrc.private` locally. Do not read, display, copy, validate, or otherwise expose the contents of `.envrc.private`. Do not create other implementation files, initialize or modify Git, provision resources, or begin deployment during this phase.

Remain in Phase 2 until the user explicitly says something equivalent to:

“Credentials and desired state are ready. Proceed with implementation and deployment.”

### Phase 3 — autonomous execution

After that explicit authorization, stop consulting me and execute autonomously until the package and deployment work end to end.

You must:

1. Inspect the workspace-level CLAUDE.md and the CLAUDE.md/README files of every relevant repository.
2. Perform all work directly without spawning subagents, delegating tasks, or creating subtasks.
3. Implement the package and deployment according to established getcolors conventions:
   - colors.yml is the editable deployment configuration;
   - secrets never enter tracked files;
   - .colors/ is generated and must not be edited or committed;
   - preserve prevent-destroy safeguards;
   - never export COLORS_PAR_PROFILE;
   - use working-tree overrides while developing across repository boundaries;
   - use real pushed Git SHAs for final pins—never invent or hand-edit SHAs;
   - keep installed launcher copies synchronized with Package Skill payloads.
4. Run all repository-specific tests, golden tests, launcher tests, build checks, and safe dry runs.
5. Inspect golden diffs rather than accepting them blindly.
6. Diagnose failures, revise the implementation, and repeat checks until they pass.
7. As each converge or gate failure is fixed, record its verbatim error text, what it turned out to mean, and the fix in an untracked session-notes file. Long sessions lose early errors to context summarization, and the optional distillation step needs this material intact — paraphrased symptoms do not route.
8. Deploy for real only within the authorization established during Phase 1.
9. Never bypass safety guards or expose credentials.
10. Do not perform destructive deletion unless it was separately and explicitly authorized.
11. Commit, push, create repositories, update pins, or incur cloud costs only if those actions were explicitly authorized during Phase 1.

Once Phase 3 begins, do not ask me routine questions or seek approval between steps. Make reasonable engineering decisions from repository conventions and evidence. If an unavoidable blocker exists—such as missing credentials, unavailable permissions, an external outage, or authorization that was never granted—do not guess or weaken safeguards. Stop safely and provide a concise blocker report stating:

- what succeeded;
- what remains;
- the exact blocker;
- the minimum external action needed.

## Definition of done

The task is complete only when:

- `<skill>/` is a functional Package Skill;
- `<skill>-<suffix>/` is a functional deployment using that skill;
- configuration validation reports all errors consistently;
- builds and dry runs work from a fresh checkout without credentials where project conventions require that;
- tests, golden checks, and launcher checks pass;
- generated files are reproducible;
- pins and launcher copies are correct;
- no secrets or generated .colors/ content are tracked;
- the authorized real deployment converges successfully;
- post-deployment health checks demonstrate that the deployed environment and its intended service are operational;
- relevant documentation accurately describes usage and recovery;
- both GitHub repositories exist in the `getcolors` organization and all authorized changes have been pushed.

## Optional catalog submission

Catalog publication is separate from creation and deployment. Do not publish automatically. After the definition of done is satisfied, mention this optional next step only if the user authorized making the Package Skill public:

```sh
npx skills use getcolors/skills@submit-package-skill
```

That Agent Skill validates the completed Package Skill against the catalog definition and opens a recipe PR. It is also the submission path for existing Package Skills, so do not duplicate its workflow here.

## Optional distillation

A completed, verified build is the qualifying input for a Context Skill —
the traps, converge failures, review findings, and acceptance doctrine the
build paid for, distilled per `workspace/standards/context-skill.md`. The
raw material decays when the session ends, so after the definition of done
is satisfied, offer this step while the evidence is still in context. The
Phase 3 session-notes file is the harvest input; keep it until distillation
is done or declined:

```sh
npx skills use getcolors/skills@create-context-skill
```

Distillation is optional and separate; do not fold it into the build.
