"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { InlineError } from "~~/components/poker/InlineError";
import { useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { writeAndOpen } from "~~/utils/mobile";
import { parsePokerError } from "~~/utils/parseError";

export const TimeoutClaim = ({ gameId, show }: { gameId: bigint; show: boolean }) => {
  const { writeContractAsync, isPending } = useScaffoldWriteContract({ contractName: "ClawdPoker" });
  const { connector } = useAccount();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  if (!show) return null;

  const onClaim = async () => {
    setErr(null);
    setBusy(true);
    try {
      await writeAndOpen(() => writeContractAsync({ functionName: "claimTimeout", args: [gameId] }), connector?.id);
    } catch (e) {
      setErr(parsePokerError(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="mt-2">
      <button className="btn btn-warning btn-sm" disabled={busy || isPending} onClick={onClaim}>
        {busy || isPending ? "Claiming..." : "Claim Timeout"}
      </button>
      <InlineError message={err} />
    </div>
  );
};
