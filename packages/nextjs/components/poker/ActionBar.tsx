"use client";

import { useState } from "react";
import { formatUnits, parseUnits } from "viem";
import { useAccount } from "wagmi";
import { ClawdAmount } from "~~/components/poker/ClawdAmount";
import { InlineError } from "~~/components/poker/InlineError";
import { useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { writeAndOpen } from "~~/utils/mobile";
import { parsePokerError } from "~~/utils/parseError";

type Props = {
  gameId: bigint;
  currentBet: bigint;
  myStack: bigint;
  committedThisRound?: bigint;
  isMyTurn: boolean;
  disabled?: boolean;
};

// Separate boolean per action so only the clicked button shows a
// spinner — the other three keep their idle labels and stay
// disable-able by the outer turn/pending state instead of by each
// other. Only one action is legal per turn anyway, but the shared
// `busy` string previously made the raise input freeze while a fold
// request was in flight, which felt wrong.
type BusyState = { fold: boolean; check: boolean; call: boolean; raise: boolean };
const NOT_BUSY: BusyState = { fold: false, check: false, call: false, raise: false };

export const ActionBar = ({ gameId, currentBet, myStack, committedThisRound = 0n, isMyTurn, disabled }: Props) => {
  const { writeContractAsync, isPending } = useScaffoldWriteContract({ contractName: "ClawdPoker" });
  const { connector } = useAccount();
  const [busy, setBusy] = useState<BusyState>(NOT_BUSY);
  const [err, setErr] = useState<string | null>(null);
  const [raiseStr, setRaiseStr] = useState("");

  const anyBusy = busy.fold || busy.check || busy.call || busy.raise;
  const canCheck = currentBet === 0n;
  const canCall = currentBet > 0n;
  const owed = currentBet > committedThisRound ? currentBet - committedThisRound : 0n;

  const submit = async (which: keyof BusyState, action: 0 | 1 | 2 | 3, amount: bigint) => {
    setErr(null);
    setBusy(b => ({ ...b, [which]: true }));
    try {
      await writeAndOpen(
        () => writeContractAsync({ functionName: "act", args: [gameId, action, amount] }),
        connector?.id,
      );
    } catch (e) {
      setErr(parsePokerError(e));
    } finally {
      setBusy(b => ({ ...b, [which]: false }));
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
    await submit("raise", 3, amount);
  };

  const base = !isMyTurn || disabled || isPending;

  return (
    <div className="rounded-lg bg-base-100 shadow p-4">
      <div className="flex items-center justify-between mb-3">
        <div className="text-sm opacity-70">{isMyTurn ? "Your turn" : "Waiting for opponent"}</div>
        <div className="text-xs opacity-60">
          Current bet: <ClawdAmount value={currentBet} />
          {owed > 0n && isMyTurn && (
            <span className="ml-2">
              · To call: <ClawdAmount value={owed} />
            </span>
          )}
        </div>
      </div>

      <div className="grid grid-cols-2 md:grid-cols-4 gap-2">
        <button className="btn btn-error btn-sm" disabled={base || busy.fold} onClick={() => submit("fold", 0, 0n)}>
          {busy.fold ? "Folding..." : "Fold"}
        </button>
        <button
          className="btn btn-ghost btn-sm"
          disabled={base || busy.check || !canCheck}
          onClick={() => submit("check", 1, 0n)}
          title={canCheck ? "Check" : "Check not available — there is a bet"}
        >
          {busy.check ? "Checking..." : "Check"}
        </button>
        <button
          className="btn btn-primary btn-sm"
          disabled={base || busy.call || !canCall}
          onClick={() => submit("call", 2, 0n)}
          title={canCall ? `Call ${formatUnits(owed, 18)}` : "Call not available"}
        >
          {busy.call ? "Calling..." : canCall ? `Call ${formatUnits(owed > myStack ? myStack : owed, 18)}` : "Call"}
        </button>
        <div className="flex gap-1">
          <input
            className="input input-bordered input-sm flex-1 min-w-0"
            type="text"
            inputMode="decimal"
            placeholder={`> ${formatUnits(currentBet, 18)}`}
            value={raiseStr}
            onChange={e => setRaiseStr(e.target.value.replace(/[^0-9.]/g, ""))}
            disabled={base || busy.raise}
          />
          <button className="btn btn-warning btn-sm" disabled={base || busy.raise || !raiseStr} onClick={onRaise}>
            {busy.raise ? "..." : "Raise"}
          </button>
        </div>
      </div>

      {anyBusy && isPending && <span className="sr-only">Submitting action…</span>}
      <InlineError message={err} />
    </div>
  );
};
