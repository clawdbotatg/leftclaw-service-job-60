// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PokerHandEvaluator
/// @notice 7-card Texas Hold'em hand evaluator. Returns a monotonically ordered
///         rank where a larger number always beats a smaller one, irrespective of
///         hand class.
/// @dev The encoding reserves the top 4 bits for the hand class (0..8) and the
///      remaining bits for the 5 best card ranks (5 * 4 bits = 20 bits, each 0..12).
///      That is strictly sufficient to break ties within a class.
///
///      Card encoding matches the engine:
///        suit = card / 13     (0..3)
///        rank = card % 13     (0=2, 1=3, ..., 11=K, 12=A)
///
///      Wheel (A-2-3-4-5) is handled explicitly as a 5-high straight.
///
///      Design is inspired by common open-source Solidity 7-card evaluators
///      (e.g. the "HoldEmPokerHandEvaluator" family) but was written from
///      first principles to remain compact and MIT-licensed.
library PokerHandEvaluator {
    // Hand classes, from weakest to strongest
    uint256 internal constant CLASS_HIGH_CARD = 0;
    uint256 internal constant CLASS_PAIR = 1;
    uint256 internal constant CLASS_TWO_PAIR = 2;
    uint256 internal constant CLASS_TRIPS = 3;
    uint256 internal constant CLASS_STRAIGHT = 4;
    uint256 internal constant CLASS_FLUSH = 5;
    uint256 internal constant CLASS_FULL_HOUSE = 6;
    uint256 internal constant CLASS_QUADS = 7;
    uint256 internal constant CLASS_STRAIGHT_FLUSH = 8;

    // Top 4 bits are the class, giving plenty of headroom over the 20-bit kicker block.
    uint256 internal constant CLASS_SHIFT = 20;

    /// @notice Evaluate the best 5-card hand out of 7 cards.
    /// @param cards 7 cards, each in [0,51]. Duplicates must not be passed in.
    /// @return rank An opaque rank score; larger is stronger.
    function evaluate(uint8[7] memory cards) internal pure returns (uint256 rank) {
        // Count per-rank occurrences and per-suit occurrences.
        uint8[13] memory rankCount;
        uint8[4] memory suitCount;
        // Bitmask of ranks present anywhere (used for straight detection).
        uint16 rankMask;
        // Per-suit rank bitmask (used for flush / straight-flush detection).
        uint16[4] memory suitRankMask;

        for (uint256 i = 0; i < 7; i++) {
            uint8 c = cards[i];
            // Defensive: if a caller passes >= 52 the behaviour is still defined
            // because modular arithmetic is used throughout; but we keep it simple.
            uint8 r = c % 13;
            uint8 s = c / 13;
            rankCount[r] += 1;
            suitCount[s] += 1;
            rankMask |= uint16(1) << r;
            suitRankMask[s] |= uint16(1) << r;
        }

        // ---------- Straight-flush / flush detection ----------
        uint256 flushSuit = 4; // 4 sentinel for "no flush"
        for (uint256 s = 0; s < 4; s++) {
            if (suitCount[s] >= 5) {
                flushSuit = s;
                break;
            }
        }

        if (flushSuit != 4) {
            // Check for a straight flush within that suit only.
            uint16 sm = suitRankMask[flushSuit];
            uint256 shi = _highestStraight(sm);
            if (shi != type(uint256).max) {
                return _encode(CLASS_STRAIGHT_FLUSH, shi, 0, 0, 0, 0);
            }
            // Plain flush: pick the 5 highest ranks of that suit.
            (uint256 f1, uint256 f2, uint256 f3, uint256 f4, uint256 f5) = _topFiveFromMask(sm);
            return _encode(CLASS_FLUSH, f1, f2, f3, f4, f5);
        }

        // ---------- Rank multiplicities ----------
        // Iterate from highest rank down so that "best of class" ordering is natural.
        uint256 quadsRank = type(uint256).max;
        uint256 trips1 = type(uint256).max;
        uint256 trips2 = type(uint256).max;
        uint256 pair1 = type(uint256).max;
        uint256 pair2 = type(uint256).max;

        for (uint256 ri = 13; ri > 0; ri--) {
            uint256 r = ri - 1;
            uint8 n = rankCount[r];
            if (n == 4) {
                if (quadsRank == type(uint256).max) quadsRank = r;
            } else if (n == 3) {
                if (trips1 == type(uint256).max) trips1 = r;
                else if (trips2 == type(uint256).max) trips2 = r;
            } else if (n == 2) {
                if (pair1 == type(uint256).max) pair1 = r;
                else if (pair2 == type(uint256).max) pair2 = r;
            }
        }

        // ---------- Quads ----------
        if (quadsRank != type(uint256).max) {
            // Kicker: the highest rank that isn't the quad.
            uint256 kicker = _highestExcluding(rankMask, quadsRank, type(uint256).max);
            return _encode(CLASS_QUADS, quadsRank, kicker, 0, 0, 0);
        }

        // ---------- Full house ----------
        if (trips1 != type(uint256).max && (trips2 != type(uint256).max || pair1 != type(uint256).max)) {
            // Best full house is "best trips + best pair/leftover trips".
            uint256 pairForFull = (trips2 != type(uint256).max && (pair1 == type(uint256).max || trips2 > pair1))
                ? trips2
                : pair1;
            return _encode(CLASS_FULL_HOUSE, trips1, pairForFull, 0, 0, 0);
        }

        // ---------- Straight ----------
        uint256 shiAll = _highestStraight(rankMask);
        if (shiAll != type(uint256).max) {
            return _encode(CLASS_STRAIGHT, shiAll, 0, 0, 0, 0);
        }

        // ---------- Trips ----------
        if (trips1 != type(uint256).max) {
            // Two kickers, excluding the trips rank.
            uint256 k1 = _highestExcluding(rankMask, trips1, type(uint256).max);
            uint256 k2 = _highestExcluding(rankMask, trips1, k1);
            return _encode(CLASS_TRIPS, trips1, k1, k2, 0, 0);
        }

        // ---------- Two pair ----------
        if (pair1 != type(uint256).max && pair2 != type(uint256).max) {
            uint256 k1 = _highestExcluding(rankMask, pair1, pair2);
            return _encode(CLASS_TWO_PAIR, pair1, pair2, k1, 0, 0);
        }

        // ---------- One pair ----------
        if (pair1 != type(uint256).max) {
            uint256 k1 = _highestExcluding(rankMask, pair1, type(uint256).max);
            uint256 k2 = _highestExcluding(rankMask, pair1, k1);
            uint256 k3 = _highestExcludingMany(rankMask, pair1, k1, k2);
            return _encode(CLASS_PAIR, pair1, k1, k2, k3, 0);
        }

        // ---------- High card ----------
        (uint256 h1, uint256 h2, uint256 h3, uint256 h4, uint256 h5) = _topFiveFromMask(rankMask);
        return _encode(CLASS_HIGH_CARD, h1, h2, h3, h4, h5);
    }

    // ---------------------------------------------------------------------
    //                         Internal helpers
    // ---------------------------------------------------------------------

    /// @dev Pack a hand class and up to five tie-breaker ranks into a single uint.
    function _encode(uint256 class_, uint256 a, uint256 b, uint256 c, uint256 d, uint256 e)
        private
        pure
        returns (uint256)
    {
        // Shift each tie-breaker up by 4 bits. Unused slots are 0 which always sorts below a real rank.
        // Store a+1 etc. so that "no kicker" (represented as 0 here) actually means rank=2 present?
        // No — we want genuine absence to collate to 0, and ranks are already 0..12. Since all hand
        // classes either fill the exact same number of kickers or leave strictly fewer for the weaker
        // class, two hands of the SAME class always fill the same kickers, so zeros never collide with
        // a real tie-breaker.
        return (class_ << CLASS_SHIFT) | (a << 16) | (b << 12) | (c << 8) | (d << 4) | e;
    }

    /// @dev Given a 13-bit rank bitmask, return the top rank of the highest 5-in-a-row run, including
    ///      the wheel (A-2-3-4-5 which is ranks 12,0,1,2,3). Returns type(uint256).max if none.
    function _highestStraight(uint16 mask) private pure returns (uint256) {
        // Walk from the top (A=12). Check every window of 5 consecutive ranks.
        for (uint256 i = 12; i >= 4; i--) {
            uint16 window = (uint16(1) << i) | (uint16(1) << (i - 1)) | (uint16(1) << (i - 2))
                | (uint16(1) << (i - 3)) | (uint16(1) << (i - 4));
            if ((mask & window) == window) {
                return i;
            }
            if (i == 4) break; // guard against underflow
        }
        // Wheel: A (12), 2 (0), 3 (1), 4 (2), 5 (3)
        uint16 wheel = (uint16(1) << 12) | (uint16(1) << 0) | (uint16(1) << 1) | (uint16(1) << 2) | (uint16(1) << 3);
        if ((mask & wheel) == wheel) {
            // 5-high straight. Rank 3 (=5).
            return 3;
        }
        return type(uint256).max;
    }

    /// @dev Extract the top 5 set bits of a 13-bit rank mask. Caller guarantees at least 5 bits set.
    function _topFiveFromMask(uint16 mask)
        private
        pure
        returns (uint256 a, uint256 b, uint256 c, uint256 d, uint256 e)
    {
        uint256[5] memory out;
        uint256 idx;
        for (uint256 i = 13; i > 0; i--) {
            uint256 r = i - 1;
            if ((mask & (uint16(1) << r)) != 0) {
                out[idx++] = r;
                if (idx == 5) break;
            }
        }
        return (out[0], out[1], out[2], out[3], out[4]);
    }

    /// @dev Highest rank in `mask` that is neither `excludeA` nor `excludeB`.
    function _highestExcluding(uint16 mask, uint256 excludeA, uint256 excludeB) private pure returns (uint256) {
        for (uint256 i = 13; i > 0; i--) {
            uint256 r = i - 1;
            if (r == excludeA || r == excludeB) continue;
            if ((mask & (uint16(1) << r)) != 0) return r;
        }
        return 0;
    }

    /// @dev Highest rank in `mask` that is not in {excludeA, excludeB, excludeC}.
    function _highestExcludingMany(uint16 mask, uint256 excludeA, uint256 excludeB, uint256 excludeC)
        private
        pure
        returns (uint256)
    {
        for (uint256 i = 13; i > 0; i--) {
            uint256 r = i - 1;
            if (r == excludeA || r == excludeB || r == excludeC) continue;
            if ((mask & (uint16(1) << r)) != 0) return r;
        }
        return 0;
    }
}
