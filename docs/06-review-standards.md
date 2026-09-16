# 6. Code Review Standards

The rubric a reviewing session applies to every PR into `dev`. It exists as a repo artifact so
that review is reproducible: the same PR reviewed twice gets the same findings, and the standard
survives any individual session's context.

Reviewers: read this file and `CLAUDE.md` before reading the diff.

---

## Severity model

Every finding carries exactly one severity. Reviewers must not leave severity to the reader.

| Severity | Meaning | Effect |
|---|---|---|
| 🔴 **Blocking** | Correctness, safety, or an invariant violation | Request changes. Cannot merge. |
| 🟡 **Required** | Convention, missing test, unclear contract | Must be resolved or explicitly waived by the author with a reason |
| 🟣 **Optional** | Nit, preference, future cleanup | Author may close without acting. Never blocks. |

A reviewer who marks everything Blocking is as useless as one who marks nothing. If a PR has
more than five Blocking findings, stop reviewing and say the PR needs rework — line-by-line
review of a fundamentally wrong approach wastes everyone's time.

---

## Tier 1 — Safety-critical review

Applies to any diff touching `packages/engine`, `packages/prompts`, `packages/contracts`, `db/`,
or anything handling injuries, pain, or load. **These paths require a second reviewer.**

### The invariant checklist

Walk it explicitly. Say in the review which items you checked.

- [ ] **No kilograms from the model.** No load parsed out of LLM output; no arithmetic on athlete
      loads outside `packages/engine`.
- [ ] **Clamp ordering** unchanged: protocol → injury → unverified → absolute → rounding.
      If the diff reorders these, it is Blocking until proven otherwise with a test.
- [ ] **Rounding direction** is down, to the athlete's own increment — not to 0.5 kg, not to nearest.
- [ ] **Assistance loads** guarded by a pulley check.
- [ ] **Protocol parameters** read from `protocols.ts`, never duplicated into a prompt string or a
      validator branch.
- [ ] **New prompt rule ⇒ new validator rule.** A PR adding a constraint to a prompt without a
      matching `Violation` case is incomplete.
- [ ] **New protocol ⇒ gates.** `equipment_required`, `contraindications`, `min_training_age_years`
      and an intensity range are all populated.
- [ ] **Injury and pain paths** are hard-coded, never routed through the model.
- [ ] **Schema drift:** committed `training-block.schema.json` regenerates identically from Zod.
- [ ] **Prompt or doctrine change:** version bumped, `CHANGELOG.md` entry written, and eval deltas
      reported in the PR description. A prompt-only PR changes what athletes are told to lift; it
      is a behaviour change with no code diff and must be reviewed as one.
- [ ] **Migration:** expand/contract, reversible, and the previous release's code still boots.

### Test expectations for these paths

- Invariants get **property tests** (fast-check), not three examples. "For all athletes and all
  valid pcts, the resolved load is a multiple of the increment and ≤ the protocol maximum."
- Every clamp has a test that proves it binds — a clamp with no failing-input test is untested.
- Every `Violation` code has a fixture block that triggers it and one that does not.
- A bug fix ships with a test that fails on the parent commit. Ask for it if it's missing.

---

## Tier 2 — General review

### Correctness
- Error handling distinguishes retryable (429, 5xx, network) from non-retryable (400, 404).
  A single broad catch around an API call is a Required finding.
- Anything crossing a process boundary — model output, DB row, HTTP body, SQLite row — is
  narrowed, not asserted. `parsed_output!` is Blocking; guard it.
- Async: no floating promises, no unawaited writes before a response returns.
- Idempotency on every write path reachable from the offline queue.

### Contracts and types
- No `any`. `unknown` + narrowing is fine.
- Types imported from `@climbai/contracts`, not redeclared locally.
- Public functions in `packages/engine` are documented with their units. `kg`, `mm`, `seconds`,
  `fraction-not-percent` — unit confusion is the most likely way this system hurts someone.

### Data and privacy
- No athlete identity in an LLM payload.
- No secrets in code, logs, or test fixtures. No API key outside the server process.
- `llm_requests` logging does not store raw athlete payloads beyond what debugging needs.

### Scope and structure
- The PR does one thing. A second purpose is a Required finding: split it.
- Diff ≤ ~400 lines where the work allows. Larger needs a reason in the description.
- No commented-out code, no `console.log`, no `TODO` without an issue reference.

### What NOT to comment on
Formatting, import order, quote style, line length. Prettier and ESLint own those — if they pass,
the reviewer is silent. Reviewers who spend findings on style get ignored on the findings that matter.

---

## Review output format

Post findings as **inline PR comments** on the relevant line, each prefixed with its severity
emoji and a one-line claim, then the reasoning:

```
🔴 Blocking — assistance load emitted without a pulley check

resolveHangLoad returns a negative addedKg here when pct lands below bodyweight,
but `equipment.hasPulley` is never consulted on this branch. An athlete with a
plain hangboard gets "-6kg" in the session player with no way to apply it.

Suggest reusing the guard from the sub-bodyweight branch above.
```

Then a summary comment with: the verdict, a count by severity, and the Tier-1 checklist items
verified. Verdicts:

- **Approve** — no Blocking, no unresolved Required.
- **Approve with comments** — Optional findings only.
- **Request changes** — any Blocking, or Required findings the author must address.
- **Needs rework** — the approach is wrong; line-by-line review deferred. Say why in two paragraphs
  and propose the alternative.

## Reviewer conduct

- Review the diff, not the author. No "you forgot"; write "this path doesn't check X".
- Be concrete. A finding without a failure scenario — specific inputs producing a specific wrong
  output — is a suspicion, and should be phrased as a question, not a finding.
- Verify before claiming. Read the surrounding file; the guard you think is missing is often
  three lines up. A confident wrong finding costs more trust than a missed nit.
- If you would need to rewrite the PR to express your objection, that is **Needs rework**, not
  forty inline comments.
- Reviewers do not push code to the PR branch. Findings go in comments; the author fixes them.
