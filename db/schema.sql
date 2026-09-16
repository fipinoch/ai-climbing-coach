-- ClimbAI Coach — PostgreSQL 16 schema (reference DDL)
-- Principles:
--   * Athlete-owned rows carry athlete_id and are protected by RLS.
--   * Plans are immutable versions; adjustments create a new version, never an UPDATE.
--   * Everything the AI consumes is derived by a view or a materialised metric, never
--     assembled ad hoc in application code.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─────────────────────────────────────────────────────────────────────────────
-- ENUMS
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TYPE grade_system   AS ENUM ('v_scale','font','french','yds','uiaa');
CREATE TYPE climb_discipline AS ENUM ('boulder','sport','trad','board');
CREATE TYPE stimulus       AS ENUM (
  'MAX_STRENGTH_FINGER','MAX_STRENGTH_GENERAL','POWER','ANAEROBIC_CAPACITY',
  'AEROBIC_CAPACITY','SKILL','ACCESSORY','REST');
CREATE TYPE grip_type      AS ENUM ('half_crimp','open_hand','full_crimp','three_finger_drag','pinch','n_a');
CREATE TYPE injury_status  AS ENUM ('active','rehabilitating','resolved');
CREATE TYPE plan_status    AS ENUM ('draft','active','superseded','abandoned');
CREATE TYPE session_status AS ENUM ('scheduled','completed','partial','skipped','moved');

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. IDENTITY & PROFILE
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE athletes (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id      TEXT UNIQUE NOT NULL,          -- Clerk / Supabase subject
  display_name      TEXT,
  date_of_birth     DATE,                          -- gates youth-safety rules
  units             TEXT NOT NULL DEFAULT 'metric' CHECK (units IN ('metric','imperial')),
  timezone          TEXT NOT NULL DEFAULT 'UTC',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Slowly-changing profile facts. Append-only: a new row supersedes the previous,
-- so a plan generated in March can still be explained with March's profile.
CREATE TABLE athlete_profiles (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  athlete_id                  UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  effective_from              DATE NOT NULL DEFAULT CURRENT_DATE,
  bodyweight_kg               NUMERIC(5,2) NOT NULL CHECK (bodyweight_kg BETWEEN 25 AND 200),
  height_cm                   NUMERIC(5,1),
  ape_index_cm                NUMERIC(4,1),
  climbing_experience_months  INT  NOT NULL CHECK (climbing_experience_months >= 0),
  structured_training_years   NUMERIC(4,1) NOT NULL DEFAULT 0,
  primary_discipline          climb_discipline NOT NULL,
  -- Self-assessed style profile; feeds exercise selection, not load math.
  style_power                 SMALLINT CHECK (style_power BETWEEN 1 AND 5),
  style_endurance             SMALLINT CHECK (style_endurance BETWEEN 1 AND 5),
  style_technique             SMALLINT CHECK (style_technique BETWEEN 1 AND 5),
  preferred_grip              grip_type NOT NULL DEFAULT 'half_crimp',
  goal_statement              TEXT,
  goal_event_date             DATE,                -- drives the taper window
  UNIQUE (athlete_id, effective_from)
);
CREATE INDEX ON athlete_profiles (athlete_id, effective_from DESC);

-- Grades are multi-system and multi-discipline; store the normalised integer so the
-- engine never parses "V7" or "7b+" at runtime. See packages/engine/grades.ts.
CREATE TABLE grade_records (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  athlete_id    UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  discipline    climb_discipline NOT NULL,
  metric        TEXT NOT NULL CHECK (metric IN ('onsight','flash','redpoint','limit')),
  system        grade_system NOT NULL,
  raw_grade     TEXT NOT NULL,                     -- 'V7', '7b+' — what the athlete typed
  normalised    SMALLINT NOT NULL,                 -- single ordinal scale, engine-facing
  recorded_on   DATE NOT NULL DEFAULT CURRENT_DATE,
  UNIQUE (athlete_id, discipline, metric, recorded_on)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. EQUIPMENT, AVAILABILITY, CONSTRAINTS
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE equipment_catalog (
  id          TEXT PRIMARY KEY,                    -- 'hangboard','campus_board','pulley_system'
  label       TEXT NOT NULL,
  category    TEXT NOT NULL
);

CREATE TABLE athlete_equipment (
  athlete_id  UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  equipment_id TEXT NOT NULL REFERENCES equipment_catalog(id),
  -- Details that change load resolution: plate increments, edge sizes, board angle.
  attributes  JSONB NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (athlete_id, equipment_id)
);
-- e.g. attributes = {"edges_mm":[20,15,10],"min_increment_kg":1.25,"max_added_kg":40}

CREATE TABLE availability (
  athlete_id        UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  day_of_week       SMALLINT NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  available         BOOLEAN NOT NULL DEFAULT true,
  max_duration_min  SMALLINT NOT NULL DEFAULT 90,
  venue             TEXT CHECK (venue IN ('home','gym','outdoor','any')),
  PRIMARY KEY (athlete_id, day_of_week)
);

-- Trips, competitions, holidays, illness. Blocks planning and triggers tapers.
CREATE TABLE calendar_constraints (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  athlete_id  UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  kind        TEXT NOT NULL CHECK (kind IN ('trip','competition','unavailable','travel','illness')),
  starts_on   DATE NOT NULL,
  ends_on     DATE NOT NULL,
  label       TEXT,
  CHECK (ends_on >= starts_on)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. INJURY HISTORY  (hard gates on protocol selection)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE injuries (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  athlete_id      UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  structure       TEXT NOT NULL,                   -- 'a2_pulley_left_ring','shoulder_right','elbow_medial'
  diagnosis       TEXT,
  status          injury_status NOT NULL,
  onset_on        DATE NOT NULL,
  resolved_on     DATE,
  -- Machine-readable restrictions the validator enforces; never free text alone.
  contraindicated_protocols TEXT[] NOT NULL DEFAULT '{}',
  contraindicated_grips     grip_type[] NOT NULL DEFAULT '{}',
  max_intensity_pct         NUMERIC(3,2),          -- global clamp while active
  notes           TEXT
);
CREATE INDEX ON injuries (athlete_id) WHERE status <> 'resolved';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. ASSESSMENTS  (the numbers every prescription is derived from)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE assessment_protocols (
  id           TEXT PRIMARY KEY,                   -- 'max_hang_10s_20mm','pullup_1rm','repeater_to_failure'
  label        TEXT NOT NULL,
  unit         TEXT NOT NULL,                      -- 'kg','mm','reps','s'
  basis_code   TEXT,                               -- maps to the LLM's `intensity.basis`
  retest_every_weeks SMALLINT NOT NULL DEFAULT 10
);

CREATE TABLE assessments (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  athlete_id    UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  performed_on  DATE NOT NULL,
  bodyweight_kg NUMERIC(5,2) NOT NULL,             -- snapshot: load ratios need the weight of that day
  is_estimated  BOOLEAN NOT NULL DEFAULT false,    -- true when onboarding inferred it from grade
  notes         TEXT
);

CREATE TABLE assessment_results (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  assessment_id UUID NOT NULL REFERENCES assessments(id) ON DELETE CASCADE,
  protocol_id   TEXT NOT NULL REFERENCES assessment_protocols(id),
  value         NUMERIC(7,2) NOT NULL,
  -- Conditions that make the value meaningful. A max hang without an edge size is noise.
  edge_mm       SMALLINT,
  grip          grip_type,
  reps          SMALLINT,
  rpe           NUMERIC(3,1) CHECK (rpe BETWEEN 1 AND 10),
  UNIQUE (assessment_id, protocol_id, edge_mm, grip)
);

-- Engine-facing derived metrics. Recomputed on every new assessment; this is what the
-- context assembler reads, so the LLM payload never contains raw assessment rows.
CREATE TABLE derived_metrics (
  athlete_id            UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  computed_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  source_assessment_id  UUID REFERENCES assessments(id),
  max_hang_20mm_added_kg      NUMERIC(5,2),
  max_hang_20mm_total_load_kg NUMERIC(6,2),
  finger_load_index           NUMERIC(4,3),   -- total load / bodyweight
  min_edge_depth_mm           SMALLINT,
  pullup_1rm_kg               NUMERIC(6,2),   -- Epley from a <=6-rep set
  pullup_strength_ratio       NUMERIC(4,3),   -- 1RM / bodyweight
  max_pullups_bw              SMALLINT,
  core_level                  SMALLINT,
  boulder_limit_normalised    SMALLINT,
  route_onsight_normalised    SMALLINT,
  is_stale                    BOOLEAN NOT NULL DEFAULT false,  -- older than retest_every_weeks
  PRIMARY KEY (athlete_id, computed_at)
);
CREATE INDEX ON derived_metrics (athlete_id, computed_at DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. PLANS  (immutable versions)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE training_blocks (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  athlete_id    UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  block_name    TEXT NOT NULL,
  primary_goal  TEXT NOT NULL,
  start_date    DATE NOT NULL,
  weeks         SMALLINT NOT NULL CHECK (weeks BETWEEN 1 AND 8),
  status        plan_status NOT NULL DEFAULT 'draft',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX one_active_block_per_athlete
  ON training_blocks (athlete_id) WHERE status = 'active';

CREATE TABLE plan_versions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  block_id        UUID NOT NULL REFERENCES training_blocks(id) ON DELETE CASCADE,
  version         INT NOT NULL,
  supersedes_id   UUID REFERENCES plan_versions(id),
  -- Provenance: answers "what produced this plan?" months later.
  prompt_hash     TEXT NOT NULL,
  schema_version  TEXT NOT NULL,
  model_id        TEXT NOT NULL,
  llm_request_id  UUID,
  reason          TEXT NOT NULL,   -- 'initial' | 'autoreg_rpe' | 'missed_sessions' | 'injury' | 'manual'
  document        JSONB NOT NULL,  -- the validated TrainingBlock, pre load-resolution
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (block_id, version)
);

-- Relational projection of the active version. Sessions and items are rewritten
-- on version change; logs reference them by id and survive via session_logs.
CREATE TABLE plan_sessions (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_version_id        UUID NOT NULL REFERENCES plan_versions(id) ON DELETE CASCADE,
  athlete_id             UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  external_key           TEXT NOT NULL,          -- the LLM's session_id, stable across versions
  scheduled_date         DATE NOT NULL,
  week                   SMALLINT NOT NULL,
  primary_stimulus       stimulus NOT NULL,
  title                  TEXT NOT NULL,
  coaching_note          TEXT,
  estimated_duration_min SMALLINT NOT NULL,
  is_deload              BOOLEAN NOT NULL DEFAULT false,
  flags                  TEXT[] NOT NULL DEFAULT '{}',
  status                 session_status NOT NULL DEFAULT 'scheduled',
  UNIQUE (plan_version_id, external_key)
);
CREATE INDEX ON plan_sessions (athlete_id, scheduled_date);

CREATE TABLE plan_items (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_session_id   UUID NOT NULL REFERENCES plan_sessions(id) ON DELETE CASCADE,
  external_key      TEXT NOT NULL,
  protocol_id       TEXT NOT NULL,
  stimulus          stimulus NOT NULL,
  ordinal           SMALLINT NOT NULL,
  sets              SMALLINT NOT NULL,
  reps              SMALLINT,
  work_s            SMALLINT,
  rest_s            SMALLINT,
  inter_set_rest_s  SMALLINT,
  grip              grip_type NOT NULL DEFAULT 'n_a',
  -- As emitted by the model:
  intensity_basis   TEXT NOT NULL,
  intensity_pct     NUMERIC(4,3),
  grade_offset      SMALLINT,
  -- As resolved by the deterministic engine (what the athlete actually sees):
  resolved_load_kg      NUMERIC(6,2),   -- negative ⇒ assistance
  resolved_edge_mm      SMALLINT,
  resolved_grade_label  TEXT,
  resolution_note       TEXT,           -- 'rounded down to 1.25kg increment', 'injury clamp applied'
  UNIQUE (plan_session_id, external_key)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. ACTIVITY LOGS  (the feedback loop)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE session_logs (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  athlete_id       UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  plan_session_id  UUID REFERENCES plan_sessions(id) ON DELETE SET NULL,  -- NULL ⇒ unplanned session
  performed_on     DATE NOT NULL,
  started_at       TIMESTAMPTZ,
  duration_min     SMALLINT,
  session_rpe      NUMERIC(3,1) CHECK (session_rpe BETWEEN 1 AND 10),
  session_load     NUMERIC(7,1) GENERATED ALWAYS AS (session_rpe * duration_min) STORED,
  -- Readiness, captured pre-session; explains a bad session that wasn't a bad prescription.
  sleep_hours      NUMERIC(3,1),
  soreness         SMALLINT CHECK (soreness BETWEEN 1 AND 5),
  stress           SMALLINT CHECK (stress BETWEEN 1 AND 5),
  motivation       SMALLINT CHECK (motivation BETWEEN 1 AND 5),
  pain_flag        BOOLEAN NOT NULL DEFAULT false,
  pain_structure   TEXT,
  athlete_note     TEXT,
  completed_ratio  NUMERIC(3,2),     -- items completed / prescribed
  client_uuid      TEXT UNIQUE,      -- offline-queue idempotency key
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ON session_logs (athlete_id, performed_on DESC);

CREATE TABLE set_logs (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_log_id   UUID NOT NULL REFERENCES session_logs(id) ON DELETE CASCADE,
  plan_item_id     UUID REFERENCES plan_items(id) ON DELETE SET NULL,
  set_number       SMALLINT NOT NULL,
  -- Prescribed vs. actual, side by side: the entire autoregulation signal lives here.
  prescribed_load_kg NUMERIC(6,2),
  actual_load_kg     NUMERIC(6,2),
  prescribed_reps    SMALLINT,
  actual_reps        SMALLINT,
  actual_work_s      SMALLINT,
  set_rpe            NUMERIC(3,1) CHECK (set_rpe BETWEEN 1 AND 10),
  failed             BOOLEAN NOT NULL DEFAULT false,
  edge_mm            SMALLINT,
  grip               grip_type,
  UNIQUE (session_log_id, plan_item_id, set_number)
);

-- Audit of every automatic or AI-proposed change. Nothing mutates a plan silently.
CREATE TABLE plan_adjustments (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  athlete_id          UUID NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
  block_id            UUID NOT NULL REFERENCES training_blocks(id) ON DELETE CASCADE,
  trigger             TEXT NOT NULL,   -- 'rpe_high','rpe_low','missed_sessions','pain','acwr','manual'
  tier                SMALLINT NOT NULL CHECK (tier BETWEEN 0 AND 3),
  severity            TEXT NOT NULL CHECK (severity IN ('minor','moderate','structural')),
  operations          JSONB NOT NULL,
  acknowledgement     TEXT NOT NULL,
  from_version_id     UUID REFERENCES plan_versions(id),
  to_version_id       UUID REFERENCES plan_versions(id),
  athlete_response    TEXT CHECK (athlete_response IN ('pending','accepted','declined','expired')),
  responded_at        TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. LLM OBSERVABILITY
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE llm_requests (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  athlete_id         UUID REFERENCES athletes(id) ON DELETE SET NULL,
  purpose            TEXT NOT NULL,   -- 'generate_block','revise_block','explain_item'
  model_id           TEXT NOT NULL,
  prompt_hash        TEXT NOT NULL,
  schema_version     TEXT NOT NULL,
  input_tokens       INT,
  cache_read_tokens  INT,
  output_tokens      INT,
  cost_usd           NUMERIC(8,5),
  latency_ms         INT,
  attempt            SMALLINT NOT NULL DEFAULT 0,
  stop_reason        TEXT,
  validation_passed  BOOLEAN,
  violations         JSONB,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ON llm_requests (prompt_hash, created_at DESC);
CREATE INDEX ON llm_requests (validation_passed, created_at DESC) WHERE validation_passed = false;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. ROW LEVEL SECURITY (illustrative — repeat per athlete-owned table)
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE session_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY session_logs_owner ON session_logs
  USING (athlete_id = current_setting('app.athlete_id', true)::uuid);
