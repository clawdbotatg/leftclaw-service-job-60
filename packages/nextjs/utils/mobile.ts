/**
 * Mobile deep-link helper. RainbowKit v2 + WalletConnect v2 does NOT
 * auto-surface the wallet app after a `writeContractAsync` call on
 * mobile — the user sees nothing happen until they manually open the
 * wallet. For a 24-hour-timeout heads-up poker game, a missed signature
 * is a direct loss-of-funds risk. `writeAndOpen` fires the write first,
 * then (on mobile only, and only when we are NOT inside an in-app
 * wallet browser) opens the wallet via its deep link after a short
 * delay.
 *
 * Usage:
 *   await writeAndOpen(() => writeContractAsync({ ... }), connectorId);
 */

const MOBILE_UA = /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i;

export const isMobile = (): boolean => {
  if (typeof navigator === "undefined") return false;
  return MOBILE_UA.test(navigator.userAgent);
};

/** Detects whether we're already inside an injected wallet's in-app browser. */
const hasInjectedWallet = (): boolean => {
  if (typeof window === "undefined") return false;

  return !!(window as any).ethereum;
};

/** Resolve a wallet deep link scheme based on the wagmi connector id. */
const deepLinkFor = (connectorId?: string): string | null => {
  if (!connectorId) return null;
  const id = connectorId.toLowerCase();
  if (id.includes("metamask")) return "metamask://";
  if (id.includes("rainbow")) return "rainbow://";
  if (id.includes("phantom")) return "phantom://";
  if (id.includes("coinbase")) return "cbwallet://";
  if (id.includes("walletconnect") || id.includes("wc")) {
    // WalletConnect v2 — no universal deep-link scheme; the session is
    // stored in localStorage and the user must re-open the specific
    // wallet that signed. Best-effort fallback: try wc: scheme.
    return "wc://";
  }
  return null;
};

/**
 * Open the connected wallet's app via its deep link. No-op outside
 * mobile and no-op when an injected wallet is already present
 * (e.g. MetaMask mobile's in-app browser).
 */
export const openWallet = (connectorId?: string): void => {
  if (!isMobile()) return;
  if (hasInjectedWallet()) return;
  const link = deepLinkFor(connectorId);
  if (!link) return;
  try {
    window.location.href = link;
  } catch {
    // Some browsers reject deep-link navigation from code without a
    // user gesture — silently ignore, the user will just have to
    // re-open the wallet manually.
  }
};

/**
 * Wrap a write-contract call so that on mobile we nudge the wallet
 * app to surface after the request is sent. The write promise is
 * returned unchanged; the deep-link is fired on a ~2s delay.
 */
export const writeAndOpen = async <T>(run: () => Promise<T>, connectorId?: string): Promise<T> => {
  // Kick off the write first so the WC bridge actually has a request
  // queued before we try to surface the wallet.
  const promise = run();
  if (isMobile() && !hasInjectedWallet()) {
    setTimeout(() => openWallet(connectorId), 2000);
  }
  return promise;
};
