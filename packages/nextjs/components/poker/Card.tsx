// Card encoding (documented here once and used everywhere):
//   suit = card / 13          0=♣ clubs, 1=♦ diamonds, 2=♥ hearts, 3=♠ spades
//   rank = card % 13          0=2, 1=3, 2=4, ..., 8=T, 9=J, 10=Q, 11=K, 12=A

export const SUITS = ["\u2663", "\u2666", "\u2665", "\u2660"] as const;
export const SUIT_NAMES = ["clubs", "diamonds", "hearts", "spades"] as const;
export const RANKS = ["2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K", "A"] as const;

export const suitOf = (card: number) => Math.floor(card / 13);
export const rankOf = (card: number) => card % 13;

export const cardLabel = (card: number): string => {
  if (card < 0 || card > 51) return "??";
  return `${RANKS[rankOf(card)]}${SUITS[suitOf(card)]}`;
};

type CardProps = {
  card?: number | null;
  faceDown?: boolean;
  size?: "sm" | "md" | "lg";
};

const sizeClasses = {
  sm: "w-10 h-14 text-sm",
  md: "w-14 h-20 text-lg",
  lg: "w-20 h-28 text-2xl",
};

export const PokerCard = ({ card, faceDown, size = "md" }: CardProps) => {
  const dim = sizeClasses[size];
  if (faceDown || card === undefined || card === null) {
    return (
      <div
        className={`${dim} rounded-md bg-gradient-to-br from-indigo-700 to-indigo-950 border border-indigo-900 shadow-md flex items-center justify-center text-white/20`}
        aria-label="face down card"
      >
        <div className="w-3/4 h-3/4 rounded-sm border border-white/10 flex items-center justify-center text-white/30 font-bold">
          CP
        </div>
      </div>
    );
  }
  const suit = suitOf(card);
  const rank = RANKS[rankOf(card)];
  const isRed = suit === 1 || suit === 2;
  const color = isRed ? "text-red-500" : "text-neutral-900";
  return (
    <div
      className={`${dim} rounded-md bg-white border border-neutral-300 shadow-md flex flex-col items-center justify-center font-bold ${color}`}
      aria-label={`${rank} of ${SUIT_NAMES[suit]}`}
    >
      <span>{rank}</span>
      <span className="text-xl leading-none">{SUITS[suit]}</span>
    </div>
  );
};
