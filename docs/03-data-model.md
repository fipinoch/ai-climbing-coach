# 3. Database Architecture & User Inputs

Full DDL: [`db/schema.sql`](../db/schema.sql). This document explains the *why*.

## 3.1 Four governing rules

1. **Snapshot, don't overwrite.** Bodyweight, grades and profile facts change. A plan
   generated in March must remain explainable with March's numbers, so profile rows are
   append-only (`effective_from`) and each assessment stores the bodyweight of that day.
   A load ratio computed against today's bodyweight and last quarter's max hang is fiction.
2. **Plans are immutable versions.** Every adjustment writes a new `plan_versions` row with
   `supersedes_id`. You get a free audit trail, trivial undo, and the ability to measure
   "did the AI's adjustment actually help?" — which is the product's central question.
3. **The AI reads derived metrics, never raw rows.** `derived_metrics` is the contract
   between the database and the prompt. Raw assessment rows never enter a payload; that
   keeps the prompt small, cacheable, and stable when the schema evolves.
4. **Constraints are machine-readable.** An injury is not a free-text note — it is
   `contraindicated_protocols TEXT[]` plus `max_intensity_pct`, which the validator enforces
   in code. Free text is for humans; arrays are for the safety layer.

## 3.2 Table groups

### Identity & profile
`athletes` · `athlete_profiles` · `grade_records`

`grade_records` stores `raw_grade` (what the athlete typed — "V7", "7b+") **and**
`normalised` (a single integer ordinal). The engine only ever compares integers; grade-system
parsing happens once, at write time, in `packages/engine/grades.ts`. The LLM receives
normalised integers plus the athlete's display system, so `grade_offset: -3` resolves
correctly whether the user thinks in V-scale or Font.

Style sliders (`style_power` / `style_endurance` / `style_technique`) influence **exercise
selection**, never load math. They are self-assessed and therefore soft signals; treating
them as anything else lets a user's self-image drive their prescribed kilograms.

### Equipment & availability
`equipment_catalog` · `athlete_equipment` · `availability` · `calendar_constraints`

`athlete_equipment.attributes` (JSONB) carries the details that change load resolution:

```json
{ "edges_mm": [20, 15, 10], "min_increment_kg": 1.25, "max_added_kg": 40, "has_pulley": true }
```

`min_increment_kg` is the reason the engine rounds: prescribing 28.7 kg to someone with 2.5 kg
plates is a prescription they cannot follow. `calendar_constraints` of kind `trip` or
`competition` automatically opens the 10-day taper window.

### Injury history
`injuries`

The most safety-critical table. `status`, `structure`, `contraindicated_protocols[]`,
`contraindicated_grips[]`, and a global `max_intensity_pct` clamp. A partial index keeps
active/rehabilitating rows cheap to fetch — they are read on **every** generation and every
validation pass.

### Assessments
`assessment_protocols` · `assessments` · `assessment_results` · `derived_metrics`

`assessment_results` stores the **conditions**, not just the number: `edge_mm`, `grip`, `reps`,
`rpe`. A 30 kg max hang means nothing without "20 mm, half-crimp". The unique constraint is
`(assessment_id, protocol_id, edge_mm, grip)` so an athlete can test multiple grips in one session.

`derived_metrics` is recomputed on every new assessment and on bodyweight change:

| Column | Derivation | Used for |
|---|---|---|
| `max_hang_20mm_total_load_kg` | `bodyweight + max_added` | basis for hangs and repeaters |
| `finger_load_index` | `total_load / bodyweight` | cross-athlete comparison, progress chart |
| `pullup_1rm_kg` | Epley: `w × (1 + reps/30)` from a ≤6-rep set | basis for weighted pull-ups |
| `min_edge_depth_mm` | best bodyweight 10 s hang edge | basis for MED progression |
| `is_stale` | `now - performed_on > retest_every_weeks` | forces an assessment week + conservative loading |

**Onboarding without assessments.** Most new users won't have measured a max hang. Rather
than blocking them, estimate from grade and training age (`assessments.is_estimated = true`),
program week 1 as an assessment week, and clamp all intensities to `pct ≤ 0.85` until real
numbers land. The flag propagates to the plan as `flags: ["conservative_baselines"]` and to the
UI as an honest "these are estimates" banner.

### Plans
`training_blocks` · `plan_versions` · `plan_sessions` · `plan_items`

`plan_versions.document` holds the validated `TrainingBlock` JSONB exactly as the model
emitted it (relative intensities, no kilograms); `plan_sessions` / `plan_items` are the
relational projection the app queries, carrying **both** the model's directive
(`intensity_basis`, `intensity_pct`) and the engine's output (`resolved_load_kg`,
`resolution_note`). Keeping both side by side is what makes "why am I lifting 28.5 kg?"
answerable: basis 118.5 kg × 0.90 = 106.7 → 34.7 added → clamped by injury rule → 28.5.

`external_key` carries the model's own `session_id` across versions, so a logged session
stays attached to its lineage after a revision.

A partial unique index enforces one `active` block per athlete — the constraint that
otherwise gets violated by a double-tapped "Generate plan" button.

### Activity logs
`session_logs` · `set_logs` · `plan_adjustments`

`set_logs` stores `prescribed_*` next to `actual_*`. That pairing is the entire autoregulation
signal: "completed 5×10 s at the prescribed load, RPE 8" and "completed 3 sets then dropped
4 kg, RPE 10" are opposite futures, and a schema that only records what was done cannot tell
them apart.

`session_logs.session_load` is a generated column (`sRPE × duration`) so acute:chronic workload
ratio is a plain window query:

```sql
SELECT athlete_id,
       SUM(session_load) FILTER (WHERE performed_on > CURRENT_DATE - 7)  / 1.0   AS acute,
       SUM(session_load) FILTER (WHERE performed_on > CURRENT_DATE - 28) / 4.0   AS chronic
FROM session_logs GROUP BY athlete_id;
```

`pain_flag` is deliberately separate from `soreness` (1–5). Soreness is a training input;
pain is a stop condition. Never collapse them into one field — the UI must ask two questions.

`client_uuid UNIQUE` is the offline-queue idempotency key: the phone generates it, retries
carry it, the server de-duplicates.

### LLM observability
`llm_requests`

Every call logged with `prompt_hash`, `model_id`, token counts (including
`cache_read_tokens` — your cache-health metric), cost, latency, `stop_reason`,
`validation_passed`, and the `violations` array. Without this you cannot answer "did doctrine
v1.3 make plans better or worse?", which you will be asked in week three.

## 3.3 The context assembler

One function builds the LLM payload, from views only — never from ad-hoc queries scattered
through the codebase:

```ts
type PlanContext = {
  athlete:    { age_band, bodyweight_kg, units, experience_months, training_years,
                discipline, style, preferred_grip, goals, event_date? };
  grades:     { boulder_limit, boulder_flash, route_onsight, route_redpoint }; // normalised ints
  baselines:  DerivedMetrics & { measured_on: string; is_estimated: boolean; is_stale: boolean };
  equipment:  Array<{ id: string; attributes: Record<string, unknown> }>;
  injuries:   Array<{ structure, status, contraindicated_protocols, contraindicated_grips, max_intensity_pct }>;
  schedule:   { availability: DayBudget[]; constraints: CalendarConstraint[] };
  history:    { last_block_summary?, weekly_volume_by_stimulus_4w, acwr, adherence_pct };
  deviations?: DeviationReport;        // revision jobs only
};
```

Target ≤ 2 500 tokens. Strip nulls, round numbers, **sort keys deterministically** — an
unsorted object serialisation is a silent cache invalidator and a silent diff in your evals.
