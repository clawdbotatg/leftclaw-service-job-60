# Clawd Poker Royale

Heads-up Texas Hold'em on Base mainnet, settled in **CLAWD**. Every hand burns 15% of the pot through the CLAWD burn hook — the rest is paid to the winner (or split on showdown ties).

- **Network:** Base mainnet (chainId `8453`)
- **Contract:** `ClawdPoker` at [`0x10cd417a4197153a90d88cb47f132f5bcd996535`](https://basescan.org/address/0x10cd417a4197153a90d88cb47f132f5bcd996535)
- **CLAWD token:** [`0xfB6Eac0e8A5175ED0c06B6293E5cf3ecf3bA63Dd`](https://basescan.org/token/0xfB6Eac0e8A5175ED0c06B6293E5cf3ecf3bA63Dd)
- **Randomness:** Chainlink VRF v2.5
- **Dealer:** off-chain service that deals cards via commit-reveal and posts community cards

## How a hand works

1. Either player calls `createGame(buyIn)` after approving CLAWD to the poker contract. Their buy-in is pulled into escrow.
2. A second player joins with `joinGame(id, buyIn)` — same approve-then-call flow.
3. The dealer requests VRF randomness, commits 52 card hashes on-chain, and posts `PREFLOP`.
4. Players `act(id, action, amount)` through **preflop → flop → turn → river** (fold, check, call, raise).
5. At showdown, each player calls `revealHand(id, c1, c2, salt1, salt2)` with the hole cards and salts the dealer gave them. The contract verifies the commits and evaluates the board.
6. Winner takes the pot; 15% is burned via `IClawdBurnable.burn`. Timeouts can be claimed if the opponent or dealer stalls.

## Streak-gated buy-ins

Wins from `getReputation(addr)` gate max buy-in:

| Wins | Buy-in cap |
| ---- | ---------- |
| 0–2 | 10M CLAWD |
| 3–5 | 50M CLAWD |
| 6–9 | 200M CLAWD |
| 10+ | Unlimited |

## Stack

- **Contracts:** Foundry + OpenZeppelin v5 + Chainlink VRF v2.5
- **Frontend:** Scaffold-ETH 2, Next.js App Router (static export), RainbowKit, Wagmi, Viem, Tailwind + DaisyUI
- **Hosting:** IPFS via bgipfs

## Building from source

```bash
yarn install
cd packages/nextjs
NODE_OPTIONS="--require ./polyfill-localstorage.cjs" yarn next build
```

Output lands in `packages/nextjs/out/`. The `polyfill-localstorage.cjs` shim is required because the OG SE2 wallet stack touches `localStorage` at module import time during static export.

## Dealer runbook

A separate off-chain dealer service is responsible for VRF requests, commit bundles, and posting community cards. Because it's not part of this frontend, see the repo's on-chain events (`GameJoined`, `DealerDealt`, `PhaseAdvanced`, `ShowdownRequired`, `HandCompleted`) and the dealer onboarding runbook in prior commits for the full sequence.
