"use client";

import { useMemo } from "react";
import { formatUnits, parseUnits } from "viem";

type Props = {
  value: string;
  onChange: (s: string) => void;
  streak?: number;
  disabled?: boolean;
};

const streakCap = (s: number): bigint | null => {
  if (s <= 2) return 10_000_000n * 10n ** 18n;
  if (s <= 5) return 50_000_000n * 10n ** 18n;
  if (s <= 9) return 200_000_000n * 10n ** 18n;
  return null;
};

const formatClawdInt = (amt: bigint): string => (amt / 10n ** 18n).toLocaleString();

export const BuyInInput = ({ value, onChange, streak = 0, disabled }: Props) => {
  const cap = streakCap(streak);
  const parsed = useMemo<bigint | null>(() => {
    if (!value) return null;
    try {
      return parseUnits(value, 18);
    } catch {
      return null;
    }
  }, [value]);
  const overCap = parsed !== null && cap !== null && parsed > cap;

  return (
    <div className="form-control w-full">
      <label className="label">
        <span className="label-text">Buy-in (CLAWD)</span>
        <span className="label-text-alt opacity-70 text-xs">
          {cap ? `streak ${streak} cap: ${formatClawdInt(cap)}` : `streak ${streak}: no cap`}
        </span>
      </label>
      <input
        type="text"
        inputMode="decimal"
        className={`input input-bordered w-full ${overCap ? "input-error" : ""}`}
        placeholder="1000000"
        value={value}
        onChange={e => onChange(e.target.value.replace(/[^0-9.]/g, ""))}
        disabled={disabled}
      />
      <label className="label">
        <span className="label-text-alt opacity-70 text-xs">
          ~N/A USD{" "}
          <span className="tooltip tooltip-right" data-tip="CLAWD has no price feed — value shown in token units only.">
            <span className="underline decoration-dotted cursor-help">why?</span>
          </span>
        </span>
        {overCap && <span className="label-text-alt text-error text-xs">Over cap — win a hand to unlock.</span>}
      </label>
    </div>
  );
};

export const parseBuyIn = (s: string): bigint | null => {
  if (!s) return null;
  try {
    return parseUnits(s, 18);
  } catch {
    return null;
  }
};

export const formatBuyIn = (amt: bigint): string => formatUnits(amt, 18);
