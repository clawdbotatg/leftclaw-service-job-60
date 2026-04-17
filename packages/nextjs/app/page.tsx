"use client";

import { useState } from "react";
import Link from "next/link";
import { Address } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { formatUnits } from "viem";
import { useAccount } from "wagmi";
import { FireIcon } from "@heroicons/react/24/outline";
import { BuyInInput, parseBuyIn } from "~~/components/poker/BuyInInput";
import { ConnectGate } from "~~/components/poker/ConnectGate";
import { InlineError } from "~~/components/poker/InlineError";
import { Reputation } from "~~/components/poker/Reputation";
import { useClawdApproval } from "~~/components/poker/useClawdApproval";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { parsePokerError } from "~~/utils/parseError";

const CreateGameCard = ({ streak }: { streak: number }) => {
  const [buyIn, setBuyIn] = useState("1000000");
  const [err, setErr] = useState<string | null>(null);
  const [createdId, setCreatedId] = useState<bigint | null>(null);
  const amount = parseBuyIn(buyIn);

  const approval = useClawdApproval();
  const { writeContractAsync, isPending } = useScaffoldWriteContract({ contractName: "ClawdPoker" });
  const [creating, setCreating] = useState(false);

  const enoughAllowance = amount !== null ? approval.hasEnough(amount) : false;
  const disabled = !amount || amount === 0n;

  const onApprove = async () => {
    if (!amount) return;
    setErr(null);
    const ok = await approval.approve(amount);
    if (!ok && approval.error) setErr(approval.error);
  };

  const onCreate = async () => {
    if (!amount) return;
    setErr(null);
    setCreating(true);
    try {
      const hash = await writeContractAsync({ functionName: "createGame", args: [amount] });
      if (hash) setCreatedId(null);
    } catch (e) {
      setErr(parsePokerError(e));
    } finally {
      setCreating(false);
    }
  };

  return (
    <div className="card bg-base-100 shadow-xl">
      <div className="card-body">
        <h2 className="card-title">Open a table</h2>
        <p className="text-sm opacity-70">
          You post the full buy-in; a second player joins for the same amount. Winner takes the pot minus 15% burn.
        </p>
        <BuyInInput value={buyIn} onChange={setBuyIn} streak={streak} disabled={creating || approval.isApproving} />

        <div className="card-actions mt-2">
          {!enoughAllowance ? (
            <button
              className="btn btn-primary w-full"
              disabled={disabled || approval.isApproving || approval.approveCooldown}
              onClick={onApprove}
            >
              {approval.isApproving
                ? "Approving..."
                : approval.approveCooldown
                  ? "Waiting for confirmation..."
                  : "Approve CLAWD"}
            </button>
          ) : (
            <button className="btn btn-success w-full" disabled={disabled || isPending || creating} onClick={onCreate}>
              {isPending || creating ? "Creating game..." : "Create game"}
            </button>
          )}
        </div>

        <InlineError message={err} />
        {createdId !== null && (
          <div className="alert alert-success mt-2 text-sm">
            Game created. Share the open-games list with your opponent.
          </div>
        )}
      </div>
    </div>
  );
};

type OpenGameRowProps = { gameId: bigint };

const OpenGameRow = ({ gameId }: OpenGameRowProps) => {
  const { address: me } = useAccount();
  const { data: game } = useScaffoldReadContract({
    contractName: "ClawdPoker",
    functionName: "getGame",
    args: [gameId],
  });

  const approval = useClawdApproval();
  const { writeContractAsync, isPending } = useScaffoldWriteContract({ contractName: "ClawdPoker" });
  const [joining, setJoining] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  if (!game) {
    return (
      <tr>
        <td colSpan={4} className="text-center text-sm opacity-50">
          Loading game #{gameId.toString()}...
        </td>
      </tr>
    );
  }

  const buyIn = game.buyIn as bigint;
  const playerA = game.playerA as string;
  const isMyGame = me && me.toLowerCase() === playerA.toLowerCase();

  const enoughAllowance = approval.hasEnough(buyIn);

  const onApprove = async () => {
    setErr(null);
    const ok = await approval.approve(buyIn);
    if (!ok && approval.error) setErr(approval.error);
  };

  const onJoin = async (): Promise<boolean> => {
    setErr(null);
    setJoining(true);
    try {
      await writeContractAsync({ functionName: "joinGame", args: [gameId] });
      return true;
    } catch (e) {
      setErr(parsePokerError(e));
      return false;
    } finally {
      setJoining(false);
    }
  };

  return (
    <tr>
      <td className="font-mono">#{gameId.toString()}</td>
      <td>
        <div className="flex items-center gap-2">
          <Address address={playerA} size="xs" />
          <Reputation address={playerA} compact />
        </div>
      </td>
      <td className="font-semibold">{formatUnits(buyIn, 18)} CLAWD</td>
      <td className="min-w-40">
        {isMyGame ? (
          <span className="badge badge-ghost">your game — waiting</span>
        ) : !enoughAllowance ? (
          <button
            className="btn btn-sm btn-primary"
            disabled={approval.isApproving || approval.approveCooldown}
            onClick={onApprove}
          >
            {approval.isApproving ? "Approving..." : approval.approveCooldown ? "Waiting..." : "Approve"}
          </button>
        ) : (
          <button
            className="btn btn-sm btn-success"
            disabled={isPending || joining}
            onClick={async () => {
              const ok = await onJoin();
              if (ok && typeof window !== "undefined") {
                window.location.href = `/game/?id=${gameId.toString()}`;
              }
            }}
          >
            {isPending || joining ? "Joining..." : "Join"}
          </button>
        )}
        <InlineError message={err} />
      </td>
    </tr>
  );
};

const OpenGames = () => {
  const { data: openIds, isLoading } = useScaffoldReadContract({
    contractName: "ClawdPoker",
    functionName: "openGames",
  });

  return (
    <div className="card bg-base-100 shadow-xl">
      <div className="card-body">
        <h2 className="card-title">Open games</h2>
        <p className="text-sm opacity-70">Heads-up tables waiting for a second seat.</p>
        {isLoading ? (
          <div className="skeleton h-24 w-full"></div>
        ) : !openIds || openIds.length === 0 ? (
          <div className="opacity-60 text-sm py-4 text-center">No open tables. Be the first to deal.</div>
        ) : (
          <div className="overflow-x-auto">
            <table className="table table-sm">
              <thead>
                <tr>
                  <th>Game</th>
                  <th>Creator</th>
                  <th>Buy-in</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {(openIds as readonly bigint[]).map(id => (
                  <OpenGameRow key={id.toString()} gameId={id} />
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
};

const MyHistory = () => {
  const { address } = useAccount();
  const { data: totalGames } = useScaffoldReadContract({
    contractName: "ClawdPoker",
    functionName: "nextGameId",
  });

  if (!address) return null;
  const n = totalGames ? Number(totalGames) : 0;
  if (n === 0) return null;
  const start = Math.max(0, n - 10);
  const ids = Array.from({ length: n - start }, (_, i) => BigInt(start + i)).reverse();

  return (
    <div className="card bg-base-100 shadow-xl mt-6">
      <div className="card-body">
        <h2 className="card-title">Recent games</h2>
        <p className="text-sm opacity-70">Up to the last 10 tables on the contract.</p>
        <div className="overflow-x-auto">
          <table className="table table-sm">
            <thead>
              <tr>
                <th>Game</th>
                <th>Players</th>
                <th>Phase</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {ids.map(id => (
                <HistoryRow key={id.toString()} gameId={id} me={address} />
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
};

const HistoryRow = ({ gameId, me }: { gameId: bigint; me: string }) => {
  const { data: game } = useScaffoldReadContract({
    contractName: "ClawdPoker",
    functionName: "getGame",
    args: [gameId],
  });
  if (!game) return null;
  const a = game.playerA as string;
  const b = game.playerB as string;
  const phase = Number(game.phase);
  const phaseNames = ["WAITING", "DEALING", "PREFLOP", "FLOP", "TURN", "RIVER", "SHOWDOWN", "COMPLETE"];
  const isMine = a?.toLowerCase() === me.toLowerCase() || (b && b.toLowerCase() === me.toLowerCase());
  if (!isMine) return null;
  return (
    <tr>
      <td className="font-mono">#{gameId.toString()}</td>
      <td>
        <div className="flex flex-col gap-1 text-xs">
          <Address address={a} size="xs" />
          {b && b !== "0x0000000000000000000000000000000000000000" ? (
            <Address address={b} size="xs" />
          ) : (
            <span className="opacity-50">waiting…</span>
          )}
        </div>
      </td>
      <td>
        <span className="badge badge-outline">{phaseNames[phase] ?? phase}</span>
      </td>
      <td>
        <Link href={`/game/?id=${gameId.toString()}`} className="btn btn-xs btn-ghost">
          open
        </Link>
      </td>
    </tr>
  );
};

const LobbyInner = () => {
  const { address } = useAccount();
  const { data: rep } = useScaffoldReadContract({
    contractName: "ClawdPoker",
    functionName: "getReputation",
    args: [address],
  });
  const streak = rep ? Number(rep[1]) : 0;

  return (
    <div className="container mx-auto px-4 py-8 max-w-5xl">
      <div className="flex flex-col md:flex-row md:items-center md:justify-between gap-3 mb-8">
        <div>
          <h1 className="text-3xl font-bold leading-tight">Clawd Poker Royale</h1>
          <p className="opacity-70 text-sm">Heads-up Texas Hold&apos;em on Base. 15% rake burned.</p>
        </div>
        {address && (
          <div className="flex items-center gap-3 bg-base-100 rounded-lg px-4 py-2 shadow">
            <Address address={address} size="sm" />
            <div className="h-5 w-px bg-base-300" />
            <Reputation address={address} />
            {streak >= 10 && (
              <span className="badge badge-warning gap-1">
                <FireIcon className="w-3 h-3" /> GOLD
              </span>
            )}
          </div>
        )}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <CreateGameCard streak={streak} />
        <OpenGames />
      </div>

      <MyHistory />
    </div>
  );
};

const Lobby: NextPage = () => (
  <ConnectGate>
    <LobbyInner />
  </ConnectGate>
);

export default Lobby;
