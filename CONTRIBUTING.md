# Contributing & Git Workflow

ClimbAI Coach uses a **two-trunk GitFlow**: a protected `master` that reflects what is
released, and a `dev` integration branch where everything is assembled and validated.

---

## 1. Branch model

| Branch | Lives | Cut from | Merges into | Protected |
|---|---|---|---|---|
| `master` | forever | — | — | ✅ |
| `dev` | forever | `master` | `master` (release) | ✅ |
| `feature/*` | days | `dev` | `dev` | — |
| `fix/*` | hours–days | `dev` | `dev` | — |
| `chore/*` | hours | `dev` | `dev` | — |
| `docs/*` `refactor/*` `perf/*` `test/*` | hours–days | `dev` | `dev` | — |
| `release/*` | days (optional) | `dev` | `master` **and** `dev` | — |
| `hotfix/*` | hours | `master` | `master` **and** `dev` | — |

```
master  ──●────────────────────●─────────────────●──────▶   tagged releases only
           \                  ↗ \               ↗
            \                /   \ hotfix/1.0.1/
             \              /     \           /
dev     ──────●──●──●──●──●─────────●──●──●──●────────▶     always staging-deployable
               ↖  ↖  ↖  ↖             ↖  ↖  ↖
        feature/…  fix/…  chore/…    feature/…
```

**The two rules that matter:**

1. **Nothing reaches `master` except through `dev`** — with one exception, `hotfix/*`.
2. **Every `hotfix/*` merges into `master` *and* back into `dev`.** A fix that lives only on
   `master` will be silently reverted by the next release. This is the single most common way
   GitFlow goes wrong.

### Why `dev` exists here

For this project specifically: mobile releases go through EAS review and cannot be rolled back
the way a server deploy can, and the training engine's arithmetic reaches athletes' fingers.
`dev` is where a change is proven against a staging database and a real EAS preview build
before it becomes irreversible.

---

## 2. Branch naming

```
<type>/<issue-number>-<short-kebab-description>
```

| Type | Use for | Example |
|---|---|---|
| `feature/` | new capability | `feature/42-session-player-timers` |
| `fix/` | bug in released or dev code | `fix/58-repeater-assistance-sign` |
| `chore/` | tooling, deps, config, CI | `chore/bump-expo-sdk-53` |
| `docs/` | documentation only | `docs/protocol-library-citations` |
| `refactor/` | behaviour-preserving change | `refactor/extract-context-assembler` |
| `perf/` | measurable performance work | `perf/calendar-virtualised-list` |
| `test/` | tests only | `test/progression-engine-edge-cases` |
| `release/` | stabilisation window | `release/1.2.0` |
| `hotfix/` | urgent production fix | `hotfix/1.1.1-load-clamp` |

The issue number is optional but strongly preferred — it makes `git log` navigable a year later.
Lowercase, hyphens, no underscores, no personal names (`feature/marco-stuff` tells nobody anything).

---

## 3. Commit messages — Conventional Commits

```
<type>(<scope>): <subject>

<body — why, not what>

<footer — BREAKING CHANGE:, Refs #42>
```

Types: `feat` `fix` `chore` `docs` `refactor` `perf` `test` `build` `ci` `revert`.
Scopes for this repo: `engine` `prompts` `contracts` `db` `api` `mobile` `ci` `docs`.

```
feat(engine): resolve sub-bodyweight repeater loads to pulley assistance

Repeaters at pct 0.72-0.85 routinely target below bodyweight. The resolver
was clamping the negative result to zero, silently prescribing full-bodyweight
hangs on an aerobic-capacity protocol.

Refs #58
```

This is not ceremony — it drives automated changelogs and the semver bump at release time
(`feat` → minor, `fix` → patch, `BREAKING CHANGE:` → major).

---

## 4. The loop

### Starting work

```bash
git checkout dev
git pull origin dev
git checkout -b feature/42-session-player-timers
```

Always branch from an up-to-date `dev`, never from another feature branch (unless you genuinely
need to stack — and then say so in the PR description).

### Staying current

Rebase **your own unshared branch** onto `dev` rather than merging `dev` into it. It keeps the
eventual PR diff honest — reviewers see your change, not a merge-noise sandwich.

```bash
git fetch origin
git rebase origin/dev
# resolve, then:
git push --force-with-lease
```

`--force-with-lease`, never bare `--force`: it refuses the push if someone else has touched the
branch since your last fetch.

**Once someone else has checked out your branch, stop rebasing it** — merge `dev` in instead.
Rewriting a branch another person is working on breaks their checkout.

### Opening the PR

- Target `dev`. Never open a PR against `master` unless it is a `hotfix/*` or a release.
- Keep it under ~400 changed lines where you can. Three reviewable PRs beat one unreviewable one.
- Fill in the template. "What could break?" is not optional.
- Mark it **Draft** while CI is still red — a red PR in the review queue costs everyone's attention.

### Merging into `dev`

**Squash merge.** One feature = one commit on `dev`. `dev`'s history stays linear and readable,
and reverting a feature is a single `git revert`. Edit the squash subject to a proper
Conventional Commit message — GitHub's default ("Merge pull request #12 from…") is useless.

Delete the branch after merge. Stale branches accumulate faster than anyone expects.

### Promoting `dev` → `master`

A **merge commit** (`--no-ff`), not a squash. The merge commit is the release boundary; squashing
destroys the link between `master` and the individual changes that made it up.

```bash
git checkout master && git pull origin master
git merge --no-ff dev -m "release: v1.2.0"
git tag -a v1.2.0 -m "v1.2.0"
git push origin master --follow-tags
```

In practice do this through a PR (`dev` → `master`) so the required checks run, then merge with
the **Create a merge commit** option.

---

## 5. Definition of Done for a `dev` → `master` promotion

`dev` is promoted when *all* of these hold — not when someone feels ready:

- [ ] CI green on `dev` head: typecheck, lint, unit tests, schema validation
- [ ] `packages/engine` test suite passing — **no exceptions, this computes loads**
- [ ] Prompt-eval fixture suite run; violations-per-block has not regressed vs. the last release
- [ ] DB migrations applied cleanly to a staging clone **and** verified reversible
- [ ] EAS preview build installed and smoke-tested on a real device (onboarding → generate → log a session)
- [ ] `CHANGELOG.md` updated
- [ ] Version bumped per semver
- [ ] No open `severity: blocker` issues tagged for this release

---

## 6. Versioning and tags

Semver, tagged **on `master` only**:

- `MAJOR` — breaking API or `TrainingBlock` schema change requiring client migration
- `MINOR` — new capability, backwards compatible
- `PATCH` — fixes

Two version streams worth tracking separately in tag messages, because they break differently:
- **`schema_version`** in `packages/contracts` — bumping it invalidates cached plans and older clients
- **prompt version** in `packages/prompts` — a doctrine change alters training output without any
  code change, so it must appear in the changelog even though no TypeScript moved

---

## 7. Hotfixes

```bash
git checkout master && git pull
git checkout -b hotfix/1.1.1-load-clamp
# fix, commit, PR → master
```

After it merges to `master` and is tagged, **immediately** merge `master` back into `dev`:

```bash
git checkout dev && git pull
git merge origin/master        # merge commit, do not squash
git push origin dev
```

Do not cherry-pick the fix into `dev` as a separate commit — you end up with two commits making
the same change and a guaranteed conflict at the next release. Merge the branch.

---

## 8. Branch protection (configure in GitHub → Settings → Branches)

### `master`
- Require a pull request before merging — **2 approvals**
- Require status checks to pass: `ci / typecheck`, `ci / test`, `ci / schema`, `ci / engine`
- Require branches to be up to date before merging
- Require conversation resolution
- Require signed commits *(recommended once the team is >1)*
- Require linear history: **off** (merge commits are the release boundary)
- Restrict who can push: release managers only
- Do not allow force pushes or deletions
- Include administrators

### `dev`
- Require a pull request before merging — **1 approval**
- Require status checks to pass: same set
- Require conversation resolution
- Require linear history: **on** (squash merges only)
- Allow only squash merging (repo setting: disable merge commits and rebase merging for PRs into `dev`)
- Do not allow force pushes or deletions

Set the repository's **default branch to `dev`** so every new PR targets it by default. This one
setting prevents most accidental PRs against `master`.

---

## 9. CI

Add `.github/workflows/ci.yml` with the following (kept out of this commit because pushing
workflow files needs elevated token scope — add it from your own account):

```yaml
name: ci
on:
  pull_request:
    branches: [dev, master]
  push:
    branches: [dev, master]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22, cache: pnpm }
      - run: pnpm install --frozen-lockfile
      - name: typecheck
        run: pnpm -r typecheck
      - name: lint
        run: pnpm -r lint
      - name: engine tests
        run: pnpm --filter @climbai/engine test
      - name: contract schema is valid + in sync with Zod
        run: pnpm --filter @climbai/contracts build && git diff --exit-code packages/contracts
      - name: prompt evals (fixture athletes)
        if: github.base_ref == 'master'
        run: pnpm eval:prompts --fixtures 40 --fail-on-regression
```

The prompt eval job runs only on `dev` → `master` because it costs real API money. Everything
else runs on every PR.

---

## 10. Database migrations across two trunks

`master` and `dev` share a database *lineage*, so migrations must be **expand/contract**:

1. **Expand** (ships with the feature) — add nullable columns, new tables, backfill. Old code
   still runs against the new schema.
2. **Migrate** — the feature writes to both shapes.
3. **Contract** (ships a release *later*) — drop the old column once no deployed client reads it.

Never ship a destructive migration in the same release as the code that stops needing the column.
If you have to roll `master` back one version, the previous code must still start.

---

## 11. Anti-patterns

- **Long-lived feature branches.** A branch open for three weeks is a merge conflict with a
  countdown timer. Break the work up or merge behind a feature flag.
- **Merging `dev` into `master` to "sync" outside a release.** `master` moves at release cadence,
  by design.
- **Cherry-picking a hotfix into `dev` instead of merging** (see §7).
- **`git push --force` on a shared branch.** Use `--force-with-lease`, and only on your own branch.
- **Squash-merging `dev` into `master`.** Destroys the release boundary.
- **Committing directly to `dev`.** Protection should make this impossible; if you find you can,
  the protection rules aren't applied.
- **A green PR nobody reviewed.** CI proves it runs, not that it's right — especially for
  anything in `packages/engine` or `packages/prompts`.
