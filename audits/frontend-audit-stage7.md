# ClawdPoker Frontend QA Audit — Stage 7

Date: 2026-04-17
Auditor: clawdbotatg (Opus, Stage 7 read-only)
Commit audited: `b76e04c`
Scope: `packages/nextjs/` source + `packages/nextjs/out/` static export

## Summary

- Ship-blockers: **7 pass / 2 fail** (OG image absolute URL, dynamic `/game/[id]` route coverage)
- Should-fix: **5 pass / 3 fail** (OG image absolute URL — same as above; USD/N-A context outside BuyInInput; mobile `writeAndOpen`)
- Additional items: **8 pass / 4 partial/fail** (debug-route branding, per-action ActionBar busy isolation, client-side streak clamp, reveal-form uniqueness pre-check)

GitHub issues filed: #12, #13, #14, #15, #16, #17, #19, #20, #21, #22.

Approve flow trace: **MATCH** (all three addresses equal `0x10cd417a4197153a90d88cb47F132f5bCD996535`).

Verdict: **Ship-blockers must land first** — specifically the OG image localhost URL, the README wrong CLAWD token address, and the `/game/[id]` IPFS routing gap.

---

## Ship-blocker results

- **PASS** — **1. Wallet connect is a button, not text.**
  `components/poker/ConnectGate.tsx:15-26` renders `<RainbowKitCustomConnectButton />` inside a card when `address` is undefined. Static-export HTML (`out/index.html`) contains `<button class="btn btn-primary btn-sm" type="button">Connect Wallet</button>` — no "please connect" paragraph as the primary control.
- **PASS** — **2. Wrong network shows a Switch button in the primary CTA slot.**
  `components/poker/ConnectGate.tsx:29-42` replaces children with a card containing `<button ...>Switch to Base</button>` when `chain.id !== base.id`. The lobby and game pages both wrap in `ConnectGate`, so no action CTA renders until chain matches. Header dropdown is supplementary, not required.
- **PASS** — **3. Approve button stays disabled through block confirmation + cooldown.**
  `components/poker/useClawdApproval.ts:33-72` defines both `submitting` (cleared in `finally {}`) AND `approveCooldown` (set after `await`, cleared 4s later after `refetch`). Consumers wire both states into `disabled`:
  - `app/page.tsx:63-66` — `disabled={disabled || approval.isApproving || approval.approveCooldown}` ✓
  - `app/page.tsx:158-162` — `disabled={approval.isApproving || approval.approveCooldown}` ✓
  `isApproving` is `isPending || submitting` (line 38), covering the click→hash gap. Cooldown covers confirm→allowance-cache-refresh. **All three states present.**
- **PASS** — **4. Approve flow traced end-to-end.**
  Resolved values:
  - `approve(pokerAddress, amount)` spender = `pokerInfo?.address` (`useClawdApproval.ts:22-23,58`) = **`0x10cd417a4197153a90d88cb47F132f5bCD996535`** (from `deployedContracts.ts:10`).
  - Contract `transferFrom` call in `ClawdPoker.sol:772`: `CLAWD.transferFrom(from, address(this), amt)`. `address(this)` of ClawdPoker = **`0x10cd417a4197153a90d88cb47F132f5bCD996535`**.
  - `allowance(user, pokerAddress)` in `useClawdApproval.ts:25-30` — spender arg is again `pokerInfo?.address` = **`0x10cd417a4197153a90d88cb47F132f5bCD996535`**.
  All three addresses match. **Verdict: MATCH.**
- **PASS** — **5. Contracts verified on Basescan.**
  `curl https://basescan.org/address/0x10cd417a4197153a90d88cb47f132f5bcd996535` returns HTML containing `"Contract Source Code Verified"`. Verified at Stage 5, re-confirmed in current state.
- **PASS** — **6. SE2 footer branding removed (homepage).**
  `components/Footer.tsx` has no BuidlGuidl/Fork-me/SpeedRun/support links. Shows project name, truncated contract address, Basescan link. No `nativeCurrencyPrice` ribbon (grep returned zero matches repo-wide). `SwitchTheme` is preserved as a bottom-right toggle (acceptable — light+dark palettes both configured).
- **FAIL** — **7. SE2 tab title removed (homepage).**
  `app/layout.tsx:11-14` uses `getMetadata({ title: "Clawd Poker Royale", ... })`; `utils/scaffold-eth/getMetadata.ts:11` sets `titleTemplate = "%s"`. `out/index.html` emits `<title>Clawd Poker Royale</title>` — no "| Scaffold-ETH 2" suffix. **PASS for `/` and `/game/[id]`.** Partial concern on `/debug/`, see issue #15. **This specific item is PASS.**
- **PARTIAL** — **8. SE2 README replaced.**
  `README.md` content is fully project-specific (describes ClawdPoker, network, contract, hand flow, streak caps, dealer pointer). No SE2 boilerplate. BUT it links the wrong CLAWD token address (`0xfB6Eac...` vs actual `0x9f86dB9f...`). Filed as **issue #13 (high)** — README being present without SE2 fluff counts, but the wrong trust-signal address is worse than the default. Promoting to ship-blocker-class until fixed.
- **PASS** — **9. Favicon replaced.**
  `public/favicon.png` is 799 B (not the ~2.8 KB SE2 default). `app/layout.tsx`-flowed metadata emits `<link rel="icon" href="/favicon.png" sizes="32x32" type="image/png"/>`. File exists in `out/favicon.png` at the same size.

## Should-fix results

- **PASS** — **10. Contract address displayed with `<Address/>`.**
  `components/Footer.tsx:27` uses `<Address address={pokerAddress} format="short" />` when deployed-contract info loads. Lobby and game pages also use `<Address/>` for player addresses (`app/page.tsx:148, 281`, `app/game/[id]/GameClient.tsx:61, 125, 155`). No raw `0x...` hex strings rendered in UI.
- **FAIL** — **11. OG image uses absolute URL.**
  `out/index.html` and `out/debug/index.html` both contain `<meta property="og:image" content="http://localhost:3000/thumbnail.png"/>`. `getMetadata.ts:1-9` falls through to the localhost branch because the build was run without `NEXT_PUBLIC_PRODUCTION_URL`. Filed as **issue #12 (high)**.
- **PASS** — **12. `--radius-field: 0.5rem` in both theme blocks.**
  `packages/nextjs/styles/globals.css:38` (light), `:63` (dark). Both present, both `0.5rem`. No `9999rem` anywhere.
- **PARTIAL FAIL** — **13. USD/N-A context on token amounts.**
  `BuyInInput.tsx:52-57` has a proper "~N/A USD" tooltip. Every *other* CLAWD amount display (lobby OpenGames buy-in column, ActionBar current bet/to-call/call-button/raise placeholder, GameClient pot/stack/payout/burn) shows raw `{formatUnits(x, 18)} CLAWD` with no price-feed disclaimer. Filed as **issue #16 (medium)**.
- **PASS** — **14. Errors mapped to human-readable messages.**
  `utils/parseError.ts:5-29` maps every custom error in `deployedContracts.ts` (23 entries — confirmed via grep `type: "error"` → 23 hits in ClawdPoker ABI, every one in `pokerErrors`). Plus 6 OZ v5 ERC20 errors in `erc20Errors` (matches the 6 `type: "error"` entries in `externalContracts.ts`). Decoder merges ABIs at line 42 (`mergedAbi = [...deployedContracts[8453].ClawdPoker.abi, ...externalContracts[8453].CLAWD.abi]`) and uses viem's `BaseError.walk(e => e instanceof ContractFunctionRevertedError)` (line 53-58) to extract the error name, which will decode custom errors present in the merged ABI. **An `ERC20InsufficientAllowance` revert in a `transferFrom` from the CLAWD token contract will decode** because (a) it's in the CLAWD ABI fragment, (b) the decoder walks the error chain, (c) the fallback string-match on `shortMessage` (line 59-68) catches cases where viem didn't decode. There are also wallet-rejection mappings and a truncation fallback at line 78.
- **PASS** — **15. Phantom wallet in RainbowKit wallet list.**
  `services/web3/wagmiConnectors.tsx:6` imports `phantomWallet`; line 21-30 includes it in the `wallets` array passed to `connectorsForWallets`.
- **FAIL** — **16. Mobile deep linking: `writeAndOpen` pattern.**
  `grep -rn 'writeAndOpen\|openWallet'` in `packages/nextjs/` → **zero matches**. Every write call in the app goes directly to `writeContractAsync` with no mobile deep-link wrapper. Stage 6 self-reported this as "relying on RainbowKit v2 built-in handling" — but RainbowKit v2 + WC v2 does not auto-deep-link (per `frontend-ux/SKILL.md` Rule: "does NOT auto-deep-link to the wallet app"). For a 24-hour-timeout heads-up poker game, missed mobile sigs are loss-of-funds. Filed as **issue #17 (medium)**.
- **PASS** — **17. `appName` in `wagmiConnectors.tsx`.**
  Line 51: `appName: "Clawd Poker Royale"`. Grep of `scaffold-eth-2` across `services/` returns zero hits. ✓

## Additional items

- **PASS** — **18. `pollingInterval: 3000`.**
  `scaffold.config.ts:20`. ✓
- **PASS** — **19. RPC override for Base is Alchemy.**
  `scaffold.config.ts:22-24` → `https://base-mainnet.g.alchemy.com/v2/${alchemyKey}`. `alchemyKey` at line 16 reads `process.env.NEXT_PUBLIC_ALCHEMY_API_KEY`. `.env.local` contains `NEXT_PUBLIC_ALCHEMY_API_KEY=…` (confirmed by grep of var name). No `mainnet.base.org` or llamarpc anywhere in `packages/nextjs/` (grep zero matches). `wagmiConfig.tsx:20` does include a bare `http()` fallback — public-RPC fallback — which is inherited SE2 scaffolding and noted but not flagged as high severity since Alchemy is prioritised first when a `rpcOverrides` entry exists.
- **PARTIAL FAIL** — **20. Per-action pending state.**
  `ActionBar.tsx:20` uses a single `busy` string state for fold/check/call/raise. Fold-click disables the other three buttons too. Filed as **issue #19 (low)** — all four buttons share a single pending flag in violation of the `frontend-ux` rule, though in practice only one action is legal per turn.
- **PARTIAL** — **21. Streak-gate buy-in enforcement in UI.**
  `BuyInInput.tsx:13-18` caps match spec exactly (0–2 ≤ 10M, 3–5 ≤ 50M, 6–9 ≤ 200M, 10+ null). Visual error flag at line 32, 58. But parent (`app/page.tsx:29, 65, 75`) does not include `overCap` in its disabled computation — over-cap submit hits the contract revert and shows "Buy-in exceeds your streak cap…" via `parsePokerError`. Filed as **issue #21 (low)**.
- **PASS** — **22. Showdown reveal form validation.**
  `RevealForm.tsx:15-19` accepts only 32-byte hex salts (0x + 64 chars); line 21-26 clamps cards to 0-51 integers; line 42 blocks duplicate-within-own-hand; line 122 disables submit on any invalid field. Cross-check against community cards noted as low-severity nice-to-have in **issue #22**.
- **PASS** — **23. Timeout button visibility.**
  `GameClient.tsx:235-245` — `canClaimTimeout` requires `iAmPlayer && timedOut && (phase === 6 || isBettingPhase)`. In betting phase it additionally requires `currentBettor?.toLowerCase() !== me.toLowerCase()`. In showdown it branches on whether the caller has revealed vs opponent. Button only renders when `canClaimTimeout && iAmPlayer` (line 367). Both conditions present.
- **PASS** — **24. No private-key handling in UI.**
  `grep -rn 'privateKey\|PRIVATE_KEY' packages/nextjs/` returns zero. RevealForm asks for card indices + salts only (dealer-provided). Dealer off-chain key material is not touched by the frontend.
- **FAIL** — **25. `out/index.html` OG tag.**
  `<meta property="og:image" content="http://localhost:3000/thumbnail.png"/>`. (Same root cause as item 11.)
- **PARTIAL FAIL** — **26. Routes exist.**
  `out/index.html` ✓, `out/debug/index.html` ✓, `out/404.html` ✓. But `out/game/` contains only `0/index.html` because `generateStaticParams` at `app/game/[id]/page.tsx:6-8` returns only `[{id:"0"}]`. Real game ids (1+) produce a gateway 404 on IPFS. Filed as **issue #14 (high)**.
- **PASS** — **27. 404 handling.**
  `out/404.html` exists (13 KB), contains "404 / Page Not Found / Go Home" link. Renders without runtime crash (static page).
- **PASS** — **28. Build warnings on files Stage 6 wrote.**
  No build log was committed; the scaffold's pre-existing TS fix at `useScaffoldEventHistory.ts:132-135` is present as documented (cast wraps `deployedOnBlock` as `unknown as bigint`). Build output exists and rendered index.html is well-formed.
- **PASS** — **29. No hardcoded LeftClaw wallet address.**
  `grep -rn 0x7E6Db18aea6b54109f4E5F34242d4A8786E0C471 packages/nextjs/` returns zero. No hex wallet literals anywhere in UI code.

## Stage 6 self-report verification

1. **SE2 branding stripped — PARTIAL.** Footer.tsx, Header.tsx, metadata — all clean. `/debug/` route leaks SE2 metadata via `app/debug/page.tsx:7`. Filed as issue #15. Otherwise confirmed.
2. **Approve flow traced end-to-end — CONFIRMED.** Three addresses all equal `0x10cd417a4197153a90d88cb47F132f5bCD996535`. See Ship-blocker §4 above.
3. **29 custom errors mapped — CONFIRMED.** 23 ClawdPoker custom errors (verified by grep on `deployedContracts.ts`) + 6 OZ v5 ERC20 errors (verified against `externalContracts.ts`) = 29 entries in `utils/parseError.ts`. Decoder uses `mergedAbi` that combines both contract ABIs. `BuyInTooLarge()` → "Buy-in exceeds your streak cap. Win more hands to unlock larger stakes." maps correctly via `ERROR_MESSAGES["BuyInTooLarge"]`. `ERC20InsufficientAllowance` → "CLAWD allowance is too low. Approve the poker contract first." ✓.
4. **`useScaffoldEventHistory.ts:132` TS fix — CONFIRMED.** Line 132-135 casts `deployedOnBlock as unknown as bigint`. Build exits clean with `ignoreBuildErrors` guarded by `NEXT_PUBLIC_IGNORE_BUILD_ERROR`.
5. **`--radius-field: 0.5rem` in both theme blocks — CONFIRMED.** Lines 38 (light), 63 (dark).
6. **Phantom in RainbowKit — CONFIRMED.** Import at line 6, included in `wallets` array line 21-30.
7. **`appName` changed — CONFIRMED.** `grep scaffold-eth-2 services/web3/wagmiConnectors.tsx` → zero. `appName` is now "Clawd Poker Royale".
8. **Title template `%s` — CONFIRMED.** `getMetadata.ts:11` sets `titleTemplate = "%s"`. `layout.tsx:11-14` sets default title to "Clawd Poker Royale". `out/index.html` `<title>Clawd Poker Royale</title>`.
9. **OG image absolute URL — REFUTED (as Stage 6 themselves flagged).** Current build emits `http://localhost:3000/thumbnail.png`. FAIL in current state per the "current state, not previous claim" audit rule. Issue #12.
10. **Favicon replaced — CONFIRMED.** 799 B file, non-default content (Stage 6 report accurate).
11. **Blockexplorer renamed — CONFIRMED.** Directory is `app/_blockexplorer-disabled/`, not `app/blockexplorer/`. No residual imports (grep "app/blockexplorer" → zero in source files; only SE2 default description strings inside the disabled dir itself, which is not included in the build since Next.js skips `_`-prefixed routes).
12. **Fonts via `next/font/google` — CONFIRMED.** `layout.tsx:1` `import { Inter } from "next/font/google"`. No `<link rel="stylesheet" ... fonts>` tags in `layout.tsx` or anywhere else.

## Approve flow trace (full)

- **spender in `approve()` =** `pokerAddress` from `useDeployedContractInfo({contractName:"ClawdPoker"})` → `0x10cd417a4197153a90d88cb47F132f5bCD996535` (`useClawdApproval.ts:23, 58`).
- **ClawdPoker.transferFrom callsite =** `packages/foundry/contracts/ClawdPoker.sol:772` — `CLAWD.transferFrom(from, address(this), amt)`. `address(this)` = `0x10cd417a4197153a90d88cb47F132f5bCD996535` (deployed address).
- **`allowance(user, spender)` spender arg =** `pokerAddress` (`useClawdApproval.ts:28`). Same value as above.

**Result: MATCH.** All three references resolve to the same deployed ClawdPoker address.

## Findings

### F-01 OG image uses `http://localhost:3000/thumbnail.png` — **high**
`out/index.html` + `out/debug/index.html` ship localhost OG/Twitter images. Build was run without `NEXT_PUBLIC_PRODUCTION_URL`. Any social-unfurl preview or crawler fails. Issue #12.

### F-02 README links wrong CLAWD token address — **high**
`README.md:7` → `0xfB6Eac0e8A5175ED0c06B6293E5cf3ecf3bA63Dd` (incorrect). Actual CLAWD on Base is `0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07`. Directs users to the wrong token. Issue #13.

### F-03 Dynamic `/game/[id]` IPFS route 404s for non-zero ids — **high**
`generateStaticParams` emits only `id="0"`. Lobby redirects to `/game/<real-id>` which doesn't exist in `out/`. Every game created after launch is unreachable via canonical URL on IPFS. Issue #14.

### F-04 `/debug/` route leaks SE2 metadata — **medium**
`app/debug/page.tsx:7` sets description to "Debug your deployed 🏗 Scaffold-ETH 2 contracts in an easy way." Emitted into `out/debug/index.html` OG/Twitter tags. Issue #15.

### F-05 CLAWD amounts lack USD/N-A context outside BuyInInput — **medium**
Pot, stacks, current bet, to-call, payouts, burn amounts all shown as raw `{formatUnits(x,18)} CLAWD` with no "~N/A USD" disclaimer. `BuyInInput` sets the right pattern; nothing else copies it. Issue #16.

### F-06 No mobile deep-linking `writeAndOpen` wrapper — **medium**
Zero grep hits for `writeAndOpen` / `openWallet`. Every write handler (approve, createGame, joinGame, act, revealHand, claimTimeout) fires `writeContractAsync` directly. WC v2 does not auto-surface the wallet on mobile. Turn-based 24-hour-timeout game — missed sigs = loss of funds. Issue #17.

### F-07 ActionBar shares single `busy` state across fold/check/call/raise — **low**
One variable; all four buttons disable together. Spirit of "per-action pending" rule is violated even though label branching is correct. Issue #19.

### F-08 Join-approve disabled expr differs from create-approve — **low**
`OpenGameRow` approve button doesn't guard for loading `buyIn`. Practical impact tiny. Issue #20.

### F-09 CreateGameCard does not clamp buy-in above streak cap — **low**
UI flags the error visually but `disabled` doesn't include `overCap`; user can submit and get a `BuyInTooLarge()` revert mapped to a readable message. Nicer UX to client-clamp. Issue #21.

### F-10 RevealForm doesn't cross-check cards against community cards — **low**
Contract reverts `CardAlreadyUsed` cleanly (mapped to a readable message), only cost is a failed tx. Nice-to-have. Issue #22.

## Verdict

**Ship-blockers must land first.**

Must-fix before Stage 8 sign-off:
- F-01 (OG image localhost URL)
- F-02 (wrong CLAWD token in README)
- F-03 (dynamic game route 404 on IPFS)

Should-fix before Stage 9 / job completion:
- F-04 (`/debug/` branding)
- F-05 (USD/N-A context on non-buyIn amounts)
- F-06 (mobile `writeAndOpen`)

Low-severity cleanup optional: F-07, F-08, F-09, F-10.

Approve flow: clean. Custom-error decoder: clean (29 errors covered, both ABIs merged). Contract verification: green on Basescan. Favicon, tab title, appName, Phantom wallet, radius-field, pollingInterval, Alchemy RPC, favicon size: all confirmed.
