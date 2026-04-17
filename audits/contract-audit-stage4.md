# ClawdPoker Contract Fix Log — Stage 4

Base commit:   `5c926fe` (Stage 2 baseline)
Audit commit:  `95865f4` (Stage 3 audit report)
Tip (Stage 4): `c672216` on `main` (`clawdbotatg/leftclaw-service-job-60`)

## Stage 4 commits (in order)

| SHA       | Subject                                                                |
|-----------|------------------------------------------------------------------------|
| `312a777` | fix(contract): burn CLAWD via ERC20Burnable.burn() not transfer(0x0) (#1) |
| `7a37108` | fix(contract): rework claimTimeout for DEALING + SHOWDOWN phases (#2, #3) |
| `86c3a49` | fix(contract): partial-call all-in + canonical post-flop ordering (#4, #6) |
| `6905ac1` | fix(contract): reject reserved hole-card indices in dealCommunity (#5) |
| `17757c1` | fix(contract): fold tie-split rounding remainder into burn (#7)        |
| `081ee0b` | fix(contract): reject zero-slot commits + document salt entropy (#8, #9) |
| `a47e5a7` | fix(contract): refund both on dealer stall between streets (#10)       |
| `c672216` | docs(plan): VRF subscription + ownership onboarding runbook (#11)      |

Final `forge build`: clean.
Final `forge test`: 42/42 passing (21 PokerHandEvaluator + 21 ClawdPoker).

---

## Per-finding response

### C-01 (Issue #1) — Settlement burn uses `transfer(address(0))` which reverts on real CLAWD
- **Severity:** Critical
- **Status:** FIXED in `312a777`
- **Fix:** Added `interface IClawdBurnable { function burn(uint256) external; }` and a
  private `_burnClawd(uint256)` helper. All settlement/burn sites
  (`_settleWinner`, `_settleSplit`, future `_refundBoth`) now call
  `IClawdBurnable(address(CLAWD)).burn(amount)` instead of
  `CLAWD.transfer(address(0), amount)`. This is the canonical OZ `ERC20Burnable`
  entrypoint that real CLAWD on Base exposes.
- **Test coverage:** `MockCLAWD` rewritten to faithfully implement OZ v5 — it
  now reverts `ERC20InvalidReceiver` on transfer-to-zero exactly like the
  deployed token, and overrides `burn(uint256) { _burn(msg.sender, amount); }`.
  Every happy-path settlement test exercises the burn path through this mock,
  so the suite would break hard on a regression.

### H-01 (Issue #2) — `claimTimeout` during DEALING lets the joiner steal the pot
- **Severity:** High
- **Status:** FIXED in `7a37108`
- **Fix:** `claimTimeout` now reverts `WrongPhase` whenever the game is in
  `Phase.DEALING`. The DEALING phase is driven by the dealer (awaiting VRF
  fulfillment + `commitDeck`), so a player-facing "timeout" there is
  categorically the wrong user experience — nobody is on the clock, and the
  old code had `currentBettor == address(0)` which let anyone walk off with
  the pot. Dealer stalls during DEALING should be resolved off-chain or by
  upgrading the dealer; they are not a player-settlement event.
- **Test coverage:** `test_Timeout_InDealingPhase_Reverts` — forces the game
  into DEALING, warps `TIMEOUT_SECONDS + 1`, asserts both players get
  `WrongPhase` on `claimTimeout`.

### H-02 (Issue #3) — Showdown-phase timeout auto-awards non-revealer instead of revealer
- **Severity:** High
- **Status:** FIXED in `7a37108`
- **Fix:** `claimTimeout` now branches on `Phase.SHOWDOWN` before touching
  `currentBettor`. It reads `handRevealed[gameId][playerA]` and
  `handRevealed[gameId][playerB]`:
  - Exactly one side revealed → the revealer wins, non-revealer forfeits (pot
    burned/awarded per standard `_settleWinner` path).
  - Neither side revealed → both refunded via new `_refundBoth` (no burn, no
    winner, no reputation change — neither side cheated, neither side played).
- **Test coverage:**
  - `test_Showdown_NonRevealerLosesOnTimeout` — alice reveals, bob stalls,
    alice wins via timeout.
  - `test_Showdown_NeitherRevealed_RefundsBoth` — both sides stall, both
    refunded, zero CLAWD burned.

### H-03 (Issue #4) — Partial-call all-in impossible; short stack can only fold
- **Severity:** High
- **Status:** FIXED in `86c3a49`
- **Fix:** Introduced per-round delta accounting via
  `mapping(uint256 => mapping(address => uint256)) _committedThisRound`.
  `_call` and `_raise` now compute `owed = currentBet - _committedThisRound[gameId][sender]`
  and use `pay = min(stack, owed)`. When `stack < owed`, the short stack commits
  their entire remaining stack, the street advances, and settlement proceeds
  against the effective pot. `_committedThisRound` is reset for both players
  in `_advanceStreet`.
- **Test coverage:** `test_PartialCallAllIn_ShortStackCallsAndAdvances` —
  alice enters with a buy-in smaller than bob's raise; alice can call all-in
  for her remaining stack, hand progresses to SHOWDOWN, settlement balances
  check out.

### M-01 (Issue #5) — Reserved hole-card indices can be hijacked in `dealCommunity`
- **Severity:** Medium
- **Status:** FIXED in `6905ac1`
- **Fix:** `dealCommunity` now rejects any `deckIndices[i] in {4, 5, 6, 7}`
  with `revert BadRevealIndex()` before calling `_verifyAndMarkReveal`. Slots
  4–5 are alice's hole cards and 6–7 are bob's; only the owning player may
  reveal those via `revealHand`. The dealer-facing community-reveal path
  cannot reach them.
- **Test coverage:** `test_DealCommunity_RejectsReservedHoleIndices` — dealer
  tries to reveal a community card at index 5, reverts `BadRevealIndex`. The
  reserved slot is placed at index 0 of the cards array so the reserved-index
  check trips before any commit comparison (otherwise `CommitMismatch` would
  mask it).

### M-02 (Issue #6) — Post-flop first-actor non-determinism
- **Severity:** Medium
- **Status:** FIXED in `86c3a49`
- **Fix:** `_advanceStreet` now unconditionally sets `g.currentBettor = g.playerB`
  on every street transition into an active betting phase (FLOP, TURN, RIVER).
  This matches canonical heads-up hold'em rules where the big blind (playerB
  in this contract) acts first post-flop on every street. On the transition
  into SHOWDOWN, `currentBettor` is set to `address(0)` so no spurious
  betting-phase timeout branch fires.
- **Test coverage:** Every post-flop street test now asserts bob-first via
  the new `_checkDownToShowdown` helper; `test_HappyPath_FullHandAliceWins`
  updated to reflect canonical ordering (previously alice-first, now bob-first).

### M-03 (Issue #7) — Tie-split stranded wei on odd-pot rounding
- **Severity:** Medium
- **Status:** FIXED in `17757c1`
- **Fix:** `_settleSplit` now folds any rounding remainder into the burn:
  ```solidity
  uint256 each = distributable / 2;
  uint256 remainder = distributable - (2 * each);
  _burnClawd(baseBurn + remainder);
  ```
  No wei can be stranded in the contract on a tie, and the house edge is
  preserved without creating an unclaimable dust line on the poker contract.
- **Test coverage:** `test_Tie_OddRemainder_FoldedIntoBurn` — constructs a
  tie with an odd `distributable`, asserts both players receive `distributable/2`
  exactly and the remainder is burned.

### M-04 (Issue #8) — Salt entropy not specified; low-entropy dealer can leak hole cards
- **Severity:** Medium
- **Status:** FIXED in `081ee0b` (NatSpec) and `PLAN.md` (operational guidance)
- **Fix:** `commitDeck` NatSpec now spells out the salt requirement explicitly
  — salts MUST be generated from a CSPRNG and have `>= 128 bits of entropy`,
  with the recommended dealer pattern
  `salt_root = cryptoRandomBytes(32); salt_i = keccak256(salt_root || i)`.
  `PLAN.md` repeats this in the operational runbook (see "Salt entropy
  (audit M-04)") so it cannot be missed at dealer-bot integration time.
- **Test coverage:** Not testable on-chain (entropy is an off-chain
  property). Covered via documentation + dealer integration playbook.

### M-05 (Issue #9) — Zero-slot commits silently accepted
- **Severity:** Medium
- **Status:** FIXED in `081ee0b`
- **Fix:** `commitDeck` now iterates every slot and reverts `CommitMismatch`
  on any `commitments[i] == bytes32(0)`. Given the NatSpec mandate that
  salts be CSPRNG-generated, a zero slot can only come from (a) a dealer bug
  or (b) an adversarial dealer trying to plant a known-collision slot.
  Either way the hand should not progress.
- **Test coverage:** `test_CommitDeck_ZeroSlot_Reverts` — dealer submits 51
  valid commits and one zero slot, contract reverts.

### M-06 (Issue #10) — Dealer stall between streets penalizes the wrong side
- **Severity:** Medium
- **Status:** FIXED in `a47e5a7`
- **Fix:** Added `mapping(uint256 => bool) _awaitingDealerReveal` set to
  `true` in `_advanceStreet` on every FLOP/TURN/RIVER transition and cleared
  by `dealCommunity` on success. `claimTimeout` now detects this state: if
  we are between streets and `_awaitingDealerReveal[gameId]` is true,
  neither player is on the clock — the dealer is — so we route through the
  new `_refundBoth` helper. Both players get their stacks back, no burn,
  no winner, no reputation change. The timeout table in `PLAN.md`
  documents this branch alongside the other four.
- **Test coverage:** `test_Timeout_DealerStallBetweenStreets_RefundsBoth` —
  game reaches FLOP, dealer never calls `dealCommunity`, time warp,
  `claimTimeout` refunds both, pre/post CLAWD balances verify no burn.

### M-07 (Issue #11) — VRF subscription onboarding undocumented
- **Severity:** Medium
- **Status:** FIXED in `c672216` (documentation)
- **Fix:** Added `PLAN.md` at repo root with the full Stage 5 runbook:
  - Chainlink VRF V2.5 sub creation (Base coordinator
    `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634`)
  - LINK funding via `transferAndCall(coordinator, amount, abi.encode(subId))`
  - Deployer-side deploy parameters (keyHash, subId, CLAWD)
  - `addConsumer(subscriptionId, clawdPokerAddress)` (mandatory; omitting
    this step bricks `joinGame` at `requestRandomWords`)
  - Two-step contract-ownership transfer (`transferOwnership` → client
    `acceptOwnership`)
  - Separation of concerns between contract-ownership (dealer role) and
    subscription-ownership (LINK/consumer role) — both may legitimately
    live on different addresses
  - Post-hand-off verification checklist (`cast call` commands to confirm
    `owner()`, subscription state, a live-game smoke test)
- **Test coverage:** Operational — documented in `PLAN.md`. Not testable
  on-chain.

---

## What changed in test surface

`packages/foundry/test/ClawdPoker.t.sol`:

- `MockCLAWD` rewritten to be faithful to OZ v5 CLAWD on Base:
  - Reverts `ERC20InvalidReceiver` on `transfer(address(0), ...)` — matches
    deployed behavior and guarantees C-01 stays fixed.
  - Implements `burn(uint256) { _burn(msg.sender, amount); }` — matches
    the `ERC20Burnable` entrypoint used by `_burnClawd`.
- `_checkDownToShowdown` helper added — walks a game through
  FLOP → TURN → RIVER with bob-first checks on every street.
- Existing `test_HappyPath_FullHandAliceWins` updated for canonical
  bob-first post-flop ordering (was alice-first before M-02).
- Eight new tests added covering each behavior change:
  - `test_Timeout_InDealingPhase_Reverts` (H-01)
  - `test_Showdown_NonRevealerLosesOnTimeout` (H-02)
  - `test_Showdown_NeitherRevealed_RefundsBoth` (H-02)
  - `test_PartialCallAllIn_ShortStackCallsAndAdvances` (H-03)
  - `test_DealCommunity_RejectsReservedHoleIndices` (M-01)
  - `test_Tie_OddRemainder_FoldedIntoBurn` (M-03)
  - `test_CommitDeck_ZeroSlot_Reverts` (M-05)
  - `test_Timeout_DealerStallBetweenStreets_RefundsBoth` (M-06)

No tests were disabled, skipped, or weakened. Suite goes from 13 → 21
ClawdPoker tests + 21 PokerHandEvaluator tests = 42 total, all green.

---

## Deferrals

None. Every Critical / High / Medium finding landed a code or documentation
fix with associated test coverage where on-chain-testable.

## Stage 5 readiness

Green — ready for deploy. Client-side prerequisites (VRF sub creation,
LINK funding) and deployer-side steps (keyHash / subId / CLAWD / coordinator
parameters, `yarn verify --network base`, `addConsumer`, two-step ownership
transfer) are enumerated in `PLAN.md`.
