## What

<!-- One or two sentences. What does this change do? -->

## Why

<!-- The problem, or a link to the issue. Refs #___ -->

## How

<!-- Notable implementation decisions a reviewer shouldn't have to reverse-engineer. -->

## What could break

<!-- Required. Blast radius, edge cases, and what you did to rule them out.
     "Nothing" is an acceptable answer only if you've actually thought about it. -->

## Checklist

- [ ] Targets `dev` (or is a `hotfix/*` / release PR to `master`)
- [ ] Branch name and commits follow the conventions in CONTRIBUTING.md
- [ ] CI is green
- [ ] Tests added or updated for the changed behaviour
- [ ] Docs updated if behaviour or contracts changed

## Safety-critical areas

<!-- Tick anything this PR touches. Each one requires an extra reviewer. -->

- [ ] `packages/engine` — computes loads that reach an athlete's fingers
- [ ] `packages/prompts` — changes training output with no code change; note the version bump
- [ ] `packages/contracts` — schema changes invalidate cached plans and older clients
- [ ] `db/` migrations — confirm expand/contract and reversibility
- [ ] Injury / pain handling or any safety clamp
