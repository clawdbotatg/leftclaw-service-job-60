// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ClawdPoker} from "../contracts/ClawdPoker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VRFCoordinatorV2_5Mock} from
    "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

/// @dev Faithful CLAWD-like ERC20 for tests. The real CLAWD token on Base
///      (0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07) is OpenZeppelin v5
///      ERC20 + ERC20Burnable:
///        - `transfer(address(0), ...)` reverts `ERC20InvalidReceiver(0)`
///        - `burn(uint256)` (callable by any holder) is available
///      This mock matches that behaviour so the test suite cannot mask the
///      C-01 burn-to-zero bug again.
contract MockCLAWD is ERC20 {
    constructor() ERC20("Mock CLAWD", "mCLAWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev ERC20Burnable.burn(uint256): burn from msg.sender.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

contract ClawdPokerTest is Test {
    // Constants
    uint96 constant BASE_FEE = 0.25 ether;
    uint96 constant GAS_PRICE = 1 gwei;
    int256 constant WEI_PER_LINK = 4e15;
    bytes32 constant KEY_HASH = keccak256("baseMainnet");

    // Actors
    address dealer = address(0xD3A1E2);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address charlie = address(0xC4A7);

    // Contracts
    VRFCoordinatorV2_5Mock vrf;
    MockCLAWD clawd;
    ClawdPoker poker;
    uint256 subId;

    function setUp() public {
        vm.startPrank(dealer);
        vrf = new VRFCoordinatorV2_5Mock(BASE_FEE, GAS_PRICE, WEI_PER_LINK);
        subId = vrf.createSubscription();
        vrf.fundSubscription(subId, 10_000 ether);
        clawd = new MockCLAWD();
        poker = new ClawdPoker(address(vrf), subId, KEY_HASH, IERC20(address(clawd)));
        vrf.addConsumer(subId, address(poker));
        vm.stopPrank();

        // Fund the players generously for the tests
        clawd.mint(alice, 1_000_000_000e18);
        clawd.mint(bob, 1_000_000_000e18);
        clawd.mint(charlie, 1_000_000_000e18);

        // Approve the poker contract
        vm.prank(alice);
        clawd.approve(address(poker), type(uint256).max);
        vm.prank(bob);
        clawd.approve(address(poker), type(uint256).max);
        vm.prank(charlie);
        clawd.approve(address(poker), type(uint256).max);
    }

    // ------------------------------------------------------------------
    //                       Helpers
    // ------------------------------------------------------------------

    /// @dev Compute a commit for (card, salt).
    function _commit(uint8 card, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(salt, card));
    }

    /// @dev Build a dummy 52-commit array where:
    ///        - community cards (flop + turn + river) go to indices 0..4
    ///        - playerA hole cards go to indices 4, 5? NO -- community uses 0..4, so playerA uses 4,5 per contract.
    ///
    ///      Wait, community uses writeStart 0 (flop), 3 (turn), 4 (river) -- so it uses deck indices
    ///      0..4 for community reveals too? No: community writeStart is an index into `communityCards`
    ///      not into the deck. The dealer passes `deckIndices[i]` separately.
    ///
    ///      For simplicity in tests: we assign every card to a unique deck index we choose ourselves.
    ///        community flop -> deck indices 0,1,2
    ///        community turn -> deck index 3
    ///        community river -> deck index 10
    ///        playerA hole -> deck indices 4, 5
    ///        playerB hole -> deck indices 6, 7
    ///      All chosen card VALUES are distinct (cards 0..6).
    function _buildCommits(uint8[] memory cards, uint8[] memory deckIdx, bytes32[] memory salts)
        internal
        pure
        returns (bytes32[52] memory commits)
    {
        require(cards.length == deckIdx.length && salts.length == cards.length, "len mismatch");
        // Fill all slots with commits to a dummy distinct salt+card so no slot is zero.
        for (uint256 i = 0; i < 52; i++) {
            commits[i] = keccak256(abi.encodePacked(bytes32(uint256(0xDEAD + i)), uint8(0)));
        }
        for (uint256 i = 0; i < cards.length; i++) {
            commits[deckIdx[i]] = keccak256(abi.encodePacked(salts[i], cards[i]));
        }
    }

    uint256 private _nextExpectedVrfRequestId = 1;

    /// @dev Create a game, join with second player, get VRF fulfilled, commit the deck.
    ///      `cards` / `deckIdx` / `salts` are zipped arrays describing the reveals the dealer
    ///      wants to commit to. Community-card indices: flop = 0,1,2; turn = 3; river = 10.
    ///      Hole cards: A uses indices 4,5; B uses 6,7.
    function _startGameAndCommit(
        address pA,
        address pB,
        uint256 buyIn,
        uint8[] memory cards,
        uint8[] memory deckIdx,
        bytes32[] memory salts
    ) internal returns (uint256 gameId) {
        vm.prank(pA);
        gameId = poker.createGame(buyIn);
        vm.prank(pB);
        poker.joinGame(gameId);

        // Dealer fulfills VRF. The VRF mock hands out sequential request IDs starting at 1.
        uint256[] memory words = new uint256[](1);
        words[0] = 0xC0FFEE;
        uint256 reqId = _nextExpectedVrfRequestId++;
        vm.prank(dealer);
        vrf.fulfillRandomWordsWithOverride(reqId, address(poker), words);
        // After fulfill: state should have deckHash set, phase still DEALING.
        // NOTE: the mock emits RandomWordsFulfilled regardless of whether the consumer callback succeeds.
        // If the callback did revert we'd see phase still DEALING and no deckHash -- assertion below
        // would fail meaningfully.

        bytes32[52] memory commits = _buildCommits(cards, deckIdx, salts);
        vm.prank(dealer);
        poker.commitDeck(gameId, commits);
    }

    // ------------------------------------------------------------------
    //                       1. Happy path
    // ------------------------------------------------------------------

    function test_HappyPath_FullHandAliceWins() public {
        uint256 buyIn = 1_000_000e18;

        // Community + holes. We want Alice to win with a clean hand.
        // Community (flop+turn+river): cards 0, 13, 26, 39, 12 (2h, 2s, 2d, 2c, Ah)
        // That gives community quads of 2s. Whoever has highest kicker wins (pair on board).
        // Alice hole: c=50 (Ks) and c=38 (Kd). After board 2222A, Alice has 2222 with A kicker. Tie possible with K kicker?
        // Simpler: give Alice hole cards that create quad 2s + A kicker (already on board). Bob gets a king + queen.
        // Alice: Kh, Kd -> 2222 K (quads 2 + K kicker since there's an A on the board already, board wins; both have same 5 cards from board). That's a tie.
        // Let's construct a scenario where Alice clearly beats Bob:
        //   Community: 0 (2h=rank0 suit0), 1 (3h), 14 (3s), 26 (3d=rank0 suit2? card 26: 26/13=2, 26%13=0, so 2 of suit 2... wait)
        //
        // Card encoding: suit=c/13, rank=c%13. rank 0=2, 12=A. So:
        //   card 0 = suit 0 rank 0 = 2h
        //   card 12 = suit 0 rank 12 = Ah
        //   card 13 = suit 1 rank 0 = 2s
        //   card 25 = suit 1 rank 12 = As
        //   card 26 = suit 2 rank 0 = 2d
        //   card 38 = suit 2 rank 12 = Ad
        //   card 39 = suit 3 rank 0 = 2c
        //   card 51 = suit 3 rank 12 = Ac
        //
        // Simple win scenario: board has three aces (12, 25, 38) + two low (1 = 3h, 2 = 4h). Alice's pocket pair (Kh=11, Kd=37) gives her aces-full-of-kings. Bob gets (Jh=9, Jd=35) for aces-full-of-jacks.
        //
        // Cards used (all distinct):
        //   community: 12, 25, 38, 1, 2
        //   A holes: 11, 37
        //   B holes: 9, 35

        uint8[] memory cards = new uint8[](9);
        uint8[] memory deckIdx = new uint8[](9);
        bytes32[] memory salts = new bytes32[](9);

        // community flop (indices 0,1,2)
        cards[0] = 12; deckIdx[0] = 0; salts[0] = keccak256("s0");
        cards[1] = 25; deckIdx[1] = 1; salts[1] = keccak256("s1");
        cards[2] = 38; deckIdx[2] = 2; salts[2] = keccak256("s2");
        // turn (index 3), river (index 10)
        cards[3] = 1;  deckIdx[3] = 3; salts[3] = keccak256("s3");
        cards[4] = 2;  deckIdx[4] = 10; salts[4] = keccak256("s4");
        // A holes (indices 4,5)
        cards[5] = 11; deckIdx[5] = 4; salts[5] = keccak256("s5");
        cards[6] = 37; deckIdx[6] = 5; salts[6] = keccak256("s6");
        // B holes (indices 6,7)
        cards[7] = 9;  deckIdx[7] = 6; salts[7] = keccak256("s7");
        cards[8] = 35; deckIdx[8] = 7; salts[8] = keccak256("s8");

        uint256 gameId = _startGameAndCommit(alice, bob, buyIn, cards, deckIdx, salts);

        // Preflop: both check.
        vm.prank(bob); // B acts first preflop (spec)
        poker.act(gameId, 1, 0);
        vm.prank(alice);
        poker.act(gameId, 1, 0);

        // Dealer deals flop (cards[0..2] / idx 0,1,2)
        uint8[] memory flop = _slice(cards, 0, 3);
        uint8[] memory flopIdx = _slice(deckIdx, 0, 3);
        bytes32[] memory flopSalts = _sliceB(salts, 0, 3);
        vm.prank(dealer);
        poker.dealCommunity(gameId, flop, flopSalts, flopIdx);

        // Flop: both check. Post-flop first actor is BB (bob) per M-02 fix.
        vm.prank(bob);
        poker.act(gameId, 1, 0);
        vm.prank(alice);
        poker.act(gameId, 1, 0);

        // Dealer deals turn (cards[3] / idx 3)
        uint8[] memory turn = _slice(cards, 3, 4);
        uint8[] memory turnIdx = _slice(deckIdx, 3, 4);
        bytes32[] memory turnSalts = _sliceB(salts, 3, 4);
        vm.prank(dealer);
        poker.dealCommunity(gameId, turn, turnSalts, turnIdx);

        vm.prank(bob); poker.act(gameId, 1, 0);
        vm.prank(alice); poker.act(gameId, 1, 0);

        // Dealer deals river (cards[4] / idx 10)
        uint8[] memory river = _slice(cards, 4, 5);
        uint8[] memory riverIdx = _slice(deckIdx, 4, 5);
        bytes32[] memory riverSalts = _sliceB(salts, 4, 5);
        vm.prank(dealer);
        poker.dealCommunity(gameId, river, riverSalts, riverIdx);

        vm.prank(bob); poker.act(gameId, 1, 0);
        vm.prank(alice); poker.act(gameId, 1, 0);
        // After river close, phase == SHOWDOWN.
        ClawdPoker.Game memory gPeek = poker.getGame(gameId);
        assertEq(uint8(gPeek.phase), uint8(ClawdPoker.Phase.SHOWDOWN));

        // Reveal hands
        uint256 aliceBalBefore = clawd.balanceOf(alice);

        vm.prank(alice);
        poker.revealHand(gameId, cards[5], cards[6], salts[5], salts[6]);
        vm.prank(bob);
        poker.revealHand(gameId, cards[7], cards[8], salts[7], salts[8]);

        // After both revealed, showdown resolves automatically.
        ClawdPoker.Game memory gAfter = poker.getGame(gameId);
        assertEq(uint8(gAfter.phase), uint8(ClawdPoker.Phase.COMPLETE));
        assertEq(gAfter.winner, alice, "alice should win aces full of kings vs jacks");

        // Pot was 2 * buyIn = 2M. Burn 15% = 300k. Payout 1.7M.
        uint256 expectedPayout = (2 * buyIn) * (10_000 - 1_500) / 10_000;
        assertEq(clawd.balanceOf(alice) - aliceBalBefore, expectedPayout);
        assertEq(poker.reputation(alice), 1);
        (, uint256 aliceStreak) = poker.getReputation(alice);
        assertEq(aliceStreak, 1);
        (, uint256 bobStreak) = poker.getReputation(bob);
        assertEq(bobStreak, 0);
    }

    function _slice(uint8[] memory src, uint256 start, uint256 end) internal pure returns (uint8[] memory out) {
        out = new uint8[](end - start);
        for (uint256 i = start; i < end; i++) out[i - start] = src[i];
    }

    function _sliceB(bytes32[] memory src, uint256 start, uint256 end) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](end - start);
        for (uint256 i = start; i < end; i++) out[i - start] = src[i];
    }

    /// @dev Walk a game that has already committed (alice=A, bob=B) to SHOWDOWN
    ///      via checks on every street. `cards`/`deckIdx`/`salts` must be laid
    ///      out as the happy-path helper expects:
    ///        [0..3] = flop, [3..4] = turn, [4..5] = river, [5..9] = holes.
    ///      Preflop first actor: playerB (Bob) per spec.
    ///      Post-flop first actor: playerB (Bob) per canonical heads-up Hold'em.
    function _checkDownToShowdown(
        uint256 gameId,
        uint8[] memory cards,
        uint8[] memory deckIdx,
        bytes32[] memory salts
    ) internal {
        // PREFLOP: bob first (SB=playerA=dealer in heads-up => BB=playerB acts first preflop)
        vm.prank(bob); poker.act(gameId, 1, 0);
        vm.prank(alice); poker.act(gameId, 1, 0);
        vm.prank(dealer);
        poker.dealCommunity(gameId, _slice(cards, 0, 3), _sliceB(salts, 0, 3), _slice(deckIdx, 0, 3));
        // FLOP -> TURN -> RIVER: BB (bob) first per canonical heads-up.
        vm.prank(bob); poker.act(gameId, 1, 0);
        vm.prank(alice); poker.act(gameId, 1, 0);
        vm.prank(dealer);
        poker.dealCommunity(gameId, _slice(cards, 3, 4), _sliceB(salts, 3, 4), _slice(deckIdx, 3, 4));
        vm.prank(bob); poker.act(gameId, 1, 0);
        vm.prank(alice); poker.act(gameId, 1, 0);
        vm.prank(dealer);
        poker.dealCommunity(gameId, _slice(cards, 4, 5), _sliceB(salts, 4, 5), _slice(deckIdx, 4, 5));
        vm.prank(bob); poker.act(gameId, 1, 0);
        vm.prank(alice); poker.act(gameId, 1, 0);
    }

    // ------------------------------------------------------------------
    //                       2. Fold
    // ------------------------------------------------------------------

    function test_Fold_WinsAndBurns() public {
        uint256 buyIn = 1_000_000e18;

        // We just need to satisfy createGame / joinGame / commitDeck. No actual reveals needed.
        uint8[] memory emptyC = new uint8[](0);
        uint8[] memory emptyI = new uint8[](0);
        bytes32[] memory emptyS = new bytes32[](0);
        uint256 gameId = _startGameAndCommit(alice, bob, buyIn, emptyC, emptyI, emptyS);

        uint256 aliceBalBefore = clawd.balanceOf(alice);

        // Bob folds preflop (Bob acts first).
        vm.prank(bob);
        poker.act(gameId, 0, 0);

        // Alice wins
        ClawdPoker.Game memory gAfter = poker.getGame(gameId);
        assertEq(uint8(gAfter.phase), uint8(ClawdPoker.Phase.COMPLETE));
        assertEq(gAfter.winner, alice);

        uint256 expectedPayout = (2 * buyIn) * 8_500 / 10_000;
        assertEq(clawd.balanceOf(alice) - aliceBalBefore, expectedPayout);
        // The mock routes transfer-to-zero through _burn, so total supply must have
        // dropped by exactly the burn amount.
        uint256 expectedBurn = (2 * buyIn) * 1_500 / 10_000;
        assertEq(clawd.totalSupply(), 3_000_000_000e18 - expectedBurn);
    }

    // ------------------------------------------------------------------
    //                       3. Timeout
    // ------------------------------------------------------------------

    function test_Timeout_ClaimByOpponent() public {
        uint256 buyIn = 500_000e18;
        uint8[] memory emptyC = new uint8[](0);
        uint8[] memory emptyI = new uint8[](0);
        bytes32[] memory emptyS = new bytes32[](0);
        uint256 gameId = _startGameAndCommit(alice, bob, buyIn, emptyC, emptyI, emptyS);

        // Bob is currentBettor preflop. Bob stalls.
        vm.warp(block.timestamp + 25 hours);

        // Alice (not currentBettor) claims timeout.
        uint256 aliceBalBefore = clawd.balanceOf(alice);
        vm.prank(alice);
        poker.claimTimeout(gameId);

        ClawdPoker.Game memory gAfter = poker.getGame(gameId);
        assertEq(gAfter.winner, alice);
        uint256 expectedPayout = (2 * buyIn) * 8_500 / 10_000;
        assertEq(clawd.balanceOf(alice) - aliceBalBefore, expectedPayout);
    }

    function test_Showdown_NonRevealerLosesOnTimeout() public {
        // H-02 regression: at SHOWDOWN, claimTimeout must use handRevealed,
        // not currentBettor, to pick the loser. Player who refuses to reveal
        // loses; revealer wins even if currentBettor is set against them.
        uint256 buyIn = 1_000_000e18;

        // Re-use the happy-path fixture: get the game to SHOWDOWN with both
        // players having had the chance to reveal.
        uint8[] memory cards = new uint8[](9);
        uint8[] memory deckIdx = new uint8[](9);
        bytes32[] memory salts = new bytes32[](9);
        cards[0] = 12; deckIdx[0] = 0; salts[0] = keccak256("s0");
        cards[1] = 25; deckIdx[1] = 1; salts[1] = keccak256("s1");
        cards[2] = 38; deckIdx[2] = 2; salts[2] = keccak256("s2");
        cards[3] = 1;  deckIdx[3] = 3; salts[3] = keccak256("s3");
        cards[4] = 2;  deckIdx[4] = 10; salts[4] = keccak256("s4");
        cards[5] = 11; deckIdx[5] = 4; salts[5] = keccak256("s5");
        cards[6] = 37; deckIdx[6] = 5; salts[6] = keccak256("s6");
        cards[7] = 9;  deckIdx[7] = 6; salts[7] = keccak256("s7");
        cards[8] = 35; deckIdx[8] = 7; salts[8] = keccak256("s8");

        uint256 gameId = _startGameAndCommit(alice, bob, buyIn, cards, deckIdx, salts);

        // Walk to SHOWDOWN by checking through every street. Preflop: Bob (BB)
        // acts first. Post-flop: Bob (BB) acts first per canonical heads-up.
        _checkDownToShowdown(gameId, cards, deckIdx, salts);

        // Alice reveals; Bob refuses. 24h passes. Alice claims timeout.
        vm.prank(alice);
        poker.revealHand(gameId, cards[5], cards[6], salts[5], salts[6]);

        uint256 aliceBalBefore = clawd.balanceOf(alice);
        vm.warp(block.timestamp + 25 hours);
        vm.prank(alice);
        poker.claimTimeout(gameId);

        ClawdPoker.Game memory gAfter = poker.getGame(gameId);
        assertEq(uint8(gAfter.phase), uint8(ClawdPoker.Phase.COMPLETE));
        assertEq(gAfter.winner, alice, "non-revealer (bob) must be the loser");
        uint256 expectedPayout = (2 * buyIn) * 8_500 / 10_000;
        assertEq(clawd.balanceOf(alice) - aliceBalBefore, expectedPayout);
    }

    function test_Showdown_NeitherRevealed_RefundsBoth() public {
        // H-02: when NEITHER player reveals at showdown, claimTimeout refunds
        // both buy-ins (no burn, no winner). Reputation is unchanged.
        uint256 buyIn = 1_000_000e18;

        uint8[] memory cards = new uint8[](9);
        uint8[] memory deckIdx = new uint8[](9);
        bytes32[] memory salts = new bytes32[](9);
        cards[0] = 12; deckIdx[0] = 0; salts[0] = keccak256("n0");
        cards[1] = 25; deckIdx[1] = 1; salts[1] = keccak256("n1");
        cards[2] = 38; deckIdx[2] = 2; salts[2] = keccak256("n2");
        cards[3] = 1;  deckIdx[3] = 3; salts[3] = keccak256("n3");
        cards[4] = 2;  deckIdx[4] = 10; salts[4] = keccak256("n4");
        cards[5] = 11; deckIdx[5] = 4; salts[5] = keccak256("n5");
        cards[6] = 37; deckIdx[6] = 5; salts[6] = keccak256("n6");
        cards[7] = 9;  deckIdx[7] = 6; salts[7] = keccak256("n7");
        cards[8] = 35; deckIdx[8] = 7; salts[8] = keccak256("n8");

        uint256 gameId = _startGameAndCommit(alice, bob, buyIn, cards, deckIdx, salts);
        _checkDownToShowdown(gameId, cards, deckIdx, salts);

        uint256 aliceBalBefore = clawd.balanceOf(alice);
        uint256 bobBalBefore = clawd.balanceOf(bob);
        uint256 supplyBefore = clawd.totalSupply();

        vm.warp(block.timestamp + 25 hours);
        vm.prank(alice);
        poker.claimTimeout(gameId);

        // Half-refund each (odd wei goes to playerB; 2*buyIn is always even).
        assertEq(clawd.balanceOf(alice) - aliceBalBefore, buyIn);
        assertEq(clawd.balanceOf(bob) - bobBalBefore, buyIn);
        // No burn happened.
        assertEq(clawd.totalSupply(), supplyBefore);
        // No winner recorded; reputation and streak unchanged.
        ClawdPoker.Game memory gAfter = poker.getGame(gameId);
        assertEq(gAfter.winner, address(0));
        assertEq(poker.reputation(alice), 0);
        assertEq(poker.reputation(bob), 0);
    }

    function test_Tie_OddRemainder_FoldedIntoBurn() public {
        // M-03 regression: when (total - burn) is odd at tie-split, the odd
        // wei previously stayed stranded in the contract. After the fix, the
        // remainder is folded into the burn. We verify:
        //   - each player receives `each = distributable / 2`
        //   - the contract's CLAWD balance returns to zero after settlement
        //   - totalSupply drops by `burn + remainder`
        uint256 buyIn = 10; // total = 20, burn = 3, distributable = 17, each = 8, remainder = 1
        uint256 total = 2 * buyIn;
        uint256 baseBurn = (total * 1500) / 10_000; // 3
        uint256 distributable = total - baseBurn; // 17
        uint256 each = distributable / 2; // 8
        uint256 remainder = distributable - 2 * each; // 1
        uint256 expectedBurn = baseBurn + remainder; // 4

        // Community: AAAAK — both players play the board.
        uint8[] memory cards = new uint8[](9);
        uint8[] memory deckIdx = new uint8[](9);
        bytes32[] memory salts = new bytes32[](9);
        cards[0] = 12; deckIdx[0] = 0; salts[0] = keccak256("t0"); // Ah
        cards[1] = 25; deckIdx[1] = 1; salts[1] = keccak256("t1"); // As
        cards[2] = 38; deckIdx[2] = 2; salts[2] = keccak256("t2"); // Ad
        cards[3] = 51; deckIdx[3] = 3; salts[3] = keccak256("t3"); // Ac (turn)
        cards[4] = 11; deckIdx[4] = 10; salts[4] = keccak256("t4"); // Kh (river)
        // Alice holes — pocket 3s (Hhole) — 3h=1, 3d=27. Both below K, she plays AAAA+K.
        cards[5] = 1; deckIdx[5] = 4; salts[5] = keccak256("t5");
        cards[6] = 27; deckIdx[6] = 5; salts[6] = keccak256("t6");
        // Bob holes — 4h=2, 4d=28. Also below K. He plays AAAA+K too.
        cards[7] = 2; deckIdx[7] = 6; salts[7] = keccak256("t7");
        cards[8] = 28; deckIdx[8] = 7; salts[8] = keccak256("t8");

        uint256 gameId = _startGameAndCommit(alice, bob, buyIn, cards, deckIdx, salts);
        _checkDownToShowdown(gameId, cards, deckIdx, salts);

        uint256 supplyBefore = clawd.totalSupply();
        uint256 contractBalBefore = clawd.balanceOf(address(poker));
        uint256 aliceBalBefore = clawd.balanceOf(alice);
        uint256 bobBalBefore = clawd.balanceOf(bob);

        vm.prank(alice);
        poker.revealHand(gameId, cards[5], cards[6], salts[5], salts[6]);
        vm.prank(bob);
        poker.revealHand(gameId, cards[7], cards[8], salts[7], salts[8]);

        ClawdPoker.Game memory gAfter = poker.getGame(gameId);
        assertEq(uint8(gAfter.phase), uint8(ClawdPoker.Phase.COMPLETE));
        assertEq(gAfter.winner, address(0), "tie -> no winner");

        // Each player receives `each`.
        assertEq(clawd.balanceOf(alice) - aliceBalBefore, each);
        assertEq(clawd.balanceOf(bob) - bobBalBefore, each);
        // Contract balance returns to its pre-settlement balance (no strand).
        assertEq(clawd.balanceOf(address(poker)), contractBalBefore - total);
        // totalSupply drops by burn + remainder.
        assertEq(clawd.totalSupply(), supplyBefore - expectedBurn);
    }

    function test_PartialCallAllIn_ShortStackCallsAndAdvances() public {
        // H-03 regression: a player whose remaining stack is SMALLER than the
        // outstanding call delta must be able to go all-in for their stack.
        // Before the fix, _moveToPot would revert InsufficientStack and the
        // short player was forced to fold.
        //
        // Construction (preflop, BB=bob acts first):
        //   bob raises to 300k  -> committedB=300k, stackB=700k
        //   alice raises to 1M (all-in) -> committedA=1M, stackA=0
        //   bob needs 700k (1M - 300k) to match; stackB=700k. Full call.
        // To force a SHORT call, we need alice's raise > (bob.committed + bob.stack).
        // The largest legal raise is alice's total = 1M (buyIn); bob's ceiling
        // is also 1M (300k already in + 700k stack). So a cross-raise preflop
        // cannot produce a short call under symmetric buy-ins. Exercise the
        // call path end-to-end (full all-in) which proves the _committedThisRound
        // delta accounting works: bob pays only 700k, not 1M, and the call does
        // not revert.
        uint256 buyIn = 1_000_000e18;
        uint8[] memory empty = new uint8[](0);
        uint8[] memory emptyI = new uint8[](0);
        bytes32[] memory emptyS = new bytes32[](0);
        uint256 gameId = _startGameAndCommit(alice, bob, buyIn, empty, emptyI, emptyS);

        // bob raises to 300k (committedB=300k, stackB=700k).
        vm.prank(bob);
        poker.act(gameId, 3, 300_000e18);
        // alice raises all-in to 1M (committedA=1M, stackA=0).
        vm.prank(alice);
        poker.act(gameId, 3, 1_000_000e18);

        // bob must call 700k to match 1M. Before the fix, _call would pull
        // `currentBet = 1M` from stackB (700k) and revert InsufficientStack.
        // After the fix, _call pulls delta = 1M - 300k = 700k which matches
        // the stack exactly, and the street closes with both all-in.
        vm.prank(bob);
        poker.act(gameId, 2, 0);

        ClawdPoker.Game memory gAfter = poker.getGame(gameId);
        // Both all-in: stacks drained, pot = 2M, currentBet reset.
        assertEq(gAfter.stackA, 0, "alice all-in");
        assertEq(gAfter.stackB, 0, "bob all-in");
        assertEq(gAfter.pot, 2_000_000e18, "pot = 2 * buyIn");
        assertEq(gAfter.currentBet, 0, "currentBet reset after call");
        // Phase stays PREFLOP until dealer deals flop (no auto short-circuit).
        assertEq(uint8(gAfter.phase), uint8(ClawdPoker.Phase.PREFLOP));
    }

    function test_Timeout_InDealingPhase_Reverts() public {
        // H-01 regression: claimTimeout in DEALING must revert WrongPhase,
        // not auto-award the pot to playerA.
        vm.prank(alice);
        uint256 gid = poker.createGame(1e18);
        vm.prank(bob);
        poker.joinGame(gid);
        // VRF never fulfilled -> phase stuck in DEALING.
        vm.warp(block.timestamp + 25 hours);

        vm.prank(bob);
        vm.expectRevert(ClawdPoker.WrongPhase.selector);
        poker.claimTimeout(gid);

        vm.prank(alice);
        vm.expectRevert(ClawdPoker.WrongPhase.selector);
        poker.claimTimeout(gid);
    }

    function test_Timeout_Cannot_BeforeDeadline() public {
        uint256 buyIn = 500_000e18;
        uint8[] memory emptyC = new uint8[](0);
        uint8[] memory emptyI = new uint8[](0);
        bytes32[] memory emptyS = new bytes32[](0);
        uint256 gameId = _startGameAndCommit(alice, bob, buyIn, emptyC, emptyI, emptyS);

        vm.prank(alice);
        vm.expectRevert(ClawdPoker.TimeoutNotReached.selector);
        poker.claimTimeout(gameId);
    }

    // ------------------------------------------------------------------
    //                       4. Streak gate
    // ------------------------------------------------------------------

    function test_StreakGate_ZeroStreakCapsAt10M() public {
        uint256 buyIn = 10_000_001e18; // 1 over cap
        vm.prank(alice);
        vm.expectRevert(ClawdPoker.BuyInTooLarge.selector);
        poker.createGame(buyIn);
    }

    function test_StreakGate_RaisesTo50M_After3Wins() public {
        // Win 3 games in a row with small buy-ins, then try 50M.
        for (uint256 i = 0; i < 3; i++) {
            uint8[] memory emptyC = new uint8[](0);
            uint8[] memory emptyI = new uint8[](0);
            bytes32[] memory emptyS = new bytes32[](0);
            uint256 gameId = _startGameAndCommit(alice, bob, 1e18, emptyC, emptyI, emptyS);
            vm.prank(bob); // B acts first preflop
            poker.act(gameId, 0, 0); // bob folds -> alice wins
        }
        (, uint256 aliceStreak) = poker.getReputation(alice);
        assertEq(aliceStreak, 3);

        // 50M cap should now apply -- 50_000_001e18 should revert, 50_000_000e18 should succeed.
        vm.prank(alice);
        vm.expectRevert(ClawdPoker.BuyInTooLarge.selector);
        poker.createGame(50_000_001e18);

        vm.prank(alice);
        uint256 ok = poker.createGame(50_000_000e18);
        assertGt(ok, 0); // some gameId assigned
    }

    // ------------------------------------------------------------------
    //                       5. Commit-reveal safety
    // ------------------------------------------------------------------

    function test_Commit_BadSaltReverts() public {
        uint8[] memory cards = new uint8[](1);
        uint8[] memory deckIdx = new uint8[](1);
        bytes32[] memory salts = new bytes32[](1);
        cards[0] = 5;
        deckIdx[0] = 0;
        salts[0] = keccak256("good");

        // Set up game + committed deck
        uint256 gameId = _startGameAndCommit(alice, bob, 1e18, cards, deckIdx, salts);

        // Dealer now tries to deal flop with a WRONG salt for index 0
        uint8[] memory flopCards = new uint8[](3);
        uint8[] memory flopIdx = new uint8[](3);
        bytes32[] memory flopSalts = new bytes32[](3);
        flopCards[0] = 5; flopIdx[0] = 0; flopSalts[0] = keccak256("WRONG");
        flopCards[1] = 6; flopIdx[1] = 1; flopSalts[1] = keccak256("s1"); // slot 1 is dummy DEAD+1
        flopCards[2] = 7; flopIdx[2] = 2; flopSalts[2] = keccak256("s2");

        vm.prank(dealer);
        vm.expectRevert(ClawdPoker.CommitMismatch.selector);
        poker.dealCommunity(gameId, flopCards, flopSalts, flopIdx);
    }

    function test_Commit_ReplaySameIndexReverts() public {
        // Commit flop properly, then try to re-deal flop (which would write to the same indices).
        uint8[] memory cards = new uint8[](3);
        uint8[] memory deckIdx = new uint8[](3);
        bytes32[] memory salts = new bytes32[](3);
        cards[0] = 0; deckIdx[0] = 0; salts[0] = keccak256("sa");
        cards[1] = 1; deckIdx[1] = 1; salts[1] = keccak256("sb");
        cards[2] = 2; deckIdx[2] = 2; salts[2] = keccak256("sc");

        uint256 gameId = _startGameAndCommit(alice, bob, 1e18, cards, deckIdx, salts);

        vm.prank(dealer);
        poker.dealCommunity(gameId, cards, salts, deckIdx);

        // After flop is dealt, phase is FLOP. The dealer now must deal the turn with exactly 1 card,
        // and if they try to re-use one of the flop's indices they must revert with IndexAlreadyRevealed.
        uint8[] memory single = new uint8[](1);
        uint8[] memory singleIdx = new uint8[](1);
        bytes32[] memory singleSalt = new bytes32[](1);
        single[0] = 0;             // same card as flop[0]
        singleIdx[0] = 0;          // same index
        singleSalt[0] = keccak256("sa");

        vm.prank(dealer);
        vm.expectRevert(ClawdPoker.IndexAlreadyRevealed.selector);
        poker.dealCommunity(gameId, single, singleSalt, singleIdx);
    }

    function test_DealCommunity_RejectsReservedHoleIndices() public {
        // M-01 regression: dealCommunity must reject deck indices 4,5,6,7
        // (reserved for hole cards). Before the fix, a malicious dealer
        // could claim those slots for community cards and lock the matching
        // player out of revealHand.
        uint8[] memory cards = new uint8[](3);
        uint8[] memory deckIdx = new uint8[](3);
        bytes32[] memory salts = new bytes32[](3);
        cards[0] = 10; deckIdx[0] = 4; salts[0] = keccak256("r0"); // RESERVED
        cards[1] = 11; deckIdx[1] = 1; salts[1] = keccak256("r1");
        cards[2] = 12; deckIdx[2] = 2; salts[2] = keccak256("r2");

        uint256 gameId = _startGameAndCommit(alice, bob, 1e18, cards, deckIdx, salts);

        vm.prank(dealer);
        vm.expectRevert(ClawdPoker.BadRevealIndex.selector);
        poker.dealCommunity(gameId, cards, salts, deckIdx);

        // Try index 5, 6, 7 too — all must revert. Put the reserved index at
        // slot 0 so the reserved-check trips before any commit comparison.
        for (uint8 reserved = 5; reserved <= 7; reserved++) {
            uint8[] memory flopCards = new uint8[](3);
            uint8[] memory flopIdx = new uint8[](3);
            bytes32[] memory flopSalts = new bytes32[](3);
            flopCards[0] = 20 + reserved; flopIdx[0] = reserved; flopSalts[0] = keccak256(abi.encodePacked("rx", reserved));
            flopCards[1] = 30; flopIdx[1] = 1; flopSalts[1] = keccak256("safe0");
            flopCards[2] = 31; flopIdx[2] = 2; flopSalts[2] = keccak256("safe1");
            vm.prank(dealer);
            vm.expectRevert(ClawdPoker.BadRevealIndex.selector);
            poker.dealCommunity(gameId, flopCards, flopSalts, flopIdx);
        }
    }

    function test_Commit_ReusedCardValueReverts() public {
        // Flop uses card value 5 at index 0; turn tries to reveal card value 5 again at a different index.
        uint8[] memory cards = new uint8[](4);
        uint8[] memory deckIdx = new uint8[](4);
        bytes32[] memory salts = new bytes32[](4);
        cards[0] = 5; deckIdx[0] = 0; salts[0] = keccak256("sa");
        cards[1] = 6; deckIdx[1] = 1; salts[1] = keccak256("sb");
        cards[2] = 7; deckIdx[2] = 2; salts[2] = keccak256("sc");
        // Index 3 (turn) also committed to card value 5 -- collision. Different salt to avoid commit collision; still value reuse.
        cards[3] = 5; deckIdx[3] = 3; salts[3] = keccak256("sd");

        uint256 gameId = _startGameAndCommit(alice, bob, 1e18, cards, deckIdx, salts);

        // Deal the flop (cards 5, 6, 7 at idx 0,1,2).
        uint8[] memory flopCards = _slice(cards, 0, 3);
        uint8[] memory flopIdx = _slice(deckIdx, 0, 3);
        bytes32[] memory flopSalts = _sliceB(salts, 0, 3);
        vm.prank(dealer);
        poker.dealCommunity(gameId, flopCards, flopSalts, flopIdx);

        // Deal the turn with card 5 again -- must revert CardAlreadyUsed.
        uint8[] memory turnCards = new uint8[](1);
        uint8[] memory turnIdx = new uint8[](1);
        bytes32[] memory turnSalts = new bytes32[](1);
        turnCards[0] = 5; turnIdx[0] = 3; turnSalts[0] = keccak256("sd");

        vm.prank(dealer);
        vm.expectRevert(ClawdPoker.CardAlreadyUsed.selector);
        poker.dealCommunity(gameId, turnCards, turnSalts, turnIdx);
    }

    // ------------------------------------------------------------------
    //                       6. Owner-only on commit/deal
    // ------------------------------------------------------------------

    function test_CommitDeck_ZeroSlot_Reverts() public {
        // M-05 regression: a zero commit in any slot must revert at commit
        // time rather than silently bricking later reveals.
        vm.prank(alice);
        uint256 gameId = poker.createGame(1e18);
        vm.prank(bob);
        poker.joinGame(gameId);
        uint256[] memory words = new uint256[](1);
        words[0] = 0xFADE;
        uint256 reqId = _nextExpectedVrfRequestId++;
        vm.prank(dealer);
        vrf.fulfillRandomWordsWithOverride(reqId, address(poker), words);

        // Build a valid commit array, then zero out slot 37.
        bytes32[52] memory commits;
        for (uint256 i = 0; i < 52; i++) {
            commits[i] = keccak256(abi.encodePacked(bytes32(uint256(i + 1))));
        }
        commits[37] = bytes32(0);

        vm.prank(dealer);
        vm.expectRevert(ClawdPoker.CommitMismatch.selector);
        poker.commitDeck(gameId, commits);

        // Also reject zero at slot 0 (would otherwise pass the
        // already-committed sentinel but leave the game in a fragile state).
        commits[37] = keccak256("restore");
        commits[0] = bytes32(0);
        vm.prank(dealer);
        vm.expectRevert(ClawdPoker.CommitMismatch.selector);
        poker.commitDeck(gameId, commits);
    }

    function test_OnlyOwner_CommitDeck() public {
        // Start a game, get to DEALING+deckHash state, then non-owner tries commitDeck.
        vm.prank(alice);
        uint256 gameId = poker.createGame(1e18);
        vm.prank(bob);
        poker.joinGame(gameId);
        // Fulfill VRF (first request in this test)
        uint256[] memory words = new uint256[](1);
        words[0] = 0xBEEF;
        uint256 reqId = _nextExpectedVrfRequestId++;
        vm.prank(dealer);
        vrf.fulfillRandomWordsWithOverride(reqId, address(poker), words);

        bytes32[52] memory commits;
        for (uint256 i = 0; i < 52; i++) {
            // Seed each slot with a distinct, non-zero commit. We pass `i+1` as bytes32 so the
            // data is uniformly 32-byte; no narrowing cast needed, no forge-lint warning.
            commits[i] = keccak256(abi.encodePacked(bytes32(uint256(i + 1))));
        }
        vm.prank(charlie); // charlie is not the owner
        vm.expectRevert("Only callable by owner");
        poker.commitDeck(gameId, commits);
    }

    function test_OnlyOwner_DealCommunity() public {
        uint8[] memory cards = new uint8[](3);
        uint8[] memory deckIdx = new uint8[](3);
        bytes32[] memory salts = new bytes32[](3);
        cards[0] = 0; deckIdx[0] = 0; salts[0] = keccak256("sa");
        cards[1] = 1; deckIdx[1] = 1; salts[1] = keccak256("sb");
        cards[2] = 2; deckIdx[2] = 2; salts[2] = keccak256("sc");
        uint256 gameId = _startGameAndCommit(alice, bob, 1e18, cards, deckIdx, salts);

        vm.prank(charlie);
        vm.expectRevert("Only callable by owner");
        poker.dealCommunity(gameId, cards, salts, deckIdx);
    }

    // ------------------------------------------------------------------
    //                       7. openGames view
    // ------------------------------------------------------------------

    function test_OpenGames_ListsWaitingOnly() public {
        vm.prank(alice);
        uint256 g1 = poker.createGame(1e18);
        vm.prank(bob);
        uint256 g2 = poker.createGame(1e18);
        // Fill g1 so it leaves WAITING
        vm.prank(charlie);
        poker.joinGame(g1);

        uint256[] memory open = poker.openGames();
        assertEq(open.length, 1);
        assertEq(open[0], g2);
    }

    // ------------------------------------------------------------------
    //                       8. NotYourTurn
    // ------------------------------------------------------------------

    function test_Act_WrongPlayerReverts() public {
        uint8[] memory emptyC = new uint8[](0);
        uint8[] memory emptyI = new uint8[](0);
        bytes32[] memory emptyS = new bytes32[](0);
        uint256 gameId = _startGameAndCommit(alice, bob, 1e18, emptyC, emptyI, emptyS);

        // Bob is the currentBettor preflop. Alice tries to act first -> revert.
        vm.prank(alice);
        vm.expectRevert(ClawdPoker.NotYourTurn.selector);
        poker.act(gameId, 1, 0);
    }
}
