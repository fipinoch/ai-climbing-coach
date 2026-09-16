# 7. Multi-Session Development Model

How this project is built by several Claude Code sessions working under one lead.

## Roles

| Role | Count | Responsibility |
|---|---|---|
| **Lead** | 1 (long-lived) | Owns the roadmap, writes assignments, spawns and tracks workers, arbitrates review disputes, keeps `dev` healthy. Does not write feature code. |
| **Builder** | 1 at a time | Takes one assignment, works on one branch, opens one PR into `dev`, responds to review findings until merged. |
| **Reviewer** | 1 per PR | Reads `CLAUDE.md` + `docs/06-review-standards.md`, reviews the PR, posts severity-labelled findings. Never pushes to the PR branch. |

**Builder and reviewer are always different sessions.** A session reviewing its own work has
already accepted every assumption in it — that is the whole reason for the split.

## Standing policy

Decided by the repository owner. Sessions follow these without re-litigating them.

| Question | Policy |
|---|---|
| **Who merges?** | **The human. Always.** No agent merges any PR, including chore and docs. The lead reports "PR #N: reviewed, CI green, N findings resolved — ready" and stops there. |
| **How are findings delivered?** | The reviewer posts **severity-labelled inline comments directly on the PR**, plus a summary verdict, and formally requests changes or approves. The PR thread is the complete record; the lead does not filter or relay findings. |
| **What does the lead do?** | **Orchestration only.** Writes assignments, spawns and tracks sessions, triages disputes, reports status. The lead does not write feature code — its context is reserved for tracking state across PRs, which is what degrades first in a long-running orchestration. |

Consequences worth being explicit about:

- A PR sits until the human merges it. Builders must not treat an approved PR as done-and-dusted
  and start the next task on top of it; the next assignment branches from `dev` after the merge.
- Because findings go straight to GitHub, a *wrong* finding is public and costs the author time.
  Reviewers verify before claiming — see `docs/06-review-standards.md` § Reviewer conduct.
- The lead never resolves a review thread it did not open.

## The loop

```
  Lead                     Builder session              Reviewer session
   │                            │                             │
   ├─ writes assignment ───────▶│                             │
   │                            ├─ branch from dev            │
   │                            ├─ implement + test           │
   │                            ├─ open PR → dev ─────────┐   │
   │◀── PR event wakes lead ────────────────────────────┘   │
   ├─ spawns reviewer ──────────────────────────────────────▶│
   │                            │                        ├─ reads standards
   │                            │                        ├─ reviews diff
   │                            │◀── findings posted ────┤
   │                            ├─ fixes, pushes         │
   │◀── PR event wakes lead ────┤                        │
   ├─ verifies CI + findings resolved                    │
   ├─ merges (or escalates to the human)                 │
   └─ next assignment
```

The handoff signal is **the pull request**, not a message between sessions. Worker sessions do not
reliably report back when they finish cleanly, so the lead subscribes to PR activity and is woken
by GitHub events. Anything that depends on inter-session chatter is fragile; anything anchored on
a PR event is not.

## Assignment format

Every builder is spawned with a self-contained brief. A worker session starts cold — it has none
of the lead's conversation context, only the repository.

```
TASK: <one sentence>
BRANCH: feature/<n>-<slug>   (cut from dev)
ROADMAP: docs/05-implementation-roadmap.md, Phase <n>
READ FIRST: CLAUDE.md, docs/<relevant>.md

SCOPE
  In:  <explicit list of files/packages>
  Out: <explicit list of what not to touch>

DONE WHEN
  - <testable criterion>
  - pnpm -r typecheck && pnpm -r lint && <package> tests green
  - PR opened against dev, template filled, Tier-1 checklist ticked if applicable

CONSTRAINTS
  - CLAUDE.md invariants apply. <Name the two or three most relevant explicitly.>
  - Do not add dependencies without asking.
  - Do not modify <adjacent package> — another session owns it.

IF BLOCKED
  Open the PR as draft describing the blocker. Do not guess at an invariant.
```

Naming the relevant invariants in the brief matters more than it looks — a cold session reading a
62-line `CLAUDE.md` will weight all ten equally unless told which two govern this task.

## Session hygiene

- **Tag every session** (`climbai:builder`, `climbai:reviewer`, `climbai:phase-1`) so the lead can
  find them with `list_sessions` after a context reset.
- **One assignment per session.** Do not reuse a builder session for the next task — its context is
  full of the last one, and stale assumptions leak into new work.
- **Archive on merge.** Finished sessions hold a container.
- **Parallelism is bounded by file ownership, not ambition.** Two builders may run concurrently only
  on packages that do not import each other. Phases 1 and 2 are a single chain of reasoning about
  correctness and should not be split across sessions.

## Escalation to the human

The lead escalates rather than deciding when:

- A finding disputes an invariant in `CLAUDE.md` — those change only with the human's agreement.
- Builder and reviewer disagree twice on the same finding.
- A change would alter prescribed training output (prompt doctrine, protocol parameters, clamp
  logic) — the human is the coach of record.
- Cost: an eval run, or spawning more than the agreed number of concurrent sessions.
- Anything touching `master`, tags, releases, or branch protection.

## What agents never do

- Merge their own PR.
- Push directly to `dev` or `master`.
- Approve a PR they contributed code to.
- Run `pnpm eval:prompts` (real API spend) without the human's go-ahead.
- Change `CLAUDE.md` invariants, `CONTRIBUTING.md`, or branch protection.
- Delete branches other than their own.
