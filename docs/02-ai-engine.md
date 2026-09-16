# 2. The Sports-Science AI Engine

The "AI engine" is four cooperating parts, only one of which is a model:

```
 Context Assembler  →  System Prompt (doctrine)  →  LLM  →  Validator  →  Load Resolver
 (SQL → payload)       (versioned, cached)         (JSON)   (rules)      (% → kg)
```

## 2.1 Prompt architecture

| Segment | Volatility | Cacheable | Contents |
|---|---|---|---|
| **A. Role + safety charter** | frozen | ✅ | scope, refusal rules, medical boundary |
| **B. Physiological model** | frozen | ✅ | stimulus taxonomy, clustering matrix, recovery matrix |
| **C. Protocol library** | ~monthly | ✅ | Eva López MaxHangs, Lattice 7:3, 4×4s, etc. — exact parameters |
| **D. Progression doctrine** | ~monthly | ✅ | overload rules, autoregulation table, deload triggers |
| **E. Output contract** | on schema change | ✅ | field semantics the JSON Schema can't express |
| **F. Athlete payload** | every request | ❌ | profile, assessments, equipment, injuries, logs, deviations |

A–E form one byte-identical system block with the cache breakpoint at its end; F goes in the user message. Segment order is deliberate: everything stable first, so the prefix hashes identically across all users.

The full text lives in [`packages/prompts/system-coach.md`](../packages/prompts/system-coach.md) and is content-hashed; the hash is stored on every `plan_versions` row so you can answer "which doctrine produced this block?" a year later.

## 2.2 The clustering model (Segment B)

The single most important thing the prompt must enforce: **one primary stimulus per session.** Mixing maximal recruitment work with high-volume anaerobic work in the same session degrades both — the strength work is performed fatigued (insufficient recruitment) and the capacity work is performed pre-exhausted (wrong metabolic profile), and the combined systemic cost lands roughly at the sum while the adaptive signal lands below either.

**Stimulus taxonomy** (every prescribed item carries exactly one):

| Code | Target | Character |
|---|---|---|
| `MAX_STRENGTH_FINGER` | maximal recruitment, tendon/connective loading | ≤10 s efforts, ≥3 min rest, non-fatiguing volume |
| `MAX_STRENGTH_GENERAL` | pulling/core 1–5RM | heavy, low rep |
| `POWER` | RFD, contact strength, campus, limit boulder | fresh CNS, full recovery between efforts |
| `ANAEROBIC_CAPACITY` | "power endurance" — 4×4s, boulder circuits, intervals | high lactate, high systemic cost |
| `AEROBIC_CAPACITY` | repeaters, ARC, easy-mileage circuits | sub-pump, high volume, low CNS cost |
| `SKILL` | movement, footwork, route reading | fresh but low physical cost |
| `ACCESSORY` | antagonist, shoulder, hip, rotator health | low intensity, high frequency tolerated |
| `REST` | complete rest / mobility | — |

**Same-session compatibility matrix** (`✅` allowed, `⚠️` allowed only in the stated order, `❌` forbidden):

|  | MAX_FINGER | MAX_GEN | POWER | ANAEROBIC | AEROBIC | SKILL | ACCESSORY |
|---|---|---|---|---|---|---|---|
| **MAX_FINGER** | — | ⚠️ finger first | ⚠️ power first | ❌ | ⚠️ finger first | ⚠️ skill first | ✅ |
| **MAX_GEN** | ⚠️ | — | ⚠️ power first | ⚠️ strength first | ⚠️ strength first | ⚠️ | ✅ |
| **POWER** | ⚠️ | ⚠️ | — | ⚠️ power first | ⚠️ power first | ⚠️ skill first | ✅ |
| **ANAEROBIC** | ❌ | ⚠️ | ⚠️ | — | ❌ | ⚠️ skill first | ✅ |
| **AEROBIC** | ⚠️ | ⚠️ | ⚠️ | ❌ | — | ✅ | ✅ |

**Mandatory within-session order** (highest neural demand first):
`SKILL → POWER → MAX_STRENGTH_FINGER → MAX_STRENGTH_GENERAL → ANAEROBIC_CAPACITY → AEROBIC_CAPACITY → ACCESSORY`

**Between-session recovery minima** (hours from session end to next session start):

| After | Before next | Min gap |
|---|---|---|
| `MAX_STRENGTH_FINGER` | any finger-intensive session | **48 h** |
| `POWER` (campus/limit) | `MAX_STRENGTH_FINGER` or `POWER` | **48 h** |
| `ANAEROBIC_CAPACITY` | `ANAEROBIC_CAPACITY` | **72 h** |
| `ANAEROBIC_CAPACITY` | `MAX_STRENGTH_FINGER` | **48 h** |
| `AEROBIC_CAPACITY` | anything | 12 h |

**Weekly caps by training age** (years of *structured* training, not years climbing):

| Training age | Max high-intensity finger days/wk | Max ANAEROBIC days/wk | Min full rest days/wk |
|---|---|---|---|
| < 1 y | 1 (hangboard only after 12 mo climbing) | 0–1 | 3 |
| 1–3 y | 2 | 1 | 2 |
| > 3 y | 3 | 2 | 1 |

## 2.3 Protocol library (Segment C)

Each protocol is a typed record, not prose. The LLM selects by `id` and sets `pct`; it may not invent protocols or alter timing.

### `eva_lopez_maxhang_maw` — Maximum Added Weight
- **Stimulus:** `MAX_STRENGTH_FINGER`
- **Edge:** fixed 18–20 mm; **grip:** half-crimp or open-hand (one per block, don't alternate)
- **Work:** 10 s hang · **Sets:** 4–5 · **Rest:** 180 s
- **Intensity basis:** `MAX_HANG_20MM_TOTAL_LOAD` (bodyweight + added, at the athlete's 10 s max)
- **Training range:** `pct` 0.85–1.00. Below 0.85 the stimulus is no longer maximal; the engine rejects it.
- **Progression:** when all sets hit full 10 s at session RPE ≤ 8 → next exposure `pct` +0.025
- **Gate:** ≥ 12 months consistent climbing; never in week 1 of a returning athlete

### `eva_lopez_maxhang_med` — Minimum Edge Depth
- Same structure, but bodyweight-only and progression is **edge depth**, not load (20 → 18 → 15 → 14 → 12 mm). Preferred where the athlete has no plate/pulley setup. Never step edge depth down more than one increment per 2 weeks.

### `lattice_repeaters_7_3` — 7:3 Repeaters
- **Stimulus:** `AEROBIC_CAPACITY` (local forearm aerobic/strength-endurance)
- **Work:** 7 s hang / 3 s rest × 6 reps = one 60 s set · **Sets:** 4–6 · **Rest:** 120–180 s
- **Edge:** 20 mm · **Grip:** half-crimp or open-hand
- **Intensity basis:** `MAX_HANG_20MM_TOTAL_LOAD`, `pct` **0.72–0.85**
- **Resolution note:** at these percentages total load is frequently *below* bodyweight — the engine emits **pulley/band assistance in kg**, not added weight. A protocol that silently prescribes negative added weight is a bug.
- **Progression:** `pct` +0.02/wk, or +1 set every 2 weeks, **never both in the same week**

### `four_by_four` — 4×4 Power Endurance
- **Stimulus:** `ANAEROBIC_CAPACITY`
- **Structure:** 4 boulder problems × 4 consecutive ascents; ~0 rest between ascents (downclimb/drop only), **3–5 min between sets**
- **Intensity basis:** `BOULDER_LIMIT_GRADE`, offset **−2 to −4 V-grades** (target: completes set 1 clean, set 4 is a genuine fight)
- **Progression:** reduce inter-set rest 5:00 → 4:00 → 3:00 across a block, *then* raise grade offset by 1 and reset rest
- **Placement:** never within 48 h before a `MAX_STRENGTH_FINGER` day; never in the 10 days before a peak/trip

### Others in the library
`limit_bouldering`, `campus_ladders` (gated: ≥3 y training age, no pulley history), `arc_circuits`, `weighted_pullups`, `front_lever_progression`, `antagonist_block`. Each carries `equipment_required[]`, `contraindications[]`, `min_training_age_years`, and its `intensity_basis`.

## 2.4 Progressive overload doctrine (Segment D)

### Baseline derivation (engine, not LLM)

```
TL_max       = bodyweight_kg + max_added_kg        # 10 s max hang total load, 20 mm
LoadIndex    = TL_max / bodyweight_kg              # normalised, comparable across athletes
PU_1RM       = w_used × (1 + reps/30)              # Epley, from a ≤6-rep weighted pull-up set
target_load  = pct × TL_max − bodyweight_kg        # → added kg (negative ⇒ assistance kg)
```

Every resolved load is then: clamped to `[protocol.min_pct, protocol.max_pct] × TL_max`, rounded **down** to the athlete's available increment (plate set, band step, 0.5 kg default), and capped by any active injury clamp.

### Mesocycle shape

4-week blocks, **3:1 loading** — weeks 1–3 progressive, week 4 deload (volume −40–50 %, intensity −5–10 %, all `ANAEROBIC_CAPACITY` removed). Intensity progresses on the primary stimulus; volume progresses on the secondary. Never both, never in the same week.

### Autoregulation table (drives adjustment — see §4.4)

| Session RPE on the primary stimulus | Engine action for the next same-stimulus exposure |
|---|---|
| ≤ 6 (well under) | `pct` **+0.05** (capped at protocol max) |
| 7–8 (**target zone**) | `pct` **+0.025** |
| 9 | **hold** `pct`, no progression |
| 10 or any failed rep / lost grip | `pct` **−0.05**, and flag the block |
| ≥ 9 on two consecutive exposures | **−0.05 and insert an unscheduled deload week** |
| Any *pain* flag (≠ soreness) | protocol suspended, safe substitution, referral prompt |

sRPE load monitoring: `session_load = sRPE × duration_min`; weekly acute:chronic ratio (7 d : 28 d rolling) outside **0.8–1.3** is surfaced to the model as a deviation and biases the next block conservative.

## 2.5 What the prompt forbids

Stated as hard constraints in Segment A, and *independently re-checked* by the validator — a prompt rule you do not also validate in code is a suggestion:

- No kilogram figures in output — only `basis` + `pct`/offset.
- No diagnosis, no rehab programming, no "push through it". Pain → suspend + refer.
- No hangboarding for athletes with `< 12 months` climbing; no campus below 3 years' structured training or with any pulley-injury history in the last 12 months.
- No protocol whose `equipment_required` is not in the athlete's equipment set.
- No session on a day the athlete marked unavailable.
- No new max-intensity stimulus in the 10 days before a declared trip/competition (taper window).

## 2.6 Validator (`packages/engine/validate.ts`)

Runs on every draft, returns a machine-readable violation list that is fed back to the model for repair:

```ts
type Violation =
  | { code: "STIMULUS_CLASH"; session_id: string; a: Stimulus; b: Stimulus }
  | { code: "RECOVERY_GAP"; from: string; to: string; got_h: number; min_h: number }
  | { code: "WEEKLY_CAP"; week: number; stimulus: Stimulus; got: number; max: number }
  | { code: "EQUIPMENT_MISSING"; item_id: string; needs: string }
  | { code: "CONTRAINDICATED"; item_id: string; injury: string }
  | { code: "INTENSITY_RANGE"; item_id: string; pct: number; allowed: [number, number] }
  | { code: "UNAVAILABLE_DAY"; date: string }
  | { code: "TAPER_VIOLATION"; date: string; event: string };
```

Two repair attempts, then the deterministic fallback block. Every violation is logged with the prompt hash — this is your regression signal when you edit doctrine.

## 2.7 Evaluating the coach

Treat the prompt as code: a fixture set of ~40 synthetic athletes (beginner/no equipment, advanced/full board, post-pulley-injury, 2-days-a-week parent, pre-trip taper, …) run on every prompt change. Score: schema pass rate, violations per block, repair rate, and a rubric-graded sample reviewed by a human coach. Ship a doctrine change only when violations-per-block does not regress.
