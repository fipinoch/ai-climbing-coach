/**
 * ClimbAI Coach — deterministic prescription engine.
 *
 * This module owns every number that reaches an athlete. The LLM emits relative
 * intensities (`basis` + `pct`); everything here converts them to loads, applies
 * safety clamps, and rounds to equipment the athlete actually owns.
 *
 * Invariants:
 *   - Pure functions. No I/O, no clock reads, no randomness. Fully unit-testable.
 *   - Every returned load carries a `note` explaining how it was derived, which is
 *     surfaced verbatim in the "where this came from" UI.
 *   - Clamps are applied in a fixed order: protocol range → injury clamp → absolute
 *     safety bound → equipment rounding. Order matters; do not reorder.
 */

export type Basis =
  | "MAX_HANG_20MM_TOTAL_LOAD"
  | "MIN_EDGE_DEPTH_MM"
  | "PULLUP_1RM"
  | "BOULDER_LIMIT_GRADE"
  | "ROUTE_ONSIGHT_GRADE"
  | "CAMPUS_RUNG_SET"
  | "CORE_LEVEL"
  | "RPE_TARGET"
  | "BODYWEIGHT";

export interface Baselines {
  bodyweightKg: number;
  maxHang20mmTotalLoadKg: number; // bodyweight + max added, 10s, 20mm
  minEdgeDepthMm?: number;
  pullup1rmKg?: number;
  boulderLimitNormalised?: number;
  routeOnsightNormalised?: number;
  isEstimated: boolean;
  isStale: boolean;
}

export interface EquipmentProfile {
  minIncrementKg: number; // smallest plate/step the athlete owns
  maxAddedKg: number;
  hasPulley: boolean; // can apply assistance (negative load)
  edgesMm: number[];
}

export interface InjuryClamp {
  maxIntensityPct?: number;
  contraindicatedProtocols: string[];
}

export interface ProtocolSpec {
  id: string;
  minPct: number;
  maxPct: number;
}

/** Protocol intensity ranges. Single source of truth — the validator reads this too. */
export const PROTOCOLS: Record<string, ProtocolSpec> = {
  eva_lopez_maxhang_maw: { id: "eva_lopez_maxhang_maw", minPct: 0.85, maxPct: 1.0 },
  lattice_repeaters_7_3: { id: "lattice_repeaters_7_3", minPct: 0.72, maxPct: 0.85 },
  weighted_pullups: { id: "weighted_pullups", minPct: 0.8, maxPct: 0.92 },
};

/** Absolute safety ceiling regardless of what any other layer says. */
const ABSOLUTE_MAX_PCT = 1.0;
/** Conservative ceiling while baselines are estimated or stale. */
const UNVERIFIED_MAX_PCT = 0.85;

export interface ResolvedLoad {
  /** Added weight in kg. Negative means assistance (pulley/band). */
  addedKg: number;
  totalLoadKg: number;
  effectivePct: number;
  note: string;
}

const round = (v: number, step: number) => Math.round(v / step) * step;
/** Loads always round DOWN to the nearest owned increment — never prescribe up. */
const roundDown = (v: number, step: number) => Math.floor(v / step) * step;

/**
 * Resolve an LLM intensity directive into an actual load.
 *
 * Example: pct 0.90, TL_max 118.5kg, BW 72kg, 1.25kg plates
 *   → total 106.65kg → added 34.65kg → rounds down to 34.0kg (not 35.0)
 */
export function resolveHangLoad(args: {
  protocolId: string;
  pct: number;
  baselines: Baselines;
  equipment: EquipmentProfile;
  injury?: InjuryClamp;
}): ResolvedLoad {
  const { protocolId, baselines, equipment, injury } = args;
  const spec = PROTOCOLS[protocolId];
  if (!spec) throw new Error(`unknown protocol: ${protocolId}`);

  const notes: string[] = [];
  let pct = args.pct;

  // 1. Protocol range.
  const clampedToProtocol = Math.min(Math.max(pct, spec.minPct), spec.maxPct);
  if (clampedToProtocol !== pct) {
    notes.push(`clamped to ${protocolId} range ${spec.minPct}–${spec.maxPct}`);
    pct = clampedToProtocol;
  }

  // 2. Injury clamp.
  if (injury?.maxIntensityPct != null && pct > injury.maxIntensityPct) {
    notes.push(`injury clamp ${injury.maxIntensityPct}`);
    pct = injury.maxIntensityPct;
  }

  // 3. Unverified-baseline clamp, then absolute ceiling.
  if ((baselines.isEstimated || baselines.isStale) && pct > UNVERIFIED_MAX_PCT) {
    notes.push(
      baselines.isEstimated ? "estimated baselines — capped at 85%" : "baselines stale — capped at 85%",
    );
    pct = UNVERIFIED_MAX_PCT;
  }
  pct = Math.min(pct, ABSOLUTE_MAX_PCT);

  // 4. Convert and round to owned equipment.
  const totalTarget = pct * baselines.maxHang20mmTotalLoadKg;
  let added = totalTarget - baselines.bodyweightKg;

  if (added >= 0) {
    added = Math.min(added, equipment.maxAddedKg);
    added = roundDown(added, equipment.minIncrementKg);
  } else {
    // Sub-bodyweight target (normal for repeaters): needs assistance.
    if (!equipment.hasPulley) {
      notes.push("no pulley — substitute a larger edge or reduce sets instead of assisting");
      added = 0;
    } else {
      added = -round(Math.abs(added), equipment.minIncrementKg);
    }
  }

  const totalLoadKg = baselines.bodyweightKg + added;
  return {
    addedKg: added,
    totalLoadKg,
    effectivePct: totalLoadKg / baselines.maxHang20mmTotalLoadKg,
    note:
      `${(pct * 100).toFixed(0)}% of ${baselines.maxHang20mmTotalLoadKg.toFixed(1)}kg max hang total load` +
      (notes.length ? ` (${notes.join("; ")})` : ""),
  };
}

/** Epley, from a set of <= 6 reps. Above 6 reps the estimate degrades badly. */
export function pullup1rm(weightUsedKg: number, bodyweightKg: number, reps: number): number {
  if (reps < 1 || reps > 6) throw new Error("estimate 1RM from 1–6 reps only");
  const total = bodyweightKg + weightUsedKg;
  return total * (1 + reps / 30) - bodyweightKg;
}

// ─────────────────────────────────────────────────────────────────────────────
// Autoregulation — the rule table from docs/02-ai-engine.md §2.4.
// Tier 1 adjustments run entirely here, with no model call.
// ─────────────────────────────────────────────────────────────────────────────

export interface ExposureOutcome {
  sessionRpe: number;
  anyFailedRep: boolean;
  completedSets: number;
  prescribedSets: number;
  painFlag: boolean;
}

export type AutoregAction =
  | { kind: "progress"; deltaPct: number; reason: string }
  | { kind: "hold"; reason: string }
  | { kind: "regress"; deltaPct: number; reason: string }
  | { kind: "deload"; deltaPct: number; reason: string }
  | { kind: "suspend"; reason: string };

export function autoregulate(current: ExposureOutcome, previous?: ExposureOutcome): AutoregAction {
  if (current.painFlag) {
    return { kind: "suspend", reason: "You flagged pain — this protocol is paused until it settles." };
  }
  if (previous && previous.sessionRpe >= 9 && current.sessionRpe >= 9) {
    return {
      kind: "deload",
      deltaPct: -0.05,
      reason: "Two hard sessions in a row on this stimulus — easing off and bringing recovery forward.",
    };
  }
  if (current.sessionRpe >= 10 || current.anyFailedRep) {
    return { kind: "regress", deltaPct: -0.05, reason: "That was at your limit — backing the load off 5%." };
  }
  if (current.sessionRpe >= 9) {
    return { kind: "hold", reason: "Holding this load until it settles into the 7–8 range." };
  }
  if (current.sessionRpe <= 6) {
    return { kind: "progress", deltaPct: 0.05, reason: "That was comfortable — stepping the load up." };
  }
  return { kind: "progress", deltaPct: 0.025, reason: "Right in the target zone — normal progression." };
}

/** Acute:chronic workload ratio from session loads (sRPE × duration). */
export function acwr(last7dLoads: number[], last28dLoads: number[]): number {
  const acute = last7dLoads.reduce((a, b) => a + b, 0);
  const chronic = last28dLoads.reduce((a, b) => a + b, 0) / 4;
  return chronic === 0 ? 0 : acute / chronic;
}

export const ACWR_SAFE_BAND: readonly [number, number] = [0.8, 1.3];
