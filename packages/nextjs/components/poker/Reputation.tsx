import { FireIcon, TrophyIcon } from "@heroicons/react/24/outline";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";

type Props = { address?: string; compact?: boolean };

export const Reputation = ({ address, compact }: Props) => {
  const { data } = useScaffoldReadContract({
    contractName: "ClawdPoker",
    functionName: "getReputation",
    args: [address],
  });

  if (!address) return null;
  const wins = data ? Number(data[0]) : 0;
  const streak = data ? Number(data[1]) : 0;

  if (compact) {
    return (
      <span className="inline-flex items-center gap-2 text-xs">
        <span className="inline-flex items-center gap-1">
          <TrophyIcon className="w-3.5 h-3.5" />
          {wins}
        </span>
        {streak > 0 && (
          <span className={`inline-flex items-center gap-1 ${streak >= 10 ? "text-amber-400" : "text-orange-400"}`}>
            <FireIcon className="w-3.5 h-3.5" />
            {streak}
          </span>
        )}
      </span>
    );
  }

  return (
    <div className="flex items-center gap-3 text-sm">
      <div className="inline-flex items-center gap-1">
        <TrophyIcon className="w-4 h-4" />
        <span>{wins} wins</span>
      </div>
      <div
        className={`inline-flex items-center gap-1 ${streak >= 10 ? "text-amber-400 font-bold" : streak > 0 ? "text-orange-400" : "opacity-60"}`}
      >
        <FireIcon className="w-4 h-4" />
        <span>{streak} streak</span>
        {streak >= 10 && <span className="badge badge-warning badge-xs">GOLD</span>}
      </div>
    </div>
  );
};

export const streakCap = (streak: number): bigint | null => {
  if (streak <= 2) return 10_000_000n * 10n ** 18n;
  if (streak <= 5) return 50_000_000n * 10n ** 18n;
  if (streak <= 9) return 200_000_000n * 10n ** 18n;
  return null;
};

export const formatClawd = (amt: bigint): string => {
  if (amt === 0n) return "0";
  const whole = amt / 10n ** 18n;
  return whole.toLocaleString();
};
