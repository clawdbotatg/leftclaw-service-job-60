"use client";

import { formatUnits } from "viem";

type Props = {
  value: bigint;
  /** Visual variant. `inline` is for table cells and sentence-flow; `stacked` is for hero numbers. */
  variant?: "inline" | "stacked";
  className?: string;
};

// CLAWD has no public price oracle. Per the frontend-ux rule every token
// amount shown to users must either show a USD equivalent or an explicit
// N/A marker — we pick the latter everywhere.
const formatClawd = (raw: bigint): string => {
  const whole = raw / 10n ** 18n;
  const frac = raw % 10n ** 18n;
  if (frac === 0n) return whole.toLocaleString();
  // Trim trailing zeros from the 18-decimal fraction.
  const s = formatUnits(raw, 18);
  return s;
};

export const ClawdAmount = ({ value, variant = "inline", className = "" }: Props) => {
  const text = formatClawd(value);
  if (variant === "stacked") {
    return (
      <span className={className}>
        {text} <span className="text-base font-normal opacity-80">CLAWD</span>
        <span
          className="ml-2 text-xs opacity-60 tooltip tooltip-bottom cursor-help"
          data-tip="CLAWD has no public price oracle — value shown in token units only."
        >
          ~N/A USD
        </span>
      </span>
    );
  }
  return (
    <span className={className}>
      <span className="font-semibold">{text}</span> CLAWD
      <span
        className="ml-1 text-[10px] opacity-60 tooltip tooltip-top cursor-help align-middle"
        data-tip="No public price oracle for CLAWD"
      >
        ~N/A USD
      </span>
    </span>
  );
};
