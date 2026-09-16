# 1. Architecture & Tech Stack

## 1.1 Design constraints that drive every decision

| Constraint | Consequence |
|---|---|
| Plan generation takes 20–60 s of LLM time | Generation must be an **async job**, never an HTTP request/response |
| The AI's output becomes a *calendar*, not prose | Output must be **schema-validated structured data**, rejected on failure |
| Prescriptions are load-bearing (literally) | **Arithmetic must be deterministic**, not model-generated |
| Sessions are logged in a gym, on a phone, on bad Wi-Fi | **Offline-first write path** with a local queue |
| One product, two targets (iOS/Android + web) | One codebase, one type system, end to end |

## 1.2 Recommended stack

### Frontend — React Native (Expo SDK) + TypeScript

```
expo-router          file-based routing, shared across native + web
TanStack Query       server cache, retries, optimistic mutations
Zustand              ephemeral UI state (session player timer, rest countdown)
Reanimated 3         60fps timers/gestures on the UI thread (7:3 repeater clock)
expo-sqlite + MMKV   offline log queue + hot profile cache
Zod (shared pkg)     the *same* schemas the backend validates against
Victory Native XL    analytics charts (Skia-backed, no JS-thread jank)
```

**Why Expo over Flutter here:** the decisive factor is not rendering — both are fast enough — it is that the AI contract is a JSON schema. With TypeScript on both ends you author the plan schema **once** in `packages/contracts` and get: backend validation, LLM tool schema (`zodOutputFormat`), and frontend types from a single source. In Flutter you maintain that schema three times (Dart model, backend model, JSON Schema for the LLM) and drift is a matter of when, not if. Choose Flutter only if you already have a Dart team.

**Web target:** Expo Web (React Native Web) covers the dashboard adequately. If marketing/SEO matters, add a separate Next.js site that imports the same `packages/contracts` and `packages/ui-primitives`.

### Backend — Node 22 + TypeScript + Fastify

```
Fastify              ~2× Express throughput, first-class JSON Schema validation
Drizzle ORM          SQL-first, typed, generates migrations; no hidden N+1
PostgreSQL 16        relational core + JSONB for plan documents (Neon/Supabase)
BullMQ + Redis       plan-generation and revision job queues
@anthropic-ai/sdk    LLM calls
Zod                  runtime validation of every AI response
OpenTelemetry        traces; every LLM call is a span with token/cost attributes
```

**Why not Python:** there is no training/inference workload here — it is API orchestration plus closed-form arithmetic. Node keeps one language and one schema package. Revisit when you want real modelling (fatigue curves fitted per athlete, cohort clustering): at that point add a **thin FastAPI + Pandas analytics service** reading a read-replica, and keep Node as the API edge. Do not start there.

### Monorepo layout

```
apps/mobile          Expo app (iOS, Android, Web)
apps/api             Fastify API + BullMQ workers
packages/contracts   Zod schemas + generated JSON Schema  ← single source of truth
packages/engine      deterministic prescription + progression math (pure, unit-tested)
packages/prompts     versioned system prompts (content-hashed)
db/                  SQL migrations
```
pnpm workspaces + Turborepo. `packages/engine` must stay **pure functions, zero I/O** — it is the part that has to be provably correct.

### Infrastructure

| Concern | Choice | Note |
|---|---|---|
| Hosting | Fly.io / Railway containers | API and worker are separate processes, same image |
| DB | Neon or Supabase Postgres | branch-per-PR is worth a lot here |
| Auth | Clerk or Supabase Auth | JWT → Postgres RLS on `athlete_id` |
| Mobile delivery | EAS Build + EAS Update | OTA for JS-only changes |
| Secrets | Platform secret store | **No LLM key ever ships in the client** |
| LLM observability | `llm_requests` table (see §3) + OTel | you will need prompt-version A/B data |

## 1.3 Request topology

```
┌─────────────┐   POST /v1/plans (202 + job_id)   ┌────────────┐
│ Expo client │ ────────────────────────────────▶ │ Fastify API│
│             │ ◀──── SSE /v1/jobs/:id/stream ─── │            │
└─────────────┘                                   └─────┬──────┘
                                                        │ enqueue
                                                        ▼
                                              ┌───────────────────┐
                                              │ BullMQ worker     │
                                              │ 1 assemble context│
                                              │ 2 engine: targets │
                                              │ 3 LLM: structure  │
                                              │ 4 validate+repair │
                                              │ 5 engine: resolve │
                                              │ 6 persist version │
                                              └───────────────────┘
```

Generation is idempotent on `(athlete_id, block_start_date, input_fingerprint)` so a retried job never produces a duplicate block.

## 1.4 The core integration decision: **hybrid deterministic/LLM generation**

> **Rule: the LLM never does arithmetic that touches a barbell or a hangboard.**

LLMs are excellent at constrained combinatorial selection and explanation, and unreliable at multi-step arithmetic. So split responsibilities:

| Layer | Owns | Example |
|---|---|---|
| **Engine (TS, deterministic)** | baselines → derived metrics; % → kg; rounding to available plates; volume ramps; deload timing; safety clamps | `0.85 × 118.5 kg − 72 kg = 28.7 → 28.5 kg (0.5 kg plates)` |
| **LLM** | which protocols, on which days, in which order, at which *relative intensity*, with what coaching rationale, under this athlete's equipment/injury/schedule constraints | "Tue = MaxHangs @ 90% MAW; Thu = 4×4s; never adjacent" |
| **Validator** | schema + sports-science business rules; repair loop | reject a plan that puts max hangs the day after 4×4s |

The AI therefore emits **intensity directives**, not kilograms:

```jsonc
{
  "protocol_id": "eva_lopez_maxhang_maw",
  "intensity": { "basis": "MAX_HANG_20MM_TOTAL_LOAD", "pct": 0.90 },
  "sets": 5, "work_s": 10, "rest_s": 180
}
```

The engine resolves `basis + pct` → `target_added_kg`, applies plate rounding, injury clamps, and absolute safety bounds. If the model hallucinates `pct: 1.6`, the schema's `maximum: 1.05` rejects it before any human sees a number.

## 1.5 Getting reliable structured output from the LLM

Use **structured outputs** (`output_config.format`) with a Zod schema — not "please reply in JSON", not regex-scraping a code fence.

```ts
// apps/api/src/llm/generateBlock.ts
import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import { TrainingBlockSchema } from "@climbai/contracts";

const client = new Anthropic(); // key from env, server-side only

export async function generateBlock(ctx: PlanContext) {
  const res = await client.messages.parse({
    model: "claude-opus-5",
    max_tokens: 16000,
    thinking: { type: "adaptive" },       // periodisation is genuinely multi-constraint
    output_config: {
      effort: "high",
      format: zodOutputFormat(TrainingBlockSchema),
    },
    system: [
      // Stable prefix: ~4–6k tokens of coaching doctrine + protocol library.
      // Identical bytes on every request → cache hit.
      { type: "text", text: COACH_SYSTEM_PROMPT, cache_control: { type: "ephemeral", ttl: "1h" } },
    ],
    messages: [{ role: "user", content: JSON.stringify(ctx) }], // volatile: athlete payload
  });

  if (res.stop_reason === "refusal") throw new CoachRefusal(res.stop_details);
  const block = res.parsed_output;       // null if parsing failed — guard, don't assert
  if (!block) throw new SchemaMiss(res);
  return block;
}
```

Key points, in priority order:

1. **Schema-constrained decoding** removes the entire class of "unparseable JSON" bugs. You still validate with Zod afterwards — schema conformance ≠ semantic validity.
2. **`effort: "high"` + adaptive thinking.** Laying out a 4-week block under equipment, injury, recovery-spacing and schedule constraints is exactly the workload that repays reasoning depth. Sweep `medium` vs `high` on your eval set before locking it in.
3. **Prompt caching.** The doctrine prompt is large and byte-identical across users; the athlete payload is small and volatile. Put the cache breakpoint at the end of the system block and never interpolate a timestamp, a user name, or an unsorted JSON object into the prefix. Verify with `usage.cache_read_input_tokens > 0` — if it is 0 across repeated requests you have a silent invalidator.
4. **Stream long generations.** A 4-week block with coaching notes runs long; use `client.messages.stream(...)` + `.finalMessage()` for revision jobs with large `max_tokens` to avoid HTTP timeouts, and push progress over SSE so the UI can show "Coach is designing week 2…".
5. **Model choice.** Default `claude-opus-5` for initial block generation (the hard, once-per-4-weeks call). Route the cheap, high-frequency work — single-session swaps, "explain this exercise", log summarisation — to `claude-sonnet-5` or `claude-haiku-4-5`. Measure before downgrading the generator; a bad block costs a user's month.

### Validation + repair loop

```ts
const MAX_REPAIRS = 2;

for (let attempt = 0; attempt <= MAX_REPAIRS; attempt++) {
  const draft = await generateBlock(attempt === 0 ? ctx : { ...ctx, violations });
  const violations = validateSportsScience(draft, ctx);  // pure fn, packages/engine
  if (violations.length === 0) return resolveLoads(draft, ctx);
  log.warn({ attempt, violations }, "plan rejected");
}
return deterministicFallbackBlock(ctx);  // template plan, flagged for coach review
```

`validateSportsScience` enforces what a JSON Schema cannot express — stimulus clustering, 48 h finger-recovery spacing, weekly hard-day caps, injury contraindications, equipment availability. See §2.4. **The fallback matters:** an athlete opening the app on Monday must never see an empty week because a model call failed.

### Cost envelope (order of magnitude)

Per 4-week block: ~5–6k cached system tokens + ~2k athlete payload + ~6–8k output. At Opus 5 rates ($5/MTok in, $25/MTok out) that is roughly **$0.20–0.25 per block uncached**, materially less once the doctrine prefix is being served from cache (cache reads are billed at a steep discount — check current multipliers). One block/month + a handful of Sonnet-tier revisions lands well under **$0.50/active user/month**. Verify against live pricing before you build a business model on it.
