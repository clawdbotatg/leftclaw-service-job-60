import { BaseError, ContractFunctionRevertedError } from "viem";
import deployedContracts from "~~/contracts/deployedContracts";
import externalContracts from "~~/contracts/externalContracts";

const pokerErrors: Record<string, string> = {
  AlreadyJoined: "This game already has a second player.",
  BadCommunityCount: "Dealer posted the wrong number of community cards.",
  BadRevealIndex: "Invalid card index — cards must be 0-51 and unique.",
  BuyInTooLarge: "Buy-in exceeds your streak cap. Win more hands to unlock larger stakes.",
  CannotJoinOwnGame: "You can't join a game you created.",
  CardAlreadyUsed: "That card value was already revealed in this deck.",
  CommitMismatch: "Card + salt don't match the committed hash. Check both inputs.",
  DeckAlreadyCommitted: "Dealer has already committed this deck.",
  DeckNotReady: "VRF seed hasn't landed yet. Give it a moment.",
  GameNotFound: "No game at that id.",
  IndexAlreadyRevealed: "That card slot was already revealed.",
  InsufficientStack: "Not enough chips in your stack for that raise.",
  InvalidAction: "That action isn't legal right now.",
  InvalidRaise: "Raise must be strictly larger than the current bet.",
  NotParticipant: "Only the two seated players can act on this game.",
  NotYourTurn: "It's not your turn.",
  OnlyCoordinatorCanFulfill: "VRF callback came from the wrong coordinator.",
  OnlyOwnerOrCoordinator: "Only the contract owner or VRF coordinator can call this.",
  TimeoutNotReached: "The 24-hour timeout hasn't elapsed yet.",
  TokenTransferFailed: "CLAWD transfer failed.",
  WrongPhase: "This game isn't in a phase that allows that action.",
  ZeroAddress: "Zero address is not allowed.",
  ZeroBuyIn: "Buy-in must be greater than zero.",
};

const erc20Errors: Record<string, string> = {
  ERC20InsufficientAllowance: "CLAWD allowance is too low. Approve the poker contract first.",
  ERC20InsufficientBalance: "Not enough CLAWD in your wallet.",
  ERC20InvalidApprover: "Invalid CLAWD approver address.",
  ERC20InvalidReceiver: "Invalid CLAWD receiver address.",
  ERC20InvalidSender: "Invalid CLAWD sender address.",
  ERC20InvalidSpender: "Invalid CLAWD spender address.",
};

const ERROR_MESSAGES: Record<string, string> = { ...pokerErrors, ...erc20Errors };

const mergedAbi = [...(deployedContracts[8453]?.ClawdPoker?.abi ?? []), ...(externalContracts[8453]?.CLAWD?.abi ?? [])];

export const getMergedAbi = () => mergedAbi;

export const parsePokerError = (err: unknown): string => {
  if (!err) return "Unknown error.";
  if (typeof err === "string") return err;

  const anyErr = err as { message?: string; shortMessage?: string; cause?: unknown };

  if (err instanceof BaseError) {
    const revertError = err.walk(e => e instanceof ContractFunctionRevertedError);
    if (revertError instanceof ContractFunctionRevertedError) {
      const name = revertError.data?.errorName;
      if (name && ERROR_MESSAGES[name]) return ERROR_MESSAGES[name];
      if (name) return name;
    }
    if (err.shortMessage) {
      const matched = Object.keys(ERROR_MESSAGES).find(n => err.shortMessage?.includes(n));
      if (matched) return ERROR_MESSAGES[matched];
      if (
        err.shortMessage.toLowerCase().includes("user rejected") ||
        err.shortMessage.toLowerCase().includes("user denied")
      ) {
        return "Transaction rejected in wallet.";
      }
      return err.shortMessage;
    }
  }

  const raw = anyErr.shortMessage || anyErr.message || String(err);
  if (raw.toLowerCase().includes("user rejected") || raw.toLowerCase().includes("user denied")) {
    return "Transaction rejected in wallet.";
  }
  const matched = Object.keys(ERROR_MESSAGES).find(n => raw.includes(n));
  if (matched) return ERROR_MESSAGES[matched];
  return raw.length > 200 ? raw.slice(0, 200) + "…" : raw;
};
