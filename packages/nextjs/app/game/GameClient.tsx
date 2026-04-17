"use client";

import { Suspense, useMemo } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { Address } from "@scaffold-ui/components";
import { useAccount } from "wagmi";
import { ArrowLeftIcon } from "@heroicons/react/24/outline";
import { ActionBar } from "~~/components/poker/ActionBar";
import { PokerCard } from "~~/components/poker/Card";
import { ClawdAmount } from "~~/components/poker/ClawdAmount";
import { ConnectGate } from "~~/components/poker/ConnectGate";
import { CountdownTimer, hasTimedOut } from "~~/components/poker/CountdownTimer";
import { PhaseBadge, phaseName } from "~~/components/poker/PhaseBadge";
import { Reputation } from "~~/components/poker/Reputation";
import { RevealForm } from "~~/components/poker/RevealForm";
import { TimeoutClaim } from "~~/components/poker/TimeoutClaim";
import { useScaffoldEventHistory, useScaffoldReadContract } from "~~/hooks/scaffold-eth";

const ZERO_ADDR = "0x0000000000000000000000000000000000000000";

const PlayerSeat = ({
  label,
  address,
  stack,
  isTurn,
  isMe,
  revealed,
  holeCards,
}: {
  label: string;
  address?: string;
  stack: bigint;
  isTurn: boolean;
  isMe: boolean;
  revealed: boolean;
  holeCards: readonly [number, number] | null;
}) => {
  if (!address || address === ZERO_ADDR) {
    return (
      <div className="rounded-lg bg-base-100/80 backdrop-blur shadow p-3 min-w-48 opacity-60">
        <div className="text-xs uppercase opacity-70 mb-1">{label}</div>
        <div className="text-sm italic opacity-70">Waiting for a second player…</div>
      </div>
    );
  }

  const showCards = isMe ? revealed : revealed;
  return (
    <div
      className={`rounded-lg bg-base-100/90 backdrop-blur shadow p-3 min-w-48 ${isTurn ? "ring-2 ring-warning" : ""}`}
    >
      <div className="flex items-center justify-between mb-2">
        <span className="text-xs uppercase opacity-70">
          {label}
          {isMe && " (you)"}
        </span>
        {isTurn && <span className="badge badge-warning badge-sm">to act</span>}
      </div>
      <div className="flex items-center gap-2 mb-1">
        <Address address={address} size="xs" />
      </div>
      <Reputation address={address} compact />
      <div className="mt-2 text-sm">
        Stack: <ClawdAmount value={stack} />
      </div>
      <div className="flex gap-1 mt-2">
        {showCards && holeCards ? (
          <>
            <PokerCard card={holeCards[0]} size="sm" />
            <PokerCard card={holeCards[1]} size="sm" />
          </>
        ) : (
          <>
            <PokerCard faceDown size="sm" />
            <PokerCard faceDown size="sm" />
          </>
        )}
      </div>
    </div>
  );
};

const CompleteCard = ({ gameId, winner }: { gameId: bigint; winner: string }) => {
  const { data: events } = useScaffoldEventHistory({
    contractName: "ClawdPoker",
    eventName: "GameComplete",
    filters: { gameId },
  });
  const { data: splits } = useScaffoldEventHistory({
    contractName: "ClawdPoker",
    eventName: "GameSplit",
    filters: { gameId },
  });

  const summary = useMemo(() => {
    const ev = events?.[0]?.args;
    if (ev) {
      return {
        kind: "win" as const,
        winner: ev.winner as string,
        payout: ev.payout as bigint,
        burn: ev.burn as bigint,
      };
    }
    const sp = splits?.[0]?.args;
    if (sp) {
      return {
        kind: "split" as const,
        perPlayer: sp.perPlayer as bigint,
        burn: sp.burn as bigint,
      };
    }
    return null;
  }, [events, splits]);

  return (
    <div className="card bg-base-100 shadow-xl">
      <div className="card-body items-center text-center">
        <h2 className="card-title">Hand complete</h2>
        {summary ? (
          summary.kind === "win" ? (
            <>
              <div className="text-sm opacity-70">Winner</div>
              <Address address={summary.winner} />
              <div className="grid grid-cols-2 gap-6 mt-3">
                <div>
                  <div className="text-xs opacity-60">Payout</div>
                  <div className="font-bold">
                    <ClawdAmount value={summary.payout} />
                  </div>
                </div>
                <div>
                  <div className="text-xs opacity-60">Burned</div>
                  <div className="font-bold">
                    <ClawdAmount value={summary.burn} />
                  </div>
                </div>
              </div>
            </>
          ) : (
            <>
              <div className="text-sm opacity-70">Tie — pot split</div>
              <div className="grid grid-cols-2 gap-6 mt-3">
                <div>
                  <div className="text-xs opacity-60">Per player</div>
                  <div className="font-bold">
                    <ClawdAmount value={summary.perPlayer} />
                  </div>
                </div>
                <div>
                  <div className="text-xs opacity-60">Burned</div>
                  <div className="font-bold">
                    <ClawdAmount value={summary.burn} />
                  </div>
                </div>
              </div>
            </>
          )
        ) : winner && winner !== ZERO_ADDR ? (
          <>
            <div className="text-sm opacity-70">Winner</div>
            <Address address={winner} />
            <div className="text-xs opacity-60 mt-2">Loading settlement details…</div>
          </>
        ) : (
          <div className="text-sm opacity-70">No winner — pot was refunded.</div>
        )}
        <Link href="/" className="btn btn-primary mt-4">
          <ArrowLeftIcon className="w-4 h-4" /> Back to lobby
        </Link>
        <div className="text-xs opacity-50 mt-2">Game #{gameId.toString()}</div>
      </div>
    </div>
  );
};

const GameView = ({ gameId }: { gameId: bigint }) => {
  const { address: me } = useAccount();

  const { data: game } = useScaffoldReadContract({
    contractName: "ClawdPoker",
    functionName: "getGame",
    args: [gameId],
  });
  const { data: timeoutSeconds } = useScaffoldReadContract({
    contractName: "ClawdPoker",
    functionName: "TIMEOUT_SECONDS",
  });

  if (!game) {
    return (
      <div className="container mx-auto p-8 max-w-4xl">
        <div className="skeleton h-96 w-full"></div>
      </div>
    );
  }

  const phase = Number(game.phase);
  const phaseText = phaseName(phase);
  const isTerminal = phase === 7; // COMPLETE
  const a = game.playerA as string;
  const b = game.playerB as string;
  const iAmA = !!me && me.toLowerCase() === a?.toLowerCase();
  const iAmB = !!me && me.toLowerCase() === b?.toLowerCase();
  const iAmPlayer = iAmA || iAmB;

  const community: readonly number[] = game.communityCards as unknown as readonly number[];
  const revealedA = (game.handRevealed as unknown as readonly boolean[])[0];
  const revealedB = (game.handRevealed as unknown as readonly boolean[])[1];

  const holeA = [
    (game.holeCardsA as unknown as readonly number[])[0],
    (game.holeCardsA as unknown as readonly number[])[1],
  ] as const;
  const holeB = [
    (game.holeCardsB as unknown as readonly number[])[0],
    (game.holeCardsB as unknown as readonly number[])[1],
  ] as const;

  const stackA = game.stackA as bigint;
  const stackB = game.stackB as bigint;
  const pot = game.pot as bigint;
  const currentBet = game.currentBet as bigint;
  const currentBettor = game.currentBettor as string;
  const lastActionTime = game.lastActionTime as bigint;
  const timedOut = timeoutSeconds ? hasTimedOut(lastActionTime, timeoutSeconds as bigint) : false;

  const isBettingPhase = phase >= 2 && phase <= 5;
  const isMyTurn = isBettingPhase && iAmPlayer && currentBettor?.toLowerCase() === me?.toLowerCase();

  // How many community cards to show based on phase
  const visibleCommunity: number = (() => {
    if (phase <= 2) return 0; // WAITING/DEALING/PREFLOP: none
    if (phase === 3) return 3; // FLOP
    if (phase === 4) return 4; // TURN
    return 5; // RIVER / SHOWDOWN / COMPLETE
  })();

  // Timeout claim visibility:
  //  - betting phase: non-currentBettor can claim
  //  - showdown: the player who has revealed can claim against the one who hasn't
  let canClaimTimeout = false;
  if (iAmPlayer && timedOut && (phase === 6 || isBettingPhase)) {
    if (phase === 6) {
      const myRevealed = iAmA ? revealedA : revealedB;
      const oppRevealed = iAmA ? revealedB : revealedA;
      if (myRevealed && !oppRevealed) canClaimTimeout = true;
      if (!myRevealed && !oppRevealed) canClaimTimeout = true;
    } else if (isBettingPhase && me && currentBettor?.toLowerCase() !== me.toLowerCase()) {
      canClaimTimeout = true;
    }
  }

  const myHasRevealed = iAmA ? revealedA : iAmB ? revealedB : false;
  const showRevealForm = phase === 6 && iAmPlayer && !myHasRevealed;

  if (isTerminal) {
    return (
      <div className="container mx-auto px-4 py-6 max-w-3xl">
        <Link href="/" className="btn btn-ghost btn-sm mb-4">
          <ArrowLeftIcon className="w-4 h-4" /> Lobby
        </Link>
        <CompleteCard gameId={gameId} winner={game.winner as string} />
      </div>
    );
  }

  // Own / opponent mapping
  const topAddr = iAmA ? b : a;
  const topStack = iAmA ? stackB : stackA;
  const topRevealed = iAmA ? revealedB : revealedA;
  const topHole = iAmA ? holeB : holeA;
  const topIsTurn = isBettingPhase && currentBettor?.toLowerCase() === (iAmA ? b : a)?.toLowerCase();

  const botAddr = iAmPlayer ? (iAmA ? a : b) : a;
  const botStack = iAmPlayer ? (iAmA ? stackA : stackB) : stackA;
  const botRevealed = iAmPlayer ? (iAmA ? revealedA : revealedB) : revealedA;
  const botHole = iAmPlayer ? (iAmA ? holeA : holeB) : holeA;
  const botIsTurn =
    isBettingPhase && currentBettor?.toLowerCase() === (iAmPlayer ? me?.toLowerCase() : a?.toLowerCase());

  return (
    <div className="container mx-auto px-4 py-6 max-w-4xl">
      <div className="flex items-center justify-between mb-4">
        <Link href="/" className="btn btn-ghost btn-sm">
          <ArrowLeftIcon className="w-4 h-4" /> Lobby
        </Link>
        <div className="flex items-center gap-3">
          <span className="font-mono text-sm opacity-60">Game #{gameId.toString()}</span>
          <PhaseBadge phase={phase} />
        </div>
      </div>

      {/* Felt table */}
      <div
        className="relative rounded-3xl shadow-2xl p-6 md:p-10 min-h-[560px] flex flex-col justify-between"
        style={{
          background: "radial-gradient(ellipse at center, #0b7d3e 0%, #0a5f30 55%, #053d1f 100%)",
          boxShadow: "inset 0 0 120px rgba(0,0,0,0.45), 0 20px 50px rgba(0,0,0,0.4)",
        }}
      >
        {/* Top seat (opponent when I'm a player) */}
        <div className="flex justify-center">
          <PlayerSeat
            label={iAmA ? "Player B" : iAmB ? "Player A" : "Player B"}
            address={topAddr}
            stack={topStack}
            isTurn={topIsTurn}
            isMe={false}
            revealed={!!topRevealed}
            holeCards={[topHole[0], topHole[1]]}
          />
        </div>

        {/* Middle: pot + community */}
        <div className="flex flex-col items-center gap-4 my-6">
          <div className="text-center">
            <div className="text-xs uppercase tracking-widest text-emerald-100/80">Pot</div>
            <div className="text-3xl font-black text-white drop-shadow">
              <ClawdAmount value={pot} variant="stacked" />
            </div>
          </div>
          <div className="flex gap-2 md:gap-3">
            {[0, 1, 2, 3, 4].map(i => {
              const dealt = i < visibleCommunity && community[i] !== undefined;
              return <PokerCard key={i} faceDown={!dealt} card={dealt ? community[i] : undefined} size="md" />;
            })}
          </div>
          <div className="text-xs text-emerald-100/70">Phase: {phaseText}</div>
          <CountdownTimer
            lastActionTime={lastActionTime}
            timeoutSeconds={(timeoutSeconds as bigint | undefined) ?? 86400n}
          />
        </div>

        {/* Bottom seat (me, or player A if spectator) */}
        <div className="flex justify-center">
          <PlayerSeat
            label={iAmA ? "Player A" : iAmB ? "Player B" : "Player A"}
            address={botAddr}
            stack={botStack}
            isTurn={botIsTurn}
            isMe={iAmPlayer}
            revealed={!!botRevealed}
            holeCards={[botHole[0], botHole[1]]}
          />
        </div>
      </div>

      {/* Below-the-table UI */}
      <div className="mt-6 grid grid-cols-1 gap-4">
        {iAmPlayer && isBettingPhase && (
          <ActionBar gameId={gameId} currentBet={currentBet} myStack={iAmA ? stackA : stackB} isMyTurn={!!isMyTurn} />
        )}

        {showRevealForm && <RevealForm gameId={gameId} />}

        {phase === 0 && (
          <div className="alert alert-info text-sm">
            Waiting for a second player to join. Share this URL to invite one.
          </div>
        )}

        {phase === 1 && (
          <div className="alert alert-info text-sm">
            VRF is seeding the deck and the dealer is committing — this usually takes under a minute.
          </div>
        )}

        {phase === 6 && !iAmPlayer && (
          <div className="alert alert-info text-sm">Showdown. Waiting for both players to reveal their hole cards.</div>
        )}

        {canClaimTimeout && iAmPlayer && <TimeoutClaim gameId={gameId} show />}
      </div>
    </div>
  );
};

const GameClientInner = () => {
  const searchParams = useSearchParams();
  const raw = searchParams?.get("id");
  const gameId = useMemo(() => {
    if (!raw) return null;
    try {
      return BigInt(raw);
    } catch {
      return null;
    }
  }, [raw]);

  return (
    <ConnectGate>
      {gameId === null ? (
        <div className="container mx-auto p-8 text-center opacity-60">
          No game id provided. Return to the{" "}
          <Link href="/" className="link">
            lobby
          </Link>{" "}
          to pick a table.
        </div>
      ) : (
        <GameView gameId={gameId} />
      )}
    </ConnectGate>
  );
};

export const GameClient = () => (
  <Suspense fallback={<div className="container mx-auto p-8 text-center opacity-60">Loading…</div>}>
    <GameClientInner />
  </Suspense>
);
