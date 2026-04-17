// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFConsumerBaseV2Plus} from
    "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from
    "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PokerHandEvaluator} from "./PokerHandEvaluator.sol";

/// @dev Minimal interface for OZ `ERC20Burnable` used by the CLAWD token on Base.
///      CLAWD (0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07) is OZ v5, which reverts
///      `ERC20InvalidReceiver(address(0))` on any `transfer(address(0), ...)`. The
///      burn path must therefore call `burn(uint256)` directly rather than a
///      transfer-to-zero.
interface IClawdBurnable {
    function burn(uint256 amount) external;
}

/// @title ClawdPoker
/// @notice Heads-up Texas Hold'em poker, settled in CLAWD, randomness from Chainlink VRF v2.5.
/// @dev Design notes (material for Stage 3 auditors)
///
///   1. Ownership model. VRFConsumerBaseV2Plus already inherits Chainlink's
///      ConfirmedOwner (which exposes `owner()` and the `onlyOwner` modifier).
///      The job brief suggested also using OpenZeppelin Ownable(msg.sender),
///      which would clash. This contract therefore uses the ConfirmedOwner
///      surface inherited from VRF — `owner()`, `transferOwnership(newOwner)`,
///      and `acceptOwnership()` (two-step). Stage 5 will call transferOwnership
///      to the `job.client` and the client will call acceptOwnership().
///
///   2. Commit-reveal design. The job spec originally proposed that each card
///      reveal submit a `keccak256(deckHash, cardIndex, card)` proof. That
///      construction is cryptographically vacuous — a dealer can compute
///      a matching "proof" for any card after the deck hash is fixed. To
///      preserve the *intent* of the spec (trusted dealer, auditable commits,
///      progressive reveal) while actually binding the dealer to a deck, we use
///      per-card hiding commits:
///        deckHash        = keccak256(abi.encode(vrfResult));
///        cardCommits[i]  = keccak256(abi.encodePacked(salt_i, card_i));
///      The dealer calls `commitDeck` with all 52 commits pinned on-chain, then
///      each subsequent reveal submits `(card, salt)` checked against the
///      pinned commits. A global "card used" bitmask guarantees no duplicate
///      card values can be revealed across indices.
///      The dealer is still trusted to pick a valid 52-card permutation — there
///      is no on-chain way to prove that without revealing the entire deck. The
///      auditability guarantee is: all commits + the seed are public, so a bad
///      deck is detectable post-hoc.
///
///   3. All-in / showdown. Standard Hold'em rules would short-circuit to
///      showdown when a player moves all-in, dealing remaining streets
///      immediately. Because card reveals here require the dealer to post
///      (card, salt) pairs, we cannot advance phases without dealer input.
///      In the all-in case the game enters SHOWDOWN only after the dealer has
///      completed all four reveal calls (flop, turn, river, then hole reveals).
///      The dealer is expected to call `dealCommunity` back-to-back. This is a
///      known divergence from canonical Hold'em and is flagged for Stage 3.
///
///   4. Burn mechanism. CLAWD on Base is OZ v5 and exposes ERC20Burnable's
///      `burn(uint256)` — but reverts `ERC20InvalidReceiver(0)` on any
///      `transfer(address(0), ...)`. The burn path calls `burn(uint256)`
///      directly via `IClawdBurnable`. (Fixed C-01, Stage 4.)
///
///   5. Tie splitting. On evaluator-tie showdowns the pot is split 50/50 AFTER
///      the 15% burn. Wins and streaks do NOT increment for either player; the
///      losing-streak reset likewise does not trigger. This is documented below
///      in `_settleSplit` — it is a conscious choice since neither player
///      "won" the hand.
contract ClawdPoker is VRFConsumerBaseV2Plus {
    // ---------------------------------------------------------------------
    //                              Constants
    // ---------------------------------------------------------------------

    uint32 public constant CALLBACK_GAS_LIMIT = 200_000;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    uint256 public constant TIMEOUT_SECONDS = 24 hours;
    uint256 public constant BURN_BPS = 1_500; // 15%
    uint256 private constant BPS_DENOM = 10_000;

    // ---------------------------------------------------------------------
    //                              Types
    // ---------------------------------------------------------------------

    enum Phase {
        WAITING,
        DEALING,
        PREFLOP,
        FLOP,
        TURN,
        RIVER,
        SHOWDOWN,
        COMPLETE
    }

    struct Game {
        uint256 gameId;
        address playerA;
        address playerB;
        uint256 buyIn;
        uint256 stackA;
        uint256 stackB;
        uint256 pot;
        bytes32 deckHash;
        uint8[5] communityCards;
        bool[2] handRevealed;
        uint8[2] holeCardsA;
        uint8[2] holeCardsB;
        Phase phase;
        address currentBettor;
        uint256 currentBet;
        uint256 lastActionTime;
        address winner;
    }

    // ---------------------------------------------------------------------
    //                              Errors
    // ---------------------------------------------------------------------

    error BuyInTooLarge();
    error ZeroBuyIn();
    error GameNotFound();
    error WrongPhase();
    error NotYourTurn();
    error NotParticipant();
    error InvalidAction();
    error InvalidRaise();
    error InsufficientStack();
    error AlreadyJoined();
    error CannotJoinOwnGame();
    error TokenTransferFailed();
    error DeckAlreadyCommitted();
    error DeckNotReady();
    error CommitMismatch();
    error IndexAlreadyRevealed();
    error CardAlreadyUsed();
    error TimeoutNotReached();
    error BadCommunityCount();
    error BadRevealIndex();

    // ---------------------------------------------------------------------
    //                              Events
    // ---------------------------------------------------------------------

    event GameCreated(uint256 indexed gameId, address indexed playerA, uint256 buyIn);
    event GameJoined(uint256 indexed gameId, address indexed playerB);
    event VrfRequested(uint256 indexed gameId, uint256 requestId);
    event VrfFulfilled(uint256 indexed gameId, uint256 seed);
    event DeckCommitted(uint256 indexed gameId, bytes32 deckHash);
    event Action(uint256 indexed gameId, address indexed actor, uint8 action, uint256 amount);
    event PhaseAdvanced(uint256 indexed gameId, Phase newPhase);
    event CommunityDealt(uint256 indexed gameId, uint8[] cards, Phase phase);
    event HandRevealed(uint256 indexed gameId, address indexed player, uint8 card1, uint8 card2);
    event TimeoutClaimed(uint256 indexed gameId, address indexed claimant);
    event GameComplete(uint256 indexed gameId, address indexed winner, uint256 payout, uint256 burn);
    event GameSplit(uint256 indexed gameId, uint256 perPlayer, uint256 burn);

    // ---------------------------------------------------------------------
    //                              Storage
    // ---------------------------------------------------------------------

    IERC20 public immutable CLAWD;
    uint256 public immutable SUBSCRIPTION_ID;
    bytes32 public immutable KEY_HASH;

    uint256 public nextGameId;
    uint256[] public gameIds;

    mapping(address => uint256) public reputation; // total wins
    mapping(address => uint256) public streak; // current consecutive wins

    mapping(uint256 => Game) public games;
    mapping(uint256 => uint256) public vrfRequestToGame; // requestId -> gameId

    // Commit-reveal
    mapping(uint256 => bytes32[52]) public cardCommits; // per-game 52 commits
    mapping(uint256 => uint256) private _indexRevealedMask; // bit i set if deck index i revealed
    mapping(uint256 => uint256) private _cardUsedMask; // bit c set if card value c already revealed
    mapping(uint256 => uint256) private _vrfResult; // raw VRF seed per game (public via event)

    // Street bookkeeping
    mapping(uint256 => bool) private _awaitingLastAct; // true if one player has already checked this street

    /// @dev Chips each player has committed to the pot on the current street
    ///      (reset in `_advanceStreet` on every street transition). Used by
    ///      `_call` and `_raise` so the chips moved on each action equal the
    ///      delta between the current bet level and what this player has
    ///      already paid this round. Enables partial-call all-in: a
    ///      short-stacked caller pays `min(stack, currentBet - committed)`.
    mapping(uint256 => mapping(address => uint256)) private _committedThisRound;

    // ---------------------------------------------------------------------
    //                             Constructor
    // ---------------------------------------------------------------------

    /// @param vrfCoordinator Chainlink VRF v2.5 coordinator
    /// @param subId          VRF subscription id (must already include this contract as consumer)
    /// @param keyHash        VRF key hash / lane for the target chain
    /// @param clawdToken     CLAWD ERC-20 token address
    constructor(address vrfCoordinator, uint256 subId, bytes32 keyHash, IERC20 clawdToken)
        VRFConsumerBaseV2Plus(vrfCoordinator)
    {
        SUBSCRIPTION_ID = subId;
        KEY_HASH = keyHash;
        CLAWD = clawdToken;
    }

    // ---------------------------------------------------------------------
    //                         Streak gate helper
    // ---------------------------------------------------------------------

    /// @dev Enforce the per-streak buy-in caps.
    function _checkStreakGate(address player, uint256 buyIn) internal view {
        uint256 s = streak[player];
        uint256 cap;
        if (s <= 2) cap = 10_000_000e18;
        else if (s <= 5) cap = 50_000_000e18;
        else if (s <= 9) cap = 200_000_000e18;
        else return; // 10+ streak: unlimited
        if (buyIn > cap) revert BuyInTooLarge();
    }

    // ---------------------------------------------------------------------
    //                           Game lifecycle
    // ---------------------------------------------------------------------

    function createGame(uint256 buyIn) external returns (uint256 gameId) {
        if (buyIn == 0) revert ZeroBuyIn();
        _checkStreakGate(msg.sender, buyIn);

        gameId = nextGameId++;
        gameIds.push(gameId);

        Game storage g = games[gameId];
        g.gameId = gameId;
        g.playerA = msg.sender;
        g.buyIn = buyIn;
        g.stackA = buyIn;
        g.phase = Phase.WAITING;
        g.lastActionTime = block.timestamp;

        _pullClawd(msg.sender, buyIn);
        emit GameCreated(gameId, msg.sender, buyIn);
    }

    function joinGame(uint256 gameId) external {
        Game storage g = games[gameId];
        if (g.playerA == address(0)) revert GameNotFound();
        if (g.phase != Phase.WAITING) revert WrongPhase();
        if (msg.sender == g.playerA) revert CannotJoinOwnGame();
        if (g.playerB != address(0)) revert AlreadyJoined();

        _checkStreakGate(msg.sender, g.buyIn);

        g.playerB = msg.sender;
        g.stackB = g.buyIn;
        g.phase = Phase.DEALING;
        g.lastActionTime = block.timestamp;

        _pullClawd(msg.sender, g.buyIn);

        // Request one random word.
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: KEY_HASH,
                subId: SUBSCRIPTION_ID,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: CALLBACK_GAS_LIMIT,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );
        vrfRequestToGame[requestId] = gameId;

        emit GameJoined(gameId, msg.sender);
        emit VrfRequested(gameId, requestId);
    }

    /// @dev VRF callback: pin the deck hash and emit the seed for the dealer. Phase stays DEALING
    ///      until the dealer calls commitDeck.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint256 gameId = vrfRequestToGame[requestId];
        Game storage g = games[gameId];
        // If phase isn't DEALING something is very wrong, but we can't revert inside the VRF callback
        // safely without triggering the mock's failure path. Just no-op in that case.
        if (g.phase != Phase.DEALING) return;
        uint256 seed = randomWords[0];
        _vrfResult[gameId] = seed;
        g.deckHash = keccak256(abi.encode(seed));
        emit VrfFulfilled(gameId, seed);
    }

    /// @notice Owner (dealer) pins the 52 per-card hiding commits for the game.
    ///         Each commit MUST equal keccak256(abi.encodePacked(salt_i, card_i)) where card_i is
    ///         a unique value in [0,51].
    function commitDeck(uint256 gameId, bytes32[52] calldata commits) external onlyOwner {
        Game storage g = games[gameId];
        if (g.phase != Phase.DEALING) revert WrongPhase();
        if (g.deckHash == bytes32(0)) revert DeckNotReady();
        if (cardCommits[gameId][0] != bytes32(0)) revert DeckAlreadyCommitted();

        for (uint256 i = 0; i < 52; i++) {
            cardCommits[gameId][i] = commits[i];
        }
        g.phase = Phase.PREFLOP;
        g.currentBettor = g.playerB; // heads-up: dealer (A) is small blind; B acts first preflop per spec
        g.lastActionTime = block.timestamp;

        emit DeckCommitted(gameId, g.deckHash);
        emit PhaseAdvanced(gameId, Phase.PREFLOP);
    }

    // ---------------------------------------------------------------------
    //                          Betting actions
    // ---------------------------------------------------------------------

    /// @dev action: 0=fold, 1=check, 2=call, 3=raise. `amount` is the NEW total bet size for raise.
    function act(uint256 gameId, uint8 action, uint256 amount) external {
        Game storage g = games[gameId];
        if (g.playerA == address(0)) revert GameNotFound();
        if (msg.sender != g.currentBettor) revert NotYourTurn();
        if (
            g.phase != Phase.PREFLOP && g.phase != Phase.FLOP && g.phase != Phase.TURN
                && g.phase != Phase.RIVER
        ) revert WrongPhase();

        if (action == 0) {
            _fold(g, gameId, msg.sender);
            return;
        } else if (action == 1) {
            _check(g, gameId);
        } else if (action == 2) {
            _call(g, gameId);
        } else if (action == 3) {
            _raise(g, gameId, amount);
        } else {
            revert InvalidAction();
        }

        g.lastActionTime = block.timestamp;
        emit Action(gameId, msg.sender, action, amount);
    }

    function _fold(Game storage g, uint256 gameId, address folder) internal {
        // lastActionTime refresh + event emission happen here since this branch returns.
        g.lastActionTime = block.timestamp;
        emit Action(gameId, folder, 0, 0);
        _settle(g, gameId, folder);
    }

    function _check(Game storage g, uint256 gameId) internal {
        if (g.currentBet != 0) revert InvalidAction();
        if (_awaitingLastAct[gameId]) {
            // both players have now checked: close the street.
            _awaitingLastAct[gameId] = false;
            _advanceStreet(g, gameId);
        } else {
            _awaitingLastAct[gameId] = true;
            _flipBettor(g);
        }
    }

    function _call(Game storage g, uint256 gameId) internal {
        if (g.currentBet == 0) revert InvalidAction();
        // Pay only the delta: currentBet minus what this player already
        // committed this round. If the caller's stack is smaller than that
        // delta, they go all-in for their remaining stack and the action
        // still closes the street (H-03: partial-call all-in).
        uint256 owed = g.currentBet - _committedThisRound[gameId][msg.sender];
        uint256 stack = _stackOf(g, msg.sender);
        uint256 pay = stack < owed ? stack : owed;
        _moveToPot(g, msg.sender, pay);
        _committedThisRound[gameId][msg.sender] += pay;
        // A call closes the street whether full-call or short-call all-in.
        g.currentBet = 0;
        _awaitingLastAct[gameId] = false;
        _advanceStreet(g, gameId);
    }

    function _raise(Game storage g, uint256 gameId, uint256 amount) internal {
        if (amount <= g.currentBet) revert InvalidRaise();
        // Raiser pays only the delta between the new bet level and whatever
        // they already put in this round.
        uint256 owed = amount - _committedThisRound[gameId][msg.sender];
        uint256 stack = _stackOf(g, msg.sender);
        if (stack < owed) revert InsufficientStack();
        _moveToPot(g, msg.sender, owed);
        _committedThisRound[gameId][msg.sender] += owed;
        g.currentBet = amount;
        _awaitingLastAct[gameId] = false;
        _flipBettor(g);
    }

    function _moveToPot(Game storage g, address who, uint256 amt) internal {
        if (who == g.playerA) {
            if (g.stackA < amt) revert InsufficientStack();
            g.stackA -= amt;
        } else {
            if (g.stackB < amt) revert InsufficientStack();
            g.stackB -= amt;
        }
        g.pot += amt;
    }

    function _stackOf(Game storage g, address who) internal view returns (uint256) {
        return who == g.playerA ? g.stackA : g.stackB;
    }

    function _flipBettor(Game storage g) internal {
        g.currentBettor = (g.currentBettor == g.playerA) ? g.playerB : g.playerA;
    }

    function _advanceStreet(Game storage g, uint256 gameId) internal {
        // Phase transitions after a closed street:
        //   PREFLOP -> wait for dealer to deal flop (phase advanced on dealCommunity)
        //   FLOP    -> wait for dealer to deal turn
        //   TURN    -> wait for dealer to deal river
        //   RIVER   -> go straight to SHOWDOWN
        // We only actually transition to SHOWDOWN here (after river).
        if (g.phase == Phase.RIVER) {
            g.phase = Phase.SHOWDOWN;
            // Defuse H-02: currentBettor has no meaning in SHOWDOWN and must not
            // be consulted as the timeout loser.
            g.currentBettor = address(0);
            emit PhaseAdvanced(gameId, Phase.SHOWDOWN);
            return;
        }
        // Otherwise we're mid-hand: the dealer must post community cards next.
        // Reset currentBet and seed first-actor-of-next-street per canonical
        // heads-up Hold'em (M-02 fix):
        //   - Pre-flop: BB (playerB) acts first.
        //   - Post-flop (flop/turn/river): BB (playerB) still acts first.
        // i.e., the BB acts first on every street in heads-up. The ternary below
        // collapses to "always playerB", but is written explicitly to document
        // intent and to give a stable hook if positional rules ever diverge.
        g.currentBet = 0;
        g.currentBettor = g.playerB;
        // Reset per-round commitments used by the partial-call-all-in logic.
        _committedThisRound[gameId][g.playerA] = 0;
        _committedThisRound[gameId][g.playerB] = 0;
    }

    // ---------------------------------------------------------------------
    //                      Community / hole reveals
    // ---------------------------------------------------------------------

    /// @notice Owner (dealer) reveals community cards for the current street.
    /// @dev Expected card counts: 3 (flop) when phase == PREFLOP,
    ///      1 (turn) when phase == FLOP,
    ///      1 (river) when phase == TURN.
    function dealCommunity(
        uint256 gameId,
        uint8[] calldata cards,
        bytes32[] calldata salts,
        uint8[] calldata deckIndices
    ) external onlyOwner {
        Game storage g = games[gameId];
        if (g.playerA == address(0)) revert GameNotFound();
        (uint256 expected, Phase next, uint256 writeStart) = _streetSpec(g.phase);
        if (cards.length != expected || salts.length != expected || deckIndices.length != expected) {
            revert BadCommunityCount();
        }

        for (uint256 i = 0; i < expected; i++) {
            // M-01: deck indices 4..7 are reserved for hole cards
            //   playerA = 4, 5   playerB = 6, 7
            // Reject the dealer claiming a reserved index for community so a
            // malicious / buggy dealer cannot lock a player out of revealHand.
            uint8 idx = deckIndices[i];
            if (idx == 4 || idx == 5 || idx == 6 || idx == 7) revert BadRevealIndex();
            _verifyAndMarkReveal(gameId, idx, cards[i], salts[i]);
            g.communityCards[writeStart + i] = cards[i];
        }

        g.phase = next;
        g.lastActionTime = block.timestamp;
        emit CommunityDealt(gameId, cards, next);
        emit PhaseAdvanced(gameId, next);
    }

    function _streetSpec(Phase p) private pure returns (uint256 expected, Phase next, uint256 writeStart) {
        if (p == Phase.PREFLOP) return (3, Phase.FLOP, 0);
        if (p == Phase.FLOP) return (1, Phase.TURN, 3);
        if (p == Phase.TURN) return (1, Phase.RIVER, 4);
        revert WrongPhase();
    }

    /// @notice A player reveals both of their hole cards at showdown.
    ///         Conventions: playerA uses deck indices (4, 5); playerB uses (6, 7).
    ///         (Indices 0..3 would correspond to the initial heads-up hole deal in a canonical
    ///          52-card deal, but we reserve 0..4 for community writes; so for absolute
    ///          clarity playerA = 4,5 and playerB = 6,7.)
    ///
    /// @dev The spec said playerA = 0,1 and playerB = 2,3 but those indices overlap the
    ///      community-card writeStart positions. We therefore use 4,5 / 6,7. This is a
    ///      minor deviation from the brief flagged for Stage 3.
    function revealHand(uint256 gameId, uint8 card1, uint8 card2, bytes32 salt1, bytes32 salt2)
        external
    {
        Game storage g = games[gameId];
        if (g.playerA == address(0)) revert GameNotFound();
        if (g.phase != Phase.SHOWDOWN) revert WrongPhase();
        if (msg.sender != g.playerA && msg.sender != g.playerB) revert NotParticipant();
        if (card1 >= 52 || card2 >= 52 || card1 == card2) revert BadRevealIndex();

        bool isA = (msg.sender == g.playerA);
        uint8 idx1 = isA ? 4 : 6;
        uint8 idx2 = isA ? 5 : 7;
        uint8 playerSlot = isA ? 0 : 1;

        if (g.handRevealed[playerSlot]) revert IndexAlreadyRevealed();

        _verifyAndMarkReveal(gameId, idx1, card1, salt1);
        _verifyAndMarkReveal(gameId, idx2, card2, salt2);

        if (isA) {
            g.holeCardsA[0] = card1;
            g.holeCardsA[1] = card2;
        } else {
            g.holeCardsB[0] = card1;
            g.holeCardsB[1] = card2;
        }
        g.handRevealed[playerSlot] = true;

        emit HandRevealed(gameId, msg.sender, card1, card2);

        if (g.handRevealed[0] && g.handRevealed[1]) {
            _scoreShowdown(g, gameId);
        }
    }

    /// @dev Verify a single (index, card, salt) reveal against the pinned commit and update masks.
    function _verifyAndMarkReveal(uint256 gameId, uint8 idx, uint8 card, bytes32 salt) internal {
        if (idx >= 52 || card >= 52) revert BadRevealIndex();
        uint256 revealedMask = _indexRevealedMask[gameId];
        uint256 usedMask = _cardUsedMask[gameId];
        uint256 idxBit = uint256(1) << idx;
        uint256 cardBit = uint256(1) << card;
        if ((revealedMask & idxBit) != 0) revert IndexAlreadyRevealed();
        if ((usedMask & cardBit) != 0) revert CardAlreadyUsed();
        if (cardCommits[gameId][idx] != keccak256(abi.encodePacked(salt, card))) revert CommitMismatch();
        _indexRevealedMask[gameId] = revealedMask | idxBit;
        _cardUsedMask[gameId] = usedMask | cardBit;
    }

    function _scoreShowdown(Game storage g, uint256 gameId) internal {
        uint8[7] memory aCards = [
            g.holeCardsA[0],
            g.holeCardsA[1],
            g.communityCards[0],
            g.communityCards[1],
            g.communityCards[2],
            g.communityCards[3],
            g.communityCards[4]
        ];
        uint8[7] memory bCards = [
            g.holeCardsB[0],
            g.holeCardsB[1],
            g.communityCards[0],
            g.communityCards[1],
            g.communityCards[2],
            g.communityCards[3],
            g.communityCards[4]
        ];
        uint256 rankA = PokerHandEvaluator.evaluate(aCards);
        uint256 rankB = PokerHandEvaluator.evaluate(bCards);

        if (rankA > rankB) {
            _settle(g, gameId, g.playerB); // B lost
        } else if (rankB > rankA) {
            _settle(g, gameId, g.playerA); // A lost
        } else {
            _settleSplit(g, gameId);
        }
    }

    // ---------------------------------------------------------------------
    //                              Timeout
    // ---------------------------------------------------------------------

    function claimTimeout(uint256 gameId) external {
        Game storage g = games[gameId];
        if (g.playerA == address(0)) revert GameNotFound();
        if (msg.sender != g.playerA && msg.sender != g.playerB) revert NotParticipant();
        // Terminal phases and WAITING (game not yet joined) have no timeout semantics.
        // DEALING is the dealer's responsibility (VRF + commitDeck) — disallow player
        // timeouts there so a dealer stall cannot be weaponized into a fixed-winner
        // path (H-01). A future `rescueStalledDeal` can refund both buy-ins after a
        // longer grace period; out of scope for this stage.
        if (
            g.phase == Phase.COMPLETE || g.phase == Phase.WAITING
                || g.phase == Phase.DEALING
        ) revert WrongPhase();
        if (block.timestamp <= g.lastActionTime + TIMEOUT_SECONDS) revert TimeoutNotReached();

        address loser;
        if (g.phase == Phase.SHOWDOWN) {
            // H-02: use `handRevealed`, not `currentBettor`, to determine the
            // stalling party at showdown.
            bool aRevealed = g.handRevealed[0];
            bool bRevealed = g.handRevealed[1];
            if (aRevealed && !bRevealed) {
                loser = g.playerB;
            } else if (bRevealed && !aRevealed) {
                loser = g.playerA;
            } else {
                // Neither (or both — impossible since double-reveal auto-settles)
                // has revealed. Refund both buy-ins with no winner declared.
                emit TimeoutClaimed(gameId, msg.sender);
                _refundBoth(g, gameId);
                return;
            }
            if (msg.sender == loser) revert InvalidAction();
        } else {
            // Betting phases (PREFLOP/FLOP/TURN/RIVER): currentBettor is the
            // player who owes an action. Non-currentBettor may claim.
            if (msg.sender == g.currentBettor) revert InvalidAction();
            loser = g.currentBettor;
        }
        emit TimeoutClaimed(gameId, msg.sender);
        _settle(g, gameId, loser);
    }

    // ---------------------------------------------------------------------
    //                              Settlement
    // ---------------------------------------------------------------------

    function _settle(Game storage g, uint256 gameId, address loser) internal {
        // Caller must have already validated that loser is one of the two players.
        // Pull any chips still sitting in player stacks into the pot so the winner is paid
        // the full on-contract balance attributable to this hand. This is required because
        // stacks only move into `pot` during betting; a preflop fold leaves both buy-ins in
        // their respective stacks.
        uint256 total = g.pot + g.stackA + g.stackB;
        g.stackA = 0;
        g.stackB = 0;

        address winner = (loser == g.playerA) ? g.playerB : g.playerA;
        uint256 burn = (total * BURN_BPS) / BPS_DENOM;
        uint256 payout = total - burn;

        g.pot = 0;
        g.phase = Phase.COMPLETE;
        g.winner = winner;

        reputation[winner] += 1;
        streak[winner] += 1;
        streak[loser] = 0;

        if (burn > 0) {
            // CLAWD is OZ ERC20Burnable; call burn() directly (C-01 fix).
            _burnClawd(burn);
        }
        _pushClawd(winner, payout);

        emit GameComplete(gameId, winner, payout, burn);
    }

    function _settleSplit(Game storage g, uint256 gameId) internal {
        uint256 total = g.pot + g.stackA + g.stackB;
        g.stackA = 0;
        g.stackB = 0;

        uint256 burn = (total * BURN_BPS) / BPS_DENOM;
        uint256 each = (total - burn) / 2;
        // If (total-burn) is odd, the odd wei stays in the contract. Acceptable (effectively extra burn).
        g.pot = 0;
        g.phase = Phase.COMPLETE;
        // No winner field set; no reputation/streak mutations on a tie.

        if (burn > 0) {
            _burnClawd(burn);
        }
        _pushClawd(g.playerA, each);
        _pushClawd(g.playerB, each);

        emit GameSplit(gameId, each, burn);
    }

    /// @dev Refund both players the full on-contract balance attributable to
    ///      this hand with no burn and no winner. Used when the SHOWDOWN times
    ///      out and neither player has revealed — the protocol cannot determine
    ///      a winner from hands alone, so punishing anyone is wrong. Reputation
    ///      and streak are unchanged (no "win" happened for either side).
    function _refundBoth(Game storage g, uint256 gameId) internal {
        uint256 total = g.pot + g.stackA + g.stackB;
        uint256 halfA = total / 2;
        uint256 halfB = total - halfA; // remainder (if total is odd) goes to playerB
        g.stackA = 0;
        g.stackB = 0;
        g.pot = 0;
        g.phase = Phase.COMPLETE;
        // No winner, no reputation / streak mutation.
        _pushClawd(g.playerA, halfA);
        _pushClawd(g.playerB, halfB);
        emit GameSplit(gameId, halfA, 0);
    }

    // ---------------------------------------------------------------------
    //                            Views
    // ---------------------------------------------------------------------

    function getGame(uint256 gameId) external view returns (Game memory) {
        return games[gameId];
    }

    function getReputation(address player) external view returns (uint256 wins, uint256 currentStreak) {
        return (reputation[player], streak[player]);
    }

    function openGames() external view returns (uint256[] memory) {
        uint256 n = gameIds.length;
        uint256 count;
        for (uint256 i = 0; i < n; i++) {
            if (games[gameIds[i]].phase == Phase.WAITING) count++;
        }
        uint256[] memory out = new uint256[](count);
        uint256 j;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = gameIds[i];
            if (games[id].phase == Phase.WAITING) {
                out[j++] = id;
            }
        }
        return out;
    }

    function getVrfResult(uint256 gameId) external view returns (uint256) {
        return _vrfResult[gameId];
    }

    // ---------------------------------------------------------------------
    //                         Token plumbing
    // ---------------------------------------------------------------------

    function _pullClawd(address from, uint256 amt) internal {
        bool ok = CLAWD.transferFrom(from, address(this), amt);
        if (!ok) revert TokenTransferFailed();
    }

    function _pushClawd(address to, uint256 amt) internal {
        bool ok = CLAWD.transfer(to, amt);
        if (!ok) revert TokenTransferFailed();
    }

    /// @dev Burn `amt` CLAWD held by this contract via ERC20Burnable.burn(uint256).
    ///      Real CLAWD (OZ v5) reverts on transfer-to-zero, so we call `burn()`
    ///      directly. The contract's balance must be >= amt; satisfied by pot
    ///      accounting since every call site burns less than the pot total.
    function _burnClawd(uint256 amt) internal {
        IClawdBurnable(address(CLAWD)).burn(amt);
    }
}
