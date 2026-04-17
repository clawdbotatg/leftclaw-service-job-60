# ClawdPoker Contract Audit — Stage 3

Date: 2026-04-16
Auditor: clawdbotatg (Opus)
Commit audited: 5c926fe8f637449bfddaab779f4fbc846d743de4
Scope: `packages/foundry/contracts/ClawdPoker.sol` (652 lines), `packages/foundry/contracts/PokerHandEvaluator.sol` (256 lines)

## Summary

| Severity | Count |
|---|---|
| Critical | 1 |
| High | 3 |
| Medium | 7 |
| Low | 3 |
| Info | 3 |

**Overall verdict: requires fixes before proceeding to Stage 5 deploy.** One Critical finding (transfer-to-zero on the real CLAWD token) will brick every game settlement on Base mainnet and must be fixed before deploy. Two High findings (DEALING-phase timeout auto-awards playerA; SHOWDOWN stall-to-win) and one High finding on re-raise accounting (forced-fold on partial-call all-in) each represent real loss-of-funds paths under realistic gameplay. All three Highs plus the Critical are fixable within Stage 4 without redesign. The overall architecture is sound.

Ship-blockers for Stage 4:
1. C-01 — replace transfer-to-zero burn with CLAWD's native `burn(uint256)` call.
2. H-01 — gate `claimTimeout` out of DEALING phase (or implement a symmetric refund path).
3. H-02 — fix showdown timeout loser determination via `handRevealed`, not `currentBettor`.
4. H-03 — correct per-round bet accounting (track committed-this-round per player, allow partial-call all-in).

## Methodology

Followed the evm-audit-master pipeline (https://ethskills.com/audit/SKILL.md) with the following specialist skill domains walked mentally given the contract's surface area:

- `evm-audit-general` — storage pointers, struct deletion, token handling, downcasting
- `evm-audit-precision-math` — 15% burn math, buy-in caps, split-rounding
- `evm-audit-erc20` — live probe of the actual CLAWD token on Base (OZ v5, has `burn`)
- `evm-audit-access-control` — ConfirmedOwner two-step ownership, onlyOwner coverage, renounce traps
- `evm-audit-oracles` — Chainlink VRF V2.5 callback correctness, subscription model, request-ID collisions
- `evm-audit-dos` — partial-call all-in forced folds, showdown griefing, timeout abuse, unbounded loops in `openGames`
- `evm-audit-signatures` (N/A — no off-chain signatures)
- `evm-audit-bridges` (N/A — single-chain)
- State-machine & commit-reveal soundness — walked the full phase graph, traced `_advanceStreet` and `claimTimeout` for every action path
- Hand evaluator spot-check — reviewed 21 existing tests, spot-checked wheel, royal flush, split-kickers, 4oaK vs straight flush

Live on-chain checks performed:
- `cast call` transfer(address(0), 1) on CLAWD `0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07` → reverts `ERC20InvalidReceiver(address)`.
- `cast call` `decimals()` → 18.
- `cast call` `burn(0)` → succeeds (CLAWD implements ERC20Burnable).
- `cast call` `burnFrom(addr, 0)` → succeeds.

Tests: 34/34 PASS with `via_ir=true` (default). Production contract compiles clean without `via_ir`; tests themselves require `via_ir` to compile (stack-too-deep in test harness). No via-ir vs non-via-ir discrepancy could be A/B tested because the test suite won't compile without it — production compilation is clean either way, so no miscompilation concern observed at the contract level.

Slither / Mythril: not installed on the audit host; not run.

## Findings

### C-01 Settlement bricked on Base: CLAWD reverts on `transfer(address(0), ...)` — **Critical**

**Location:** `ClawdPoker.sol:576-579` (`_settle`), `ClawdPoker.sol:597-599` (`_settleSplit`), `ClawdPoker.sol:648-651` (`_pushClawd` → `CLAWD.transfer(address(0), burn)`)

**Description:** The live CLAWD token on Base at `0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07` ("clawd.atg.eth") is an OpenZeppelin v5 ERC20. OZ v5 `_update` reverts with `ERC20InvalidReceiver(0x0)` on any transfer whose recipient is the zero address, including zero-amount transfers. The `_settle` and `_settleSplit` paths unconditionally call `_pushClawd(address(0), burn)` whenever `burn > 0`, which is true for every realistic game. Therefore every terminal state transition in every game on Base mainnet will revert.

**Impact:** Every game's settlement reverts. Buy-ins are permanently stranded in the contract. No admin-rescue path exists.

**Proof-of-concept:**
```
$ cast call 0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07 \
    "transfer(address,uint256)(bool)" \
    0x0000000000000000000000000000000000000000 1 \
    --rpc-url $ALCHEMY_RPC_URL --from 0x0000...01
Error: execution reverted, data: "0xec442f05..."   # ERC20InvalidReceiver(address)
```

The existing `MockCLAWD` in `test/ClawdPoker.t.sol:15-29` silently routes transfer-to-zero through `_burn` to hide this exact path from the test suite.

**Recommendation:** CLAWD exposes `burn(uint256)` (verified on-chain). Replace the transfer-to-zero call with a direct burn:

```solidity
interface IClawdBurnable { function burn(uint256) external; }

function _burnClawd(uint256 amt) internal {
    IClawdBurnable(address(CLAWD)).burn(amt);
}
```

Update tests to use a faithful OZ v5 mock (no `_burn` shortcut) to prevent regression.

**GH issue:** #1

---

### H-01 `claimTimeout` in DEALING phase auto-awards to `playerA` — **High**

**Location:** `ClawdPoker.sol:537-548` (`claimTimeout`), `ClawdPoker.sol:554-583` (`_settle`)

**Description:** `Phase.DEALING` is not in the `claimTimeout` WrongPhase guard. In DEALING, `g.currentBettor` is the zero-address default. The check `msg.sender == g.currentBettor` is `false` for any real player, so either player can claim. `loser = g.currentBettor = address(0)`, and `_settle`'s winner ternary gives `winner = playerA` unconditionally (because `loser != playerA`, the else-branch is taken).

**Impact:** In any game where the dealer / VRF fails to progress within 24h (LINK drained, dealer offline, Chainlink outage), whichever player calls `claimTimeout` causes playerA to win by default. PlayerB loses their buy-in via 85% payout to playerA. A malicious creator can co-design this with a colluding dealer to always win stalled games.

**Proof-of-concept:** see issue body.

**Recommendation:** Gate `claimTimeout` to exclude `DEALING` (and consider adding a symmetric `rescueStalledDeal` path that refunds both buy-ins without burn after a longer 72h grace).

**GH issue:** #2

---

### H-02 Showdown timeout penalizes wrong player (stall-to-win) — **High**

**Location:** `ClawdPoker.sol:537-548` (`claimTimeout`), `ClawdPoker.sol:453-486` (`revealHand`), `ClawdPoker.sol:381-403` (`_advanceStreet` on RIVER → SHOWDOWN does not reset `currentBettor`)

**Description:** In SHOWDOWN, `currentBettor` is whatever it happened to be at the end of the river — unrelated to who has/hasn't revealed. `revealHand` does not update `currentBettor`. `claimTimeout` uses `currentBettor` as the loser. Consequence: a player with the worse hand can refuse to reveal, and — if they are not `currentBettor` at SHOWDOWN entry — call `claimTimeout` after 24h to force `loser = currentBettor = opponent`. They win despite holding the weaker hand.

In the common both-check-the-river flow, `currentBettor` at SHOWDOWN entry ends up as `playerB` (B checks last), so `playerA` can call `claimTimeout` without revealing → `loser = B, winner = A`. PlayerA wins with an un-revealed (and potentially weak) hand.

**Impact:** Direct wrong-winner path for any SHOWDOWN whose `currentBettor` at entry is not the player motivated to stall. Easy to engineer.

**Recommendation:** In SHOWDOWN, use `handRevealed[]` to determine the stalling party. Penalize the player who did NOT reveal within the window. If both haven't revealed, refund both. Also clear `currentBettor` when transitioning to SHOWDOWN so the value cannot be misused.

**GH issue:** #3

---

### H-03 Re-raise semantics allow partial-call all-in to force-fold — **High**

**Location:** `ClawdPoker.sol:301` (docstring), `ClawdPoker.sol:347-355` (`_call`), `ClawdPoker.sol:357-364` (`_raise`), `ClawdPoker.sol:366-375` (`_moveToPot`)

**Description:** The `act` docstring says `amount` is the "new total bet size for raise"; the `_raise` in-function comment says `amount` is the chips-this-action (a delta). The implementation uses `amount` as BOTH — `_moveToPot(msg.sender, amount)` AND `g.currentBet = amount` — which is only correct when the raiser hasn't contributed this round yet. More importantly, `_call` always moves the full `currentBet` from the caller's stack: so any player whose stack is below `currentBet` cannot call, they must fold. There is no partial-call-all-in pathway.

**Impact:** A player with a short stack (smaller than the current bet) is forced to fold and forfeit their buy-in, even when they have funds to at least see the showdown. Canonical Hold'em allows an all-in call for less than the full bet (creating a side-pot or capping the effective bet). This contract does not. The asymmetry can be weaponized to eliminate players by sizing bets just above their remaining stack.

**Recommendation:** Track `committedThisRound[gameId][player]`, reset on each `_advanceStreet`. `_call` should pay `min(stack, currentBet - committed)` (going all-in if short). `_raise` should pay `amount - committed`. Implement all-in short-circuit (see Medium on all-in handling).

**GH issue:** #4

---

### M-01 Dealer can brick showdown by claiming hole-card deck indices 4-7 for community — **Medium**

**Location:** `ClawdPoker.sol:413-435` (`dealCommunity`), `ClawdPoker.sol:453-486` (`revealHand`), `ClawdPoker.sol:489-500` (`_verifyAndMarkReveal`)

**Description:** Hole cards are hard-coded to deck indices 4,5 (playerA) and 6,7 (playerB). `dealCommunity` does not reject those indices. A malicious dealer can deal the flop/turn/river using indices 4-7; those slots are then in `_indexRevealedMask`, and the corresponding player can no longer reveal their hole cards (reverts `IndexAlreadyRevealed`). The game stalls in SHOWDOWN and resolves via timeout (which, per H-02, picks the wrong winner).

**Impact:** Within the trusted-dealer model, the dealer can selectively lock out either player from showdown and force a timeout-based wrong-winner outcome.

**Recommendation:** Reject `deckIndices[i] in {4,5,6,7}` inside `dealCommunity`. Better: reserve deck indices 0-3 for community, 4-5 for playerA holes, 6-7 for playerB holes, and enforce all ranges.

**GH issue:** #5

---

### M-02 Post-flop first-actor is non-deterministic / reverse-canonical — **Medium**

**Location:** `ClawdPoker.sol:381-403` (`_advanceStreet`, especially the line `g.currentBettor = (g.phase == Phase.PREFLOP) ? g.currentBettor : g.playerA;`)

**Description:** When `_advanceStreet` runs the phase is still the CURRENT phase (pre-transition). So the ternary preserves `currentBettor` after PREFLOP close and forces `playerA` after FLOP/TURN close. PREFLOP close leaves currentBettor on whoever happened to take the last action — it can be either player depending on the specific action sequence. Post-flop, playerA is forced first, but canonical heads-up Hold'em has the BB (playerB here) acting first post-flop.

**Impact:** First-actor assignment on the flop is unpredictable across games, and post-flop ordering is reversed from canonical Hold'em. Neither is a fund-loss vector; both degrade fairness / expectation.

**Recommendation:** Rewrite `_advanceStreet` to set the first-actor based on the NEXT phase using canonical Hold'em rules: BB (playerB) acts first post-flop. Do not touch `currentBettor` in `dealCommunity`. Also clear `currentBettor` on RIVER → SHOWDOWN to defuse H-02-style misuse.

**GH issue:** #6

---

### M-03 Stranded wei from tie-split leak has no recovery path — **Medium**

**Location:** `ClawdPoker.sol:585-604` (`_settleSplit`)

**Description:** On tie, `each = (total - burn) / 2` truncates; when `(total - burn)` is odd, 1 wei stays in the contract. Over many games this pools indefinitely. No admin rescue, no sweep into next game.

**Recommendation:** Add the remainder to the burn amount and burn it (after C-01 is fixed). Or pay the remainder to one player deterministically.

**GH issue:** #7

---

### M-04 Salt entropy requirement for commits is undocumented — **Medium**

**Location:** `ClawdPoker.sol:489-500` (`_verifyAndMarkReveal`), commit scheme comments at lines 32-40 and 277-279

**Description:** Commits are `keccak256(abi.encodePacked(salt, card))` with `card in [0,51]`. If salts have low entropy, an observer can brute-force each commit and learn committed cards before reveal. The contract cannot enforce salt entropy on-chain; it is an operator obligation that is not currently documented.

**Recommendation:** Document in NatSpec and README: salts MUST be generated with a CSPRNG and ≥128 bits of entropy. Optionally, have the dealer commit a single `saltRoot` and derive per-card salts as `keccak256(root, index)` — only one 32-byte high-entropy secret to protect.

**GH issue:** #8

---

### M-05 Incomplete commit validation in `commitDeck` — **Medium**

**Location:** `ClawdPoker.sol:280-295` (`commitDeck`)

**Description:** "Already committed" sentinel is `cardCommits[gameId][0] != bytes32(0)`. The function does not validate that all 52 slots are non-zero. A dealer who accidentally leaves slots zero will silently brick any reveal targeting those slots. Use of `cardCommits[0]` as a sentinel is additionally fragile.

**Recommendation:** Reject any zero commit inside the loop, or use a dedicated `_deckCommitted[gameId]` boolean.

**GH issue:** #9

---

### M-06 Ambiguous timeout responsibility between player stall and dealer stall — **Medium**

**Location:** `ClawdPoker.sol:537-548` (`claimTimeout`), `ClawdPoker.sol:381-403` (`_advanceStreet`)

**Description:** The same `lastActionTime` + `currentBettor` mechanism is used to penalize both "player won't act" and (implicitly) "dealer won't deal the next street." When a dealer stalls between streets, the player penalized on timeout is whoever happened to be `currentBettor` at the end of the last closed round — arbitrary and not the stalling party.

**Recommendation:** Split the two cases. When the contract is waiting on the dealer, `claimTimeout` should refund both players (no burn, no winner) instead of declaring a loser.

**GH issue:** #10

---

### M-07 VRF subscription ownership / deployment runbook is undocumented — **Medium**

**Location:** Constructor at `ClawdPoker.sol:184-190` (`SUBSCRIPTION_ID` immutable)

**Description:** Contract ownership (via ConfirmedOwner) and VRF subscription ownership (managed by VRFCoordinator) are independent surfaces. Stage 5 must coordinate who creates/funds/owns the sub, who adds the consumer, and when contract ownership transfers. No on-chain coupling today; no runbook.

**Recommendation:** Explicit Stage 5 runbook AND consider making `subscriptionId` owner-settable instead of immutable (losing immutability in exchange for onboarding flexibility).

**GH issue:** #11

---

### L-01 `openGames()` iterates the full `gameIds` array — unbounded gas growth — **Low**

**Location:** `ClawdPoker.sol:618-633`

**Description:** `openGames` iterates every game ever created. As volume grows, this view becomes expensive to call (it's a view, but front-ends that hit it via eth_call against a loaded archive node may time out at very high volumes). Not a security issue.

**Recommendation:** Maintain an explicit `_openGameIds` set, or offer paginated views (`openGamesPage(offset, limit)`).

**GH issue:** not filed (Low).

---

### L-02 VRF callback silently no-ops on wrong phase — **Low**

**Location:** `ClawdPoker.sol:265-275` (`fulfillRandomWords`)

**Description:** If `g.phase != Phase.DEALING` when VRF callback fires, the callback silently returns. This is required by Chainlink's recommendation (never revert inside the callback to avoid getting stuck). However, no event is emitted in this path, making it hard to diagnose if it ever triggers. Could happen if a game was settled via timeout (see H-01) before VRF arrived.

**Recommendation:** Emit a `VrfFulfilledUnexpectedPhase(requestId, gameId, phase)` event for observability. Do not revert.

**GH issue:** not filed (Low).

---

### L-03 Burn rounding favors players (by 1 wei) rather than house — **Low**

**Location:** `ClawdPoker.sol:565` (`burn = (total * BURN_BPS) / BPS_DENOM`)

**Description:** Standard integer division rounds toward zero. So burn is rounded DOWN, payout rounds UP. Protocol (burn) is worse off by at most 9 wei per settlement; winner is better off by at most 9 wei. Direction is not explicitly chosen — consider whether it should be.

**Recommendation:** If the house is the "burn beneficiary" and protocol-favoring rounding is desired, use `burn = (total * BURN_BPS + BPS_DENOM - 1) / BPS_DENOM`. This is a design choice, not a bug.

**GH issue:** not filed (Low).

---

### I-01 Event data — `Action` emits twice on fold — **Info**

**Location:** `ClawdPoker.sol:325` and `ClawdPoker.sol:331`

**Description:** `act()` has a general `emit Action(...)` at line 325 after the action branches, but `_fold` returns early with its own `emit Action(...)` at line 331. On fold, only the in-`_fold` event fires. This is intentional but means the `emit` at line 325 is dead for action=0. No bug; minor surprise.

**GH issue:** not filed (Info).

---

### I-02 Constant naming inconsistency — **Info**

**Location:** Multiple. E.g., `BURN_BPS`, `BPS_DENOM`, `CALLBACK_GAS_LIMIT` are UPPER_SNAKE (correct), but some state fields and locals use lower-camelCase conventionally. `CLAWD`, `SUBSCRIPTION_ID`, `KEY_HASH` are state immutables but named like constants; they are immutable so this is acceptable. Just noting for style-audit completeness.

**GH issue:** not filed (Info).

---

### I-03 `_vrfResult` stored per game but only exposed via a public getter — **Info**

**Location:** `ClawdPoker.sol:171` (`_vrfResult` is private), `ClawdPoker.sol:635-637` (getter `getVrfResult`)

**Description:** Storing the raw seed on-chain is intentional (for post-hoc auditability), but the primary path players will use to see it is the `VrfFulfilled` event. The mapping + getter is redundant with the event. Costs one SSTORE per game (~20k gas). Consider whether keeping it is worth the gas vs. relying on the event log.

**Recommendation:** Either drop the storage and rely on the event, or keep it and document why (e.g., "to remain available for chains without reliable event archive").

**GH issue:** not filed (Info).

---

## Assessment of author-flagged concerns (1–10)

**1. Ownership model collision (ConfirmedOwner vs Ownable).** CONFIRMED as correctly handled. `VRFConsumerBaseV2Plus` → `ConfirmedOwner` gives `owner()` / `onlyOwner` / `transferOwnership(address)` / `acceptOwnership()` (two-step). No collision. Stage 5 can transferOwnership to `job.client`; client calls acceptOwnership. See M-07 for the operational caveat about VRF subscription ownership being a separate surface.

**2. Deck index convention (hole at 4/5/6/7).** PARTIALLY CONFIRMED. `_indexRevealedMask` correctly prevents reuse at the same index, but `dealCommunity` does NOT prevent the dealer from using indices 4-7 for community cards. That lets the dealer grief showdown reveals. Filed as M-01.

**3. Optimizer + via_ir miscompilation.** UNABLE TO A/B TEST — the test suite fails to compile without via_ir (stack-too-deep in `test_HappyPath_FullHandAliceWins`). The production contract compiles cleanly both with and without via_ir (no stack-too-deep in production code). Since no output-differing test could run under both configs, no miscompilation was observed. No finding.

**4. All-in short-circuit missing.** CONFIRMED and RECLASSIFIED as part of a bigger issue. The core bug is not just "no short-circuit to showdown" — it's that the `_call` / `_raise` accounting forces a fold on any partial-call-all-in (H-03). Fix the accounting first; short-circuit-to-showdown is a nice-to-have on top.

**5. Burn-to-zero assumption.** CONFIRMED Critical. Live CLAWD on Base (`0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07`) is OZ v5 and reverts unconditionally on transfer-to-zero. Filed as C-01.

**6. `_settle` pot reconstruction (`pot + stackA + stackB`).** CONFIRMED correct. Walked every action path:
- preflop fold → stacks untouched, both at buyIn, pot=0 → total = 2*buyIn ✓
- call-check down → stacks drain into pot; conservation holds because `_moveToPot` only subtracts what it adds to pot ✓
- raise-fold → same — all moves are conservative ✓
- all-in showdown — no true all-in is possible today (see H-03), but the math is still conservative ✓
- timeout (betting phases) — conservative ✓
- tie split — loses up to 1 wei to rounding (M-03) but otherwise conservative ✓

No CLAWD is materialized from nowhere. The redemption of the sweep is that even if per-round accounting over-charges a player (H-03 second-order), the full balance still reaches the winner.

**7. Tie splits leak odd wei.** CONFIRMED. Filed as M-03.

**8. VRF callback no-op on wrong phase.** CONFIRMED as acceptable silent behavior but with an observability gap. Filed as L-02. Silent no-op does NOT let an attacker reach any griefing surface; the only realistic trigger is a DEALING-phase timeout (H-01) firing before VRF returns, after which the contract is in COMPLETE phase and the callback becomes a no-op. LINK is burned but no further state change. Low severity.

**9. `_advanceStreet` currentBettor handling.** CONFIRMED as a real bug. Filed as M-02 — reclassified to Medium rather than High because neither player is *locked out* of acting; the issue is first-actor determinism and spec adherence.

**10. Constructor ownership via ConfirmedOwner (initial owner = deployer).** CONFIRMED workable but with operational care. See M-07. The two-step transfer protects against setting a typo'd address; the client must actively `acceptOwnership` so there is no accidental transfer.

---

## Tests

- 34/34 tests pass (`forge test`).
- Gas report: `test_StreakGate_RaisesTo50M_After3Wins` hits ~4.8M gas — expected given it runs 3 complete flows. No anomalies.
- All passing tests rely on `MockCLAWD`'s non-standard transfer-to-zero behavior and therefore do NOT cover the production failure mode in C-01. Stage 4 must update `MockCLAWD` to faithfully revert on transfer-to-zero and re-run the suite.

## Recommended Stage 4 Fix Order

1. C-01 (burn-to-zero) — blocker for any deploy.
2. H-01 (DEALING timeout) — straightforward guard, do this together with C-01.
3. H-02 (SHOWDOWN timeout loser) — requires handRevealed-based logic.
4. H-03 (per-round accounting + partial-call all-in) — biggest single change; will affect multiple tests.
5. M-01 through M-07 — roughly in filed order.
6. Low / Info items — fix opportunistically or defer to hardening stage.

Close each issue with a commit reference per the `[STAGE:contract_fix]` playbook. Re-run `forge test` after every fix and keep the suite passing.
