export const PHASE_NAMES = ["WAITING", "DEALING", "PREFLOP", "FLOP", "TURN", "RIVER", "SHOWDOWN", "COMPLETE"] as const;

export const phaseName = (n: number | bigint | undefined) => {
  if (n === undefined) return "—";
  const i = Number(n);
  return PHASE_NAMES[i] ?? `PHASE_${i}`;
};

const COLORS: Record<string, string> = {
  WAITING: "badge-ghost",
  DEALING: "badge-info",
  PREFLOP: "badge-primary",
  FLOP: "badge-primary",
  TURN: "badge-primary",
  RIVER: "badge-primary",
  SHOWDOWN: "badge-warning",
  COMPLETE: "badge-success",
};

export const PhaseBadge = ({ phase }: { phase: number | bigint | undefined }) => {
  const name = phaseName(phase);
  const color = COLORS[name] ?? "badge-neutral";
  return <span className={`badge ${color} font-semibold`}>{name}</span>;
};
