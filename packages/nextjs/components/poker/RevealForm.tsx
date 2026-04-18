"use client";

import { useState } from "react";
import { isHex } from "viem";
import { useAccount } from "wagmi";
import { cardLabel } from "~~/components/poker/Card";
import { InlineError } from "~~/components/poker/InlineError";
import { useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { writeAndOpen } from "~~/utils/mobile";
import { parsePokerError } from "~~/utils/parseError";

type Props = {
  gameId: bigint;
  disabled?: boolean;
};

const validSalt = (s: string): `0x${string}` | null => {
  if (!isHex(s)) return null;
  if (s.length !== 66) return null;
  return s as `0x${string}`;
};

const parseCard = (raw: string): number | null => {
  if (raw === "") return null;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 0 || n > 51) return null;
  return n;
};

export const RevealForm = ({ gameId, disabled }: Props) => {
  const { writeContractAsync, isPending } = useScaffoldWriteContract({ contractName: "ClawdPoker" });
  const { connector } = useAccount();
  const [c1, setC1] = useState("");
  const [c2, setC2] = useState("");
  const [s1, setS1] = useState("");
  const [s2, setS2] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const card1 = parseCard(c1);
  const card2 = parseCard(c2);
  const salt1 = validSalt(s1);
  const salt2 = validSalt(s2);

  const dup = card1 !== null && card2 !== null && card1 === card2;
  const ready = card1 !== null && card2 !== null && !dup && salt1 && salt2;

  const onSubmit = async () => {
    if (!ready) return;
    setErr(null);
    setBusy(true);
    try {
      await writeAndOpen(
        () =>
          writeContractAsync({
            functionName: "revealHand",
            args: [gameId, card1!, card2!, salt1!, salt2!],
          }),
        connector?.id,
      );
    } catch (e) {
      setErr(parsePokerError(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="rounded-lg bg-base-100 shadow p-4">
      <h3 className="font-bold text-lg mb-1">Reveal your hole cards</h3>
      <p className="text-xs opacity-70 mb-3">
        Enter the two card values (0–51) and 32-byte salts (0x-prefixed, 64 hex chars) your dealer gave you.
      </p>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        <div>
          <label className="label">
            <span className="label-text text-xs">Card 1 index</span>
            {card1 !== null && <span className="label-text-alt">{cardLabel(card1)}</span>}
          </label>
          <input
            className="input input-bordered input-sm w-full"
            type="text"
            inputMode="numeric"
            placeholder="0–51"
            value={c1}
            onChange={e => setC1(e.target.value.replace(/[^0-9]/g, ""))}
            disabled={disabled || busy}
          />
          <input
            className="input input-bordered input-sm w-full mt-1 font-mono text-xs"
            type="text"
            placeholder="0x + 64 hex chars"
            value={s1}
            onChange={e => setS1(e.target.value.trim())}
            disabled={disabled || busy}
          />
        </div>

        <div>
          <label className="label">
            <span className="label-text text-xs">Card 2 index</span>
            {card2 !== null && <span className="label-text-alt">{cardLabel(card2)}</span>}
          </label>
          <input
            className="input input-bordered input-sm w-full"
            type="text"
            inputMode="numeric"
            placeholder="0–51"
            value={c2}
            onChange={e => setC2(e.target.value.replace(/[^0-9]/g, ""))}
            disabled={disabled || busy}
          />
          <input
            className="input input-bordered input-sm w-full mt-1 font-mono text-xs"
            type="text"
            placeholder="0x + 64 hex chars"
            value={s2}
            onChange={e => setS2(e.target.value.trim())}
            disabled={disabled || busy}
          />
        </div>
      </div>

      {dup && <div className="text-error text-xs mt-2">Card 1 and card 2 must be different values.</div>}

      <button
        className="btn btn-primary w-full mt-4"
        disabled={disabled || busy || isPending || !ready}
        onClick={onSubmit}
      >
        {busy || isPending ? "Revealing..." : "Reveal hand"}
      </button>

      <InlineError message={err} />
    </div>
  );
};
