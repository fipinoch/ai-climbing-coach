# ClimbAI Coach — working agreement

Read this before touching anything. It is short on purpose.

## What this system does

Generates personalised climbing training plans. **An LLM designs the block; deterministic
TypeScript computes every load an athlete actually lifts.** Read `README.md`, then
`docs/02-ai-engine.md` before changing anything in `packages/prompts` or `packages/engine`.

## Non-negotiable invariants

Violating one of these is a blocking review finding, no matter how clean the code is.

1. **The LLM never emits a kilogram.** Model output carries `{basis, pct}` or `{basis, grade_offset}`.
   All kg/mm resolution happens in `packages/engine`. If you find yourself parsing a load out of
   model output, stop.
2. **Clamp order in load resolution is fixed:** protocol range → injury clamp → unverified-baseline
   clamp → absolute ceiling → equipment rounding. Reordering changes what an athlete lifts.
3. **Loads round DOWN** to the athlete's plate increment. Never up, never nearest.
4. **Negative (assistance) load is only ever emitted to an athlete with a pulley.**
5. **The protocol library (`packages/engine/protocols.ts`) is the single source.** Both the prompt
   builder and the validator read it. Never hand-copy protocol parameters into a prompt string.
6. **Every rule stated in a prompt has a counterpart in `validate.ts`.** A prompt rule you do not
   also validate in code is a suggestion, not a constraint.
7. **Pain and soreness are separate fields and separate questions.** Never collapse them.
8. **Plans are immutable versions.** Adjustments INSERT a new `plan_versions` row. Never UPDATE a plan.
9. **Migrations are expand/contract and reversible.** The previous release's code must still boot
   against the new schema.
10. **No athlete identity in an LLM payload.** No name, no email, no auth id. Age band, not birth date.

## Commands

```bash
pnpm install
pnpm -r typecheck            # must pass before any push
pnpm -r lint
pnpm --filter @climbai/engine test
pnpm generate --athlete fixtures/<name>.json   # headless block generation
pnpm eval:prompts            # costs real API credit — ask before running
```

## Conventions

- Branches, commits, merge strategy, releases: **`CONTRIBUTING.md`**. Follow it exactly.
- Work branches from `dev`. PRs target `dev`. Never push directly to `dev` or `master`.
- Conventional Commits, scopes: `engine` `prompts` `contracts` `db` `api` `mobile` `ci` `docs`.
- TypeScript strict. No `any`. No non-null assertion on anything that came from outside the
  process (model output, DB rows, network) — narrow it.
- Tests live beside the code. Invariants get property tests (fast-check), not just examples.

## Scope discipline

Do the task in the issue or the assignment. If you find an unrelated problem, note it in the PR
description under "Found along the way" — do not fix it in the same PR. A PR that grew a second
purpose gets sent back.

## Ask, don't guess

Stop and ask the lead session if: a change would alter prescribed training output, an invariant
above seems wrong for your case, the assignment conflicts with `CONTRIBUTING.md`, or you need a
dependency that is not already in the lockfile.
