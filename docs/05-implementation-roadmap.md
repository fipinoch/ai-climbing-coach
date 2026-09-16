# 5. Implementation Roadmap

Estimates assume **one full-time developer**. Halve the wall-clock with two, but Phases 1–2 are
hard to parallelise — they're a single chain of reasoning about correctness.

## The sequencing principle

> **Build the risky spine headless, before there is any UI or database to hide behind.**

Most of this application is conventional: a calendar, forms, charts, an offline queue. Exactly
one part is novel and can fail in ways that matter — the chain from athlete data through the
model to a number an athlete loads onto their fingers. That chain is also the cheapest thing in
the project to test, because it is pure functions plus one API call.

So the order is deliberately inverted from the usual "scaffold the app, then fill it in":

```
engine + contracts  →  generation pipeline  →  API + DB  →  mobile  →  adjustments  →  polish
   (pure, no I/O)       (CLI harness only)
   ▲ correctness is cheap here             ▲ prompt iteration is 30 seconds per loop here
```

If you build the API first, every prompt iteration costs a server restart and a database
round-trip. At the CLI you can run fifty variations in an afternoon.

---

## Phase 0 — Foundations · ~2 days

**Goal:** `dev` exists, CI is real, one command runs everything.

- Bootstrap `master` and `dev`; set `dev` as the default branch; apply the branch protection
  rules from CONTRIBUTING.md §8.
- pnpm workspaces + Turborepo; shared `tsconfig.base.json`, ESLint (flat config), Prettier, Vitest.
- Package skeletons: `@climbai/contracts`, `@climbai/engine`, `@climbai/prompts`.
- Uncomment the `app` job in `.github/workflows/ci.yml` once `package.json` exists.
- `.env.example`, secret handling, `commitlint` for Conventional Commits.

**Done when:** a trivial PR into `dev` runs typecheck + lint + tests green in CI.

**PRs:** `chore/1-monorepo-scaffold`, `chore/2-ci-and-commit-hooks`

---

## Phase 1 — The safety core · ~1 week

**Goal:** every number the product will ever produce is computed by tested, pure code.

This is the highest-leverage week in the project. No network, no database, no framework.

### `@climbai/contracts`
- Zod schemas as the source of truth: `TrainingBlock`, `BlockRevision`, `PlanContext`, `DeviationReport`.
- `pnpm build` emits `training-block.schema.json` from Zod; CI fails on drift
  (`git diff --exit-code`) so the committed schema can never lie about the types.
- `schema_version` constant + a documented bump policy.

### `@climbai/engine`
- `grades.ts` — V-scale ⇄ Font ⇄ French ⇄ YDS ⇄ UIAA → a single integer ordinal. Table-driven,
  with the conversion table as data and a test per boundary. This is fiddlier than it looks;
  do it once, properly, behind a tested API.
- `protocols.ts` — **the protocol library as data**, not prose. Read by both the prompt builder
  and the validator, so the rules the model is told and the rules it is checked against cannot
  drift apart. This single file is the reason the doctrine stays honest.
- `progression.ts` — already drafted: load resolution, clamp ordering, Epley, autoregulation,
  ACWR. Complete it and test it hard.
- `validate.ts` — the `Violation` union from §2.6: clustering matrix, within-session ordering,
  recovery gaps, weekly caps by training age, equipment, contraindications, intensity ranges,
  availability, taper windows.

### Testing posture
Unit tests for the tables; **property tests (fast-check) for the invariants**, because those
are the statements you actually care about:

- a resolved load is never above `protocol.maxPct × TL_max`, for any input
- a resolved load is never above an active injury clamp
- a resolved added weight is always an exact multiple of the athlete's increment
- a negative (assistance) load is never emitted to an athlete with no pulley
- `autoregulate()` never returns `progress` for any input with `painFlag` or RPE ≥ 9
- validating a block, applying no changes, and re-validating is idempotent

**Done when:** `pnpm --filter @climbai/engine test` is green, coverage on `progression.ts` and
`validate.ts` is ~100%, and `pnpm engine:resolve --fixture advanced-male-72kg` prints a sane
table of loads you can hand to a coach for a sanity check.

**PRs:** `feature/3-contracts-zod`, `feature/4-engine-grades`, `feature/5-engine-protocol-library`, `feature/6-engine-progression`, `feature/7-engine-validator`

---

## Phase 2 — Generation pipeline, headless · ~1.5 weeks

**Goal:** a command that turns an athlete JSON file into a validated training block. No server.

- `packages/prompts` — assemble Segments A–E, with the protocol library **rendered from
  `protocols.ts`** rather than hand-maintained. Content-hash the result; export the hash.
- `apps/cli` — `pnpm generate --athlete fixtures/xyz.json [--model …] [--effort …]`, printing
  the block as a readable week-by-week table, the violation list, token counts, cache hit rate
  and cost.
- LLM client: `messages.parse()` with `zodOutputFormat`, cached system block, the two-attempt
  repair loop, and `deterministicFallbackBlock()`.
- **The fallback template is not optional and not last.** Build it in this phase. It is what
  stands between a model outage and an athlete with an empty week.
- Eval harness: ~40 fixture athletes spanning the awkward cases — beginner with no equipment,
  advanced with a full board, post-pulley-injury, two-days-a-week parent, pre-trip taper,
  estimated baselines, stale baselines, conflicting constraints.
  `pnpm eval:prompts` reports schema pass rate, violations per block, repair rate, cost, latency.

**Done when:** ≥ 95% first-attempt schema pass, mean violations-per-block < 0.3 across fixtures,
measured cost per block, and a human coach has reviewed ten generated blocks and signed off.

**That last gate is the real one.** Everything downstream assumes the blocks are good.

**PRs:** `feature/8-prompt-assembly`, `feature/9-llm-client-and-repair`, `feature/10-fallback-template`, `feature/11-eval-harness`

---

## Phase 3 — Persistence and API · ~1.5 weeks

**Goal:** the pipeline runs for a real user against a real database.

- Drizzle migrations generated from `db/schema.sql`; seed script for `equipment_catalog` and
  `assessment_protocols`.
- `contextAssembler.ts` — SQL → `PlanContext`, from views only, deterministic key ordering,
  token-budget assertion (≤ 2 500) in a test.
- `derivedMetrics.ts` — recompute on assessment insert and bodyweight change.
- Fastify: auth middleware → Postgres RLS session variable; `POST /v1/plans` (202 + job),
  BullMQ worker, `GET /v1/jobs/:id/stream` (SSE), `GET /v1/plans/active`,
  `POST /v1/sessions/:id/log` (idempotent on `client_uuid`).
- `llm_requests` logging wired into every call.

**Done when:** a curl script runs onboarding → generate → poll → fetch plan → log a session,
end to end, against a real database, and the generated plan is identical to what the CLI
produced for the same fixture.

**PRs:** `feature/12-db-migrations`, `feature/13-context-assembler`, `feature/14-api-plan-generation`, `feature/15-api-logging`

---

## Phase 4 — Mobile vertical slice · ~2 weeks

**Goal:** one athlete can complete the full loop on a real phone.

Build **only** the spine: onboarding (6 steps) → generating screen with SSE progress → Today →
session player → debrief. Deliberately deferred: month calendar, analytics, coach chat, swaps.

- Expo + expo-router + TanStack Query; types imported from `@climbai/contracts`.
- Session player with protocol-aware timers on the UI thread (Reanimated) — the 7:3 repeater
  clock is the hardest widget in the app; build it early and test it on a real device, because
  timer drift under JS load will not show up in the simulator.
- Offline write queue (expo-sqlite) with `client_uuid` idempotency, sync on reconnect.
- Tier-0 in-session autoregulation (client-side, no network).

**Done when:** an EAS preview build installs on a phone, and someone completes onboarding and
logs a real hangboard session in a gym, offline, without help.

**PRs:** `feature/16-onboarding-flow`, `feature/17-today-screen`, `feature/18-session-player`, `feature/19-offline-queue`

---

## Phase 5 — The adjustment loop · ~1 week

**Goal:** the thing that makes this a coach rather than a plan generator.

- Tier 1 rules engine (deterministic, already in `progression.ts`) wired to the debrief.
- Tier 3 safety responses — hard-coded, never model-mediated.
- Tier 2: `system-revise.md`, the `BlockRevision` op types, patch application to a working copy,
  **re-validation of the patched block**, the diff UI, accept/decline, atomic new `plan_versions` row.
- Rate limiting: one Tier-2 proposal per 48 h.

**Done when:** logging RPE 9 twice on the same stimulus produces a reviewed, accepted adjustment
that correctly rewrites only future sessions, and declining it is recorded and changes nothing.

**PRs:** `feature/20-tier1-autoregulation`, `feature/21-safety-responses`, `feature/22-ai-revision`, `feature/23-adjustment-diff-ui`

---

## Phase 6 — Completion · ~2 weeks

Calendar week/month views with gesture-level constraint feedback · Progress analytics (four
sections) · Coach Q&A (read-only, cheaper model) · Substitutions · Accessibility pass ·
Onboarding polish · `v1.0.0` release through `dev` → `master`.

---

## Risk register

| Risk | Likelihood | Mitigation | Phase |
|---|---|---|---|
| **Generated blocks are plausible but not actually good** | High | Eval harness + human coach sign-off gate *before* any UI exists | 2 |
| Beginners with estimated baselines get silly prescriptions | High | Conservative clamp (≤ 0.85), assessment week, explicit UI honesty; fixture coverage | 1–2 |
| Grade conversion edge cases (V-scale ⇄ Font boundaries) | Medium | Table-driven with a test per boundary; never parse grades outside `grades.ts` | 1 |
| Timer drift in the session player under JS load | Medium | Reanimated UI-thread timers; test on a low-end physical device early | 4 |
| Offline sync conflicts on re-connect | Medium | `client_uuid` idempotency; logs are append-only, never updated | 3–4 |
| LLM cost drift as usage grows | Low | `llm_requests` cost logging from day one; Tier-1 handles most adjustments without a call | 2–3 |
| Model or API outage at generation time | Low | Deterministic fallback block, built in Phase 2 not as an afterthought | 2 |

---

## What I would deliberately *not* build yet

- Social, sharing, leaderboards
- Multi-coach / team accounts
- Wearable or HRV integration — readiness is three taps and that's enough signal for v1
- Video form analysis
- Web app beyond what Expo Web gives free
- Payments — until the eval gate in Phase 2 passes, there is nothing worth charging for

---

## First week, concretely

| Day | Work |
|---|---|
| 1 | Branch bootstrap, protection rules, monorepo scaffold, CI green on a trivial PR |
| 2 | `@climbai/contracts`: Zod schemas + JSON Schema generation + drift check |
| 3 | `grades.ts` with full conversion tables and boundary tests |
| 4 | `protocols.ts` — library as data; wire `progression.ts` to read from it |
| 5 | `validate.ts` — clustering, ordering, gaps, caps |
| 6–7 | Property tests for every invariant; `engine:resolve` CLI; review the output tables with a coach |

At the end of week one you have no application and no UI — and the part that can hurt someone
is provably correct. That is the right trade.
