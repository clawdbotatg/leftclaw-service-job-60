// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PokerHandEvaluator} from "../contracts/PokerHandEvaluator.sol";

/// @dev All tests use the engine encoding: card = suit * 13 + rank, rank 0..12 (0 = 2, 12 = A).
contract PokerHandEvaluatorTest is Test {
    // ---- small helpers ----
    function c(uint8 suit, uint8 rank) internal pure returns (uint8) {
        return suit * 13 + rank;
    }

    function hand(uint8 a, uint8 b, uint8 d, uint8 e, uint8 f, uint8 g, uint8 h)
        internal
        pure
        returns (uint8[7] memory out)
    {
        out[0] = a;
        out[1] = b;
        out[2] = d;
        out[3] = e;
        out[4] = f;
        out[5] = g;
        out[6] = h;
    }

    function _eval(uint8[7] memory cards) internal pure returns (uint256) {
        return PokerHandEvaluator.evaluate(cards);
    }

    // ------------------- 1. High card -------------------
    function test_HighCard_Basic() public pure {
        // A, K, J, 9, 7 (mixed suits), pair-less, straight-less
        uint8[7] memory h = hand(
            c(0, 12), // Ah
            c(1, 11), // Ks
            c(2, 9), // Jd
            c(3, 7), // 9c
            c(0, 5), // 7h
            c(1, 3), // 5s
            c(2, 1) // 3d
        );
        uint256 r = _eval(h);
        // Class high card (0) -- so top nibble above class shift must be 0
        assertEq(r >> 20, 0, "class should be HIGH_CARD");
    }

    // ------------------- 2. Pair -------------------
    function test_Pair_BeatsHighCard() public pure {
        uint8[7] memory p = hand(c(0, 12), c(1, 12), c(2, 9), c(3, 7), c(0, 5), c(1, 3), c(2, 1));
        uint8[7] memory h = hand(c(0, 12), c(1, 11), c(2, 9), c(3, 7), c(0, 5), c(1, 3), c(2, 1));
        assertGt(_eval(p), _eval(h));
    }

    // ------------------- 3. Two pair -------------------
    function test_TwoPair_BeatsPair() public pure {
        uint8[7] memory tp = hand(c(0, 12), c(1, 12), c(2, 9), c(3, 9), c(0, 5), c(1, 3), c(2, 1));
        uint8[7] memory p = hand(c(0, 12), c(1, 12), c(2, 9), c(3, 7), c(0, 5), c(1, 3), c(2, 1));
        assertGt(_eval(tp), _eval(p));
    }

    // ------------------- 4. Trips -------------------
    function test_Trips_BeatsTwoPair() public pure {
        uint8[7] memory t = hand(c(0, 12), c(1, 12), c(2, 12), c(3, 9), c(0, 5), c(1, 3), c(2, 1));
        uint8[7] memory tp = hand(c(0, 12), c(1, 12), c(2, 9), c(3, 9), c(0, 5), c(1, 3), c(2, 1));
        assertGt(_eval(t), _eval(tp));
    }

    // ------------------- 5. Straight (6-high) -------------------
    function test_Straight_Basic() public pure {
        // 2-3-4-5-6 of mixed suits
        uint8[7] memory s = hand(
            c(0, 0), // 2
            c(1, 1), // 3
            c(2, 2), // 4
            c(3, 3), // 5
            c(0, 4), // 6
            c(1, 10), // Q (noise)
            c(2, 8) // T (noise)
        );
        uint256 r = _eval(s);
        assertEq(r >> 20, 4, "class should be STRAIGHT");
    }

    // ------------------- 6. Wheel (A-2-3-4-5) -------------------
    function test_Wheel_IsStraightButLowerThan6High() public pure {
        uint8[7] memory wheel = hand(
            c(0, 12), // A
            c(1, 0), // 2
            c(2, 1), // 3
            c(3, 2), // 4
            c(0, 3), // 5
            c(1, 8), // T noise
            c(2, 9) // J noise
        );
        uint8[7] memory sixHigh = hand(
            c(0, 0), // 2
            c(1, 1), // 3
            c(2, 2), // 4
            c(3, 3), // 5
            c(0, 4), // 6
            c(1, 8),
            c(2, 9)
        );
        uint256 rw = _eval(wheel);
        uint256 r6 = _eval(sixHigh);
        assertEq(rw >> 20, 4, "wheel should be a STRAIGHT");
        assertEq(r6 >> 20, 4, "6-high should be a STRAIGHT");
        assertLt(rw, r6, "wheel must be weaker than 6-high straight");
    }

    // ------------------- 7. Flush -------------------
    function test_Flush_Basic() public pure {
        // Five hearts (suit 0), ranks 2,5,8,10,12 (not sequential)
        uint8[7] memory f = hand(
            c(0, 0),
            c(0, 3),
            c(0, 6),
            c(0, 8),
            c(0, 10),
            c(1, 11), // Ks noise
            c(2, 9) // Jd noise
        );
        uint256 r = _eval(f);
        assertEq(r >> 20, 5, "class should be FLUSH");
    }

    function test_Flush_BeatsStraight() public pure {
        uint8[7] memory f = hand(c(0, 0), c(0, 3), c(0, 6), c(0, 8), c(0, 10), c(1, 11), c(2, 9));
        uint8[7] memory s = hand(c(0, 0), c(1, 1), c(2, 2), c(3, 3), c(0, 4), c(1, 10), c(2, 8));
        assertGt(_eval(f), _eval(s));
    }

    // ------------------- 8. Full house -------------------
    function test_FullHouse_Basic() public pure {
        uint8[7] memory fh = hand(
            c(0, 12), // Ah
            c(1, 12), // As
            c(2, 12), // Ad
            c(3, 9), // Tc (rank 9 = J? rank 9 is J actually; let me use rank 7 => 9)
            c(0, 7), // 9h
            c(1, 7), // 9s
            c(2, 3) // 5d noise
        );
        // Trips of A, pair of 9.
        uint256 r = _eval(fh);
        assertEq(r >> 20, 6, "class should be FULL_HOUSE");
    }

    function test_FullHouse_TwoTripsPicksBestPair() public pure {
        // Trips of A, trips of 9 -> full house AAA99
        uint8[7] memory h = hand(c(0, 12), c(1, 12), c(2, 12), c(3, 7), c(0, 7), c(1, 7), c(2, 3));
        uint256 r = _eval(h);
        assertEq(r >> 20, 6, "class should be FULL_HOUSE");
        // class shift = 20; the next 4 bits (shift 16) are the trips rank (12), and 12..15 bits are the pair rank (7)
        uint256 trips = (r >> 16) & 0xF;
        uint256 pair = (r >> 12) & 0xF;
        assertEq(trips, 12, "trips rank should be A");
        assertEq(pair, 7, "pair rank should be 9 (from the second trips set)");
    }

    // ------------------- 9. Quads -------------------
    function test_Quads_Basic() public pure {
        uint8[7] memory q = hand(c(0, 12), c(1, 12), c(2, 12), c(3, 12), c(0, 7), c(1, 3), c(2, 1));
        uint256 r = _eval(q);
        assertEq(r >> 20, 7, "class should be QUADS");
    }

    function test_Quads_BeatsFullHouse() public pure {
        uint8[7] memory q = hand(c(0, 12), c(1, 12), c(2, 12), c(3, 12), c(0, 7), c(1, 3), c(2, 1));
        uint8[7] memory fh = hand(c(0, 11), c(1, 11), c(2, 11), c(3, 7), c(0, 7), c(1, 3), c(2, 1));
        assertGt(_eval(q), _eval(fh));
    }

    // ------------------- 10. Straight flush -------------------
    function test_StraightFlush_Basic() public pure {
        // 5-9 of hearts (suit 0). ranks 3,4,5,6,7 -> 5,6,7,8,9
        uint8[7] memory sf = hand(
            c(0, 3),
            c(0, 4),
            c(0, 5),
            c(0, 6),
            c(0, 7),
            c(1, 12), // Ks noise off-suit
            c(2, 9) // Jd noise
        );
        uint256 r = _eval(sf);
        assertEq(r >> 20, 8, "class should be STRAIGHT_FLUSH");
    }

    function test_StraightFlush_Wheel() public pure {
        // A,2,3,4,5 all of one suit
        uint8[7] memory sf = hand(
            c(0, 12), c(0, 0), c(0, 1), c(0, 2), c(0, 3), c(1, 10), c(2, 7)
        );
        uint256 r = _eval(sf);
        assertEq(r >> 20, 8, "class should be STRAIGHT_FLUSH");
    }

    // ------------------- 11. Royal flush -------------------
    function test_RoyalFlush_IsStraightFlushAHigh() public pure {
        // T,J,Q,K,A all spades (suit 1). Ranks 8,9,10,11,12.
        uint8[7] memory rf = hand(
            c(1, 8),
            c(1, 9),
            c(1, 10),
            c(1, 11),
            c(1, 12),
            c(2, 0), // 2d noise
            c(3, 3) // 5c noise
        );
        uint256 r = _eval(rf);
        assertEq(r >> 20, 8, "class should be STRAIGHT_FLUSH");
        // Top card in the encoded run is ace (rank 12), so the next nibble after the class should be 12.
        uint256 top = (r >> 16) & 0xF;
        assertEq(top, 12, "top card should be ace");
    }

    // ------------------- 12. Tie-breakers: high-card kicker (5th card differs) -------------------
    function test_HighCard_KickerOrdering() public pure {
        // Both have same top 4 ranks; 5th differs. Hand A has a 6 (rank 4) as 5th, hand B has a 5 (rank 3).
        uint8[7] memory a = hand(c(0, 12), c(1, 10), c(2, 8), c(3, 6), c(0, 4), c(1, 2), c(2, 0));
        uint8[7] memory b = hand(c(0, 12), c(1, 10), c(2, 8), c(3, 6), c(0, 3), c(1, 1), c(2, 0));
        assertGt(_eval(a), _eval(b));
    }

    // ------------------- 13. Tie-breakers: pair with kicker -------------------
    function test_Pair_KickerOrdering() public pure {
        // Pair of 9s. Kickers A vs K.
        uint8[7] memory a = hand(c(0, 7), c(1, 7), c(2, 12), c(3, 8), c(0, 5), c(1, 3), c(2, 1));
        uint8[7] memory b = hand(c(0, 7), c(1, 7), c(2, 11), c(3, 8), c(0, 5), c(1, 3), c(2, 1));
        assertGt(_eval(a), _eval(b));
    }

    // ------------------- 14. 6-card straight collapses to 5 (best high) -------------------
    function test_SixCardStraight_PicksHighestEnd() public pure {
        // 4-5-6-7-8-9 all usable, plus two more. Best straight is 5..9 (9-high).
        uint8[7] memory h = hand(
            c(0, 2), // 4
            c(1, 3), // 5
            c(2, 4), // 6
            c(3, 5), // 7
            c(0, 6), // 8
            c(1, 7), // 9
            c(2, 11) // K noise
        );
        uint256 r = _eval(h);
        assertEq(r >> 20, 4, "class should be STRAIGHT");
        uint256 top = (r >> 16) & 0xF;
        assertEq(top, 7, "top of best 5-run should be rank 7 (=9)");
    }

    // ------------------- 15. Full house (trips + pair, trips wins over lower pair) -------------------
    function test_FullHouse_TripsBeatsLowerPair() public pure {
        // Trips 9, pair of As, kicker: full house 9-over-A? No -- trips takes precedence as the big part.
        uint8[7] memory h = hand(c(0, 7), c(1, 7), c(2, 7), c(3, 12), c(0, 12), c(1, 3), c(2, 1));
        uint256 r = _eval(h);
        assertEq(r >> 20, 6, "class should be FULL_HOUSE");
        uint256 trips = (r >> 16) & 0xF;
        uint256 pair = (r >> 12) & 0xF;
        assertEq(trips, 7, "trips is 9");
        assertEq(pair, 12, "pair is A");
    }

    // ------------------- 16. Flush not confused by 4 same-suit -------------------
    function test_Flush_RequiresFive() public pure {
        // 4 hearts + something else
        uint8[7] memory h = hand(
            c(0, 12),
            c(0, 10),
            c(0, 8),
            c(0, 6),
            c(1, 4), // different suit
            c(2, 2),
            c(3, 0)
        );
        uint256 r = _eval(h);
        // Should NOT be a flush (only 4 hearts), and it's a high-card.
        assertEq(r >> 20, 0, "should be HIGH_CARD not FLUSH");
    }

    // ------------------- 17. Straight not across suits with a gap -------------------
    function test_Straight_RequiresConsecutive() public pure {
        // 2,3,4,6,7 -- gap at 5 -> no straight, just high card
        uint8[7] memory h = hand(
            c(0, 0), c(1, 1), c(2, 2), c(3, 4), c(0, 5), c(1, 10), c(2, 7)
        );
        uint256 r = _eval(h);
        // h has rank 7 (=9) twice? No -- all distinct ranks. So it's HIGH_CARD.
        assertEq(r >> 20, 0, "gap in straight should fall back to HIGH_CARD");
    }
}
