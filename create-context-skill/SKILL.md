---
name: create-context-skill
description: Distill a completed, verified build into a Colors Context Skill conforming to the Context Skill Standard - five required artifacts, symptom-first routing, no working-file copies. Use at the end of a build whose acceptance gates passed, when the user says to distill the lessons, capture what the build learned, or turn converge failures into a skill - or to migrate an existing knowledge skill with assets into conforming shape.
---

# Create a Context Skill

Distill a verified build into a Context Skill: the traps, contracts, and
acceptance doctrine that separate a stack that runs from a deployment whose
claims are proven. The canonical definition of the output is the Context
Skill Standard (`workspace/standards/context-skill.md` in the getcolors
workspace; `github.com/getcolors/workspace`); the reference implementation
is `agent-network-single-node`.

**The input is a completed, verified build — without one, there is nothing
to create.** A Context Skill is knowledge bought from converging against the
real platform. Do not author one from research, upstream documentation, or
transcripts alone: that produces the well-written README the standard's
qualifying definition rejects. If the build has not happened yet, run it
first (`create-package-skill` governs that); come back here when the gates
pass.

## When to run

The best moment is the end of the build session, while the raw material is
still in context: verbatim converge failures, review-round findings and
their dispositions, deviations with their evidence, the pinned version set,
and the source functions that were read when the docs were wrong. That
material decays the moment the session ends; reconstructing it later from
git history loses the verbatim error text that makes routing work.

The second mode is **migration**: an existing knowledge skill that predates
the standard, typically carrying `assets/` copies of working files. The
build evidence then comes from the skill's own body, its repository history,
and the companion package that now owns the tested implementation.

## Phase 1 — Harvest

Collect, verbatim and with provenance, before writing anything:

- every converge or gate failure: the exact error text, what it turned out
  to mean, and the fix — paraphrased symptoms do not route;
- every adversarial-review or inspection finding that survived, with its
  disposition;
- every deviation from the reviewed plan, with the evidence that forced it;
- the pinned version set and the rules that generated it;
- each place the docs and the source disagreed, naming the function that
  was read;
- the acceptance gates: what each one checks, and any gate whose passing
  turned out to mean the opposite of what it claimed.

Label anything not actually verified against the running deployment. The
skill may carry such a claim only if it says so.

## Phase 2 — Structure

The body carries the *why*: topology, doctrine, the discoveries the docs
will not give, each claim traceable to Phase 1 evidence. Bulk reference
material moves to `references/` — by convention `pins.md` (the version set
and its generation rules), `failure-catalogue.md` (symptom-indexed, verbatim
error text, searchable by the string on the reader's screen), the API or
protocol contract as the source defines it, and the acceptance doctrine.
Keep `SKILL.md` under 500 lines; agents load references on demand.

Apply the no-second-copy rule as you go: the skill carries **no copies of
anything a tested implementation owns**. Name the companion repository in
the body and point at its files; do not reproduce them. In migration mode
this is the main work, and ownership is not binary — compare each `assets/`
file with the companion's sibling before deciding:

- **Identical** (allowing comment and templating-delimiter noise): delete
  the copy and point at the companion path.
- **Diverged**: normalize the pair — strip comments, unify templating
  delimiters — and diff, then classify every delta. The companion being
  ahead is fine: drop the copy. A skill-side improvement that was
  *verified* moves upstream first, through the companion's own tests,
  golden fixtures, and pin flow, before the copy is deleted — deleting it
  first destroys the only record of the fix. Reasoning that lived only in
  the copy's comments survives as prose in the body or references.
- **Not owned by the companion at all**: the file moves there first, behind
  that package's own tests.

`scripts/` go with the assets, operational ones included: a deleted
script's checks survive as a prose checklist in the references, tied to
the failure-catalogue entries they guard, so the knowledge keeps working
after the file is gone.

## Phase 3 — Route

Write the frontmatter `description` symptom-first: error strings, observed
behaviours, and situations — not mechanism. The Agent Skills spec caps it at
1024 characters; keep the highest-signal symptoms in the description and put
the full symptom index at the top of the body. Draft the symptom-oriented
keywords now, while the failures are fresh — the catalog recipe will need
them, including any error strings the cap forced out of the description.

In migration mode, measure the inherited description against the cap before
restructuring: trimming an over-cap description and moving the full index
into the body reshapes the skill, so find that out early, not at
validation.

## Phase 4 — Prove

- Write `evals/` prompts shaped as a user in trouble: the support message
  someone would actually send, drawn from the real failure moments — testing
  routing and diagnosis together. Evals are the category's regression net.
- Run `npx skills-ref validate <skill-directory>`; it must pass, including
  the description cap and the name/directory match.
- Re-read the body against Phase 1: every claim either names what verified
  it or says it is unverified. Remove anything that does neither.
- In migration mode there is no Phase 1 harvest to re-read against; instead
  re-verify every dated or status claim against what the companion and its
  deployments have done since the skill was written. A "schema-checked, not
  yet converged" note may have been superseded by a production deployment —
  a migrated skill that repeats it is lying in the safe direction, which is
  still lying.

## Phase 5 — Hand off

The skill lives in the `getcolors/skills` repository beside its siblings.
Committing and pushing require explicit authorization, as everywhere in this
workspace. Catalog admission is a separate step with its own skill —
`submit-context-skill` — and its own authorization boundary; do not open the
catalog PR from here.

## Boundaries

- Never invent, soften, or generalize a claim beyond what the build proved.
  A Context Skill that guesses is worse than no skill: agents read it as the
  reference.
- Never copy working files from the companion, whatever the convenience.
- Distillation needs no cloud credentials and must not provision, converge,
  or contact infrastructure providers. If a claim needs re-verification, say
  so in the skill rather than re-running infrastructure from here.
- On a later pin bump the skill decays per the standard's §6; note in
  `pins.md` any claim with a known retest condition.
