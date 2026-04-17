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

    /// @notice Counts struct -- extracted to keep `evaluate` under the stack limit.
    struct Counts {
        uint16 rankMask;
        uint16[4] suitRankMask;
        uint8[13] rankCount;
        uint8[4] suitCount;
    }

    /// @notice Evaluate the best 5-card hand out of 7 cards.
    /// @param cards 7 cards, each in [0,51]. Duplicates must not be passed in.
    /// @return rank An opaque rank score; larger is stronger.
    function evaluate(uint8[7] memory cards) internal pure returns (uint256 rank) {
        Counts memory k = _count(cards);

        // ---------- Straight-flush / flush detection ----------
        uint256 flushResult = _evaluateFlush(k);
        if (flushResult != 0) return flushResult;

        // ---------- Rank multiplicities ----------
        // Packed quartet: quadsRank | trips1 | trips2 | pair1 | pair2. Sentinel 0xF = absent.
        uint256 mult = _rankMultiplicities(k.rankCount);
        return _evaluateByMult(k.rankMask, mult);
    }

    /// @dev Tally rank/suit histograms and bitmasks.
    function _count(uint8[7] memory cards) private pure returns (Counts memory k) {
        for (uint256 i = 0; i < 7; i++) {
            uint8 card = cards[i];
            uint8 r = card % 13;
            uint8 s = card / 13;
            k.rankCount[r] += 1;
            k.suitCount[s] += 1;
            k.rankMask |= uint16(1) << uint16(r);
            k.suitRankMask[s] |= uint16(1) << uint16(r);
        }
    }

    /// @dev Returns a non-zero encoded rank for a flush / straight-flush, else 0.
    function _evaluateFlush(Counts memory k) private pure returns (uint256) {
        uint256 flushSuit = 4;
        for (uint256 s = 0; s < 4; s++) {
            if (k.suitCount[s] >= 5) {
                flushSuit = s;
                break;
            }
        }
        if (flushSuit == 4) return 0;

        uint16 sm = k.suitRankMask[flushSuit];
        uint256 shi = _highestStraight(sm);
        if (shi != type(uint256).max) {
            return _encode(CLASS_STRAIGHT_FLUSH, shi, 0, 0, 0, 0);
        }
        (uint256 f1, uint256 f2, uint256 f3, uint256 f4, uint256 f5) = _topFiveFromMask(sm);
        return _encode(CLASS_FLUSH, f1, f2, f3, f4, f5);
    }

    /// @dev Pack quadsRank / trips1 / trips2 / pair1 / pair2 into a uint40 (5 nibbles), MSB first.
    ///      Absent = 0xF (ranks are only 0..12 so 0xF is distinguishable).
    function _rankMultiplicities(uint8[13] memory rankCount) private pure returns (uint256 packed) {
        uint256 quadsRank = 0xF;
        uint256 trips1 = 0xF;
        uint256 trips2 = 0xF;
        uint256 pair1 = 0xF;
        uint256 pair2 = 0xF;

        for (uint256 ri = 13; ri > 0; ri--) {
            uint256 r = ri - 1;
            uint8 n = rankCount[r];
            if (n == 4) {
                if (quadsRank == 0xF) quadsRank = r;
            } else if (n == 3) {
                if (trips1 == 0xF) trips1 = r;
                else if (trips2 == 0xF) trips2 = r;
            } else if (n == 2) {
                if (pair1 == 0xF) pair1 = r;
                else if (pair2 == 0xF) pair2 = r;
            }
        }
        packed = (quadsRank << 16) | (trips1 << 12) | (trips2 << 8) | (pair1 << 4) | pair2;
    }

    function _evaluateByMult(uint16 rankMask, uint256 mult) private pure returns (uint256) {
        uint256 quadsRank = (mult >> 16) & 0xF;
        uint256 trips1 = (mult >> 12) & 0xF;
        uint256 trips2 = (mult >> 8) & 0xF;
        uint256 pair1 = (mult >> 4) & 0xF;
        uint256 pair2 = mult & 0xF;

        // Quads
        if (quadsRank != 0xF) {
            uint256 kicker = _highestExcluding(rankMask, quadsRank, type(uint256).max);
            return _encode(CLASS_QUADS, quadsRank, kicker, 0, 0, 0);
        }

        // Full house
        if (trips1 != 0xF && (trips2 != 0xF || pair1 != 0xF)) {
            uint256 pairForFull = (trips2 != 0xF && (pair1 == 0xF || trips2 > pair1)) ? trips2 : pair1;
            return _encode(CLASS_FULL_HOUSE, trips1, pairForFull, 0, 0, 0);
        }

        // Straight
        uint256 shiAll = _highestStraight(rankMask);
        if (shiAll != type(uint256).max) {
            return _encode(CLASS_STRAIGHT, shiAll, 0, 0, 0, 0);
        }

        // Trips
        if (trips1 != 0xF) {
            uint256 k1 = _highestExcluding(rankMask, trips1, type(uint256).max);
            uint256 k2 = _highestExcluding(rankMask, trips1, k1);
            return _encode(CLASS_TRIPS, trips1, k1, k2, 0, 0);
        }

        // Two pair
        if (pair1 != 0xF && pair2 != 0xF) {
            uint256 k1 = _highestExcluding(rankMask, pair1, pair2);
            return _encode(CLASS_TWO_PAIR, pair1, pair2, k1, 0, 0);
        }

        // One pair
        if (pair1 != 0xF) {
            uint256 k1 = _highestExcluding(rankMask, pair1, type(uint256).max);
            uint256 k2 = _highestExcluding(rankMask, pair1, k1);
            uint256 k3 = _highestExcludingMany(rankMask, pair1, k1, k2);
            return _encode(CLASS_PAIR, pair1, k1, k2, k3, 0);
        }

        // High card
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

    /// @dev Bit `shift` of a uint16, computed without triggering the "implicit uint256 shift on uint16"
    ///      compiler warning. Callers only ever pass shift in [0, 12].
    function _bit(uint256 shift) private pure returns (uint16) {
        return uint16(1) << uint16(shift);
    }

    /// @dev Given a 13-bit rank bitmask, return the top rank of the highest 5-in-a-row run, including
    ///      the wheel (A-2-3-4-5 which is ranks 12,0,1,2,3). Returns type(uint256).max if none.
    function _highestStraight(uint16 mask) private pure returns (uint256) {
        // Walk from the top (A=12). Check every window of 5 consecutive ranks.
        for (uint256 i = 12; i >= 4; i--) {
            uint16 window = _bit(i) | _bit(i - 1) | _bit(i - 2) | _bit(i - 3) | _bit(i - 4);
            if ((mask & window) == window) {
                return i;
            }
            if (i == 4) break; // guard against underflow
        }
        // Wheel: A (12), 2 (0), 3 (1), 4 (2), 5 (3)
        uint16 wheel = _bit(12) | _bit(0) | _bit(1) | _bit(2) | _bit(3);
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
            if ((mask & _bit(r)) != 0) {
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
            if ((mask & _bit(r)) != 0) return r;
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
            if ((mask & _bit(r)) != 0) return r;
        }
        return 0;
    }
}
