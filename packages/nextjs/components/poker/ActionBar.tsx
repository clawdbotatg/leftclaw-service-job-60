"use client";

import { useState } from "react";
import { formatUnits, parseUnits } from "viem";
import { InlineError } from "~~/components/poker/InlineError";
import { useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { parsePokerError } from "~~/utils/parseError";

type Props = {
  gameId: bigint;
  currentBet: bigint;
  myStack: bigint;
  committedThisRound?: bigint;
  isMyTurn: boolean;
  disabled?: boolean;
};

export const ActionBar = ({ gameId, currentBet, myStack, committedThisRound = 0n, isMyTurn, disabled }: Props) => {
  const { writeContractAsync, isPending } = useScaffoldWriteContract({ contractName: "ClawdPoker" });
  const [busy, setBusy] = useState<"fold" | "check" | "call" | "raise" | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [raiseStr, setRaiseStr] = useState("");

  const canCheck = currentBet === 0n;
  const canCall = currentBet > 0n;
  const owed = currentBet > committedThisRound ? currentBet - committedThisRound : 0n;

  const submit = async (action: 0 | 1 | 2 | 3, amount: bigint) => {
    setErr(null);
    setBusy(action === 0 ? "fold" : action === 1 ? "check" : action === 2 ? "call" : "raise");
    try {
      await writeContractAsync({ functionName: "act", args: [gameId, action, amount] });
    } catch (e) {
      setErr(parsePokerError(e));
    } finally {
      setBusy(null);
    }
  };

  const onRaise = async () => {
    let amount: bigint;
    try {
      amount = parseUnits(raiseStr || "0", 18);
    } catch {
      setErr("Invalid raise amount.");
      return;
    }
    if (amount <= currentBet) {
      setErr("Raise must exceed the current bet.");
      return;
    }
    await submit(3, amount);
  };

  const outerDisabled = !isMyTurn || disabled || !!busy || isPending;

  return (
    <div className="rounded-lg bg-base-100 shadow p-4">
      <div className="flex items-center justify-between mb-3">
        <div className="text-sm opacity-70">{isMyTurn ? "Your turn" : "Waiting for opponent"}</div>
        <div className="text-xs opacity-60">
          Current bet: <span className="font-semibold">{formatUnits(currentBet, 18)} CLAWD</span>
          {owed > 0n && isMyTurn && (
            <span className="ml-2">
              · To call: <span className="font-semibold">{formatUnits(owed, 18)}</span>
            </span>
          )}
        </div>
      </div>

      <div className="grid grid-cols-2 md:grid-cols-4 gap-2">
        <button className="btn btn-error btn-sm" disabled={outerDisabled} onClick={() => submit(0, 0n)}>
          {busy === "fold" ? "Folding..." : "Fold"}
        </button>
        <button
          className="btn btn-ghost btn-sm"
          disabled={outerDisabled || !canCheck}
          onClick={() => submit(1, 0n)}
          title={canCheck ? "Check" : "Check not available — there is a bet"}
        >
          {busy === "check" ? "Checking..." : "Check"}
        </button>
        <button
          className="btn btn-primary btn-sm"
          disabled={outerDisabled || !canCall}
          onClick={() => submit(2, 0n)}
          title={canCall ? `Call ${formatUnits(owed, 18)}` : "Call not available"}
        >
          {busy === "call"
            ? "Calling..."
            : canCall
              ? `Call ${formatUnits(owed > myStack ? myStack : owed, 18)}`
              : "Call"}
        </button>
        <div className="flex gap-1">
          <input
            className="input input-bordered input-sm flex-1 min-w-0"
            type="text"
            inputMode="decimal"
            placeholder={`> ${formatUnits(currentBet, 18)}`}
            value={raiseStr}
            onChange={e => setRaiseStr(e.target.value.replace(/[^0-9.]/g, ""))}
            disabled={outerDisabled}
          />
          <button className="btn btn-warning btn-sm" disabled={outerDisabled || !raiseStr} onClick={onRaise}>
            {busy === "raise" ? "..." : "Raise"}
          </button>
        </div>
      </div>

      <InlineError message={err} />
    </div>
  );
};
