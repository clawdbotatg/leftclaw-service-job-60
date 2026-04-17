# ClawdPoker — Deployment & Operations Plan

This document captures the operational runbook for deploying `ClawdPoker` to
Base mainnet and handing it off to the client (`0x7E6Db18aea6b54109f4E5F34242d4A8786E0C471`).

It exists primarily to close Stage 3 audit finding **M-07** (VRF subscription
onboarding) and to give the client an unambiguous path to full control of the
contract across its two ownership surfaces:

1. **Contract ownership** — `ConfirmedOwner` (via `VRFConsumerBaseV2Plus`).
   Governs `commitDeck`, `dealCommunity`, and `transferOwnership` /
   `acceptOwnership`. Two-step transfer.
2. **VRF subscription ownership** — owned by whichever address called
   `VRFCoordinator.createSubscription`. Governs LINK funding and consumer
   list. Independent from contract ownership.

Both surfaces must end up controlled by the client.

---

## Stage 5 deployment runbook

### Prerequisites (client-side, done before deployer deploys)

1. Client creates a Chainlink VRF V2.5 subscription on Base:
   - Coordinator address on Base mainnet:
     `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634`
     (verify against https://docs.chain.link/vrf/v2-5/supported-networks)
   - Client calls `createSubscription()` on the coordinator from
     `0x7E6Db18aea6b54109f4E5F34242d4A8786E0C471`.
   - Coordinator returns a numeric `subscriptionId`. **Client communicates
     this `subscriptionId` to the deployer.**

2. Client funds the subscription with LINK:
   - Base LINK token: `0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196`
   - Client calls `LINK.transferAndCall(VRFCoordinator, amount, abi.encode(subId))`.
   - Recommended initial funding: at least 10 LINK (covers ~500 VRF requests
     at Base gas prices). Top up as usage grows.

### Deploy

1. Deployer sets `ALCHEMY_RPC_URL` pointing to Base mainnet (never a public
   RPC) in `.env`.
2. Deployer sets the Base V2.5 key hash in the deploy script. At time of
   writing the 30 gwei lane on Base mainnet is
   `0xdc2f87a5c8d3f9e6b1f83b9d3c3bc1f02f1c9f9b2b7d9a2e0e9e2c1a8e7e8d9c`
   (verify against https://docs.chain.link/vrf/v2-5/supported-networks before
   broadcasting).
3. Deploy with:
   - `vrfCoordinator` = Base coordinator address
   - `subId` = client's subscription id
   - `keyHash` = Base V2.5 key hash (above)
   - `clawdToken` = `0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07` (CLAWD on Base)
4. Deployer runs `yarn verify --network base` to verify on BaseScan. No
   BaseScan API key is required; SE2 handles verification natively.

### Client adds the contract as a VRF consumer

After `ClawdPoker` is deployed and verified:

- Client calls `VRFCoordinator.addConsumer(subscriptionId, clawdPokerAddress)`.
- This MUST be done from the subscription owner (i.e. the client wallet).

If this step is skipped, `joinGame` will revert inside
`s_vrfCoordinator.requestRandomWords(...)` with a consumer-not-registered
error, and games cannot progress out of `WAITING`.

### Contract ownership transfer (two-step)

1. Deployer (current contract `owner()`) calls `transferOwnership(clientAddr)`.
   `ConfirmedOwner` records a pending transfer. Contract state does NOT
   change yet — the deployer is still `owner()`.
2. Client calls `acceptOwnership()` from `0x7E6Db18aea6b54109f4E5F34242d4A8786E0C471`.
   Contract `owner()` now returns the client.
3. Deployer can `transferOwnership` their dealer role separately if the
   dealer is a different address; see "Dealer role" below.

### Dealer role

`commitDeck` and `dealCommunity` are `onlyOwner` — i.e. the contract owner
IS the dealer. If the client intends to run a bot wallet as dealer separate
from their cold wallet:

- Deploy with the deployer as owner.
- Deployer transfers ownership directly to the dealer bot wallet.
- Client retains sub-owner control (LINK / consumer) independently.

This means contract-ownership and VRF-sub-ownership can legitimately live
on different addresses: dealer bot owns the contract (to call commit/deal)
and client owns the sub (to fund and add consumers). Both arrangements work.

### Post-hand-off verification checklist

- `cast call $POKER "owner()(address)" --rpc-url $ALCHEMY_RPC_URL`
  returns the client (or the client-designated dealer) address.
- `cast call $VRF_COORDINATOR "getSubscription(uint256)(address,uint96,uint64,address[])" $SUB_ID --rpc-url $ALCHEMY_RPC_URL`
  returns the client as owner AND the ClawdPoker address in the consumer list.
- Sub has > 0 LINK balance.
- A test game created with tiny buyIn reaches `PREFLOP` phase (proving VRF
  + commitDeck work end-to-end).

---

## Operational notes

### Salt entropy (audit M-04)

Each of the 52 per-card commits is `keccak256(abi.encodePacked(salt, card))`
with `card in [0, 51]`. Salts MUST be generated with a CSPRNG and have >=128
bits of entropy. A dealer using low-entropy salts (counter, timestamp,
`keccak256(gameId, i)`, etc.) enables an observer to brute-force commits in
O(52 * 2^bits_of_salt) and learn hole cards before showdown.

Recommended dealer pattern:

```
salt_root = cryptoRandomBytes(32)   // 256 bits from a CSPRNG
salt_i    = keccak256(salt_root || i)
commit_i  = keccak256(salt_i || card_i)
```

Only `salt_root` needs to be protected between commit and reveal.

### Timeout behaviour summary

| Phase state                              | Who times out   | claimTimeout outcome        |
|------------------------------------------|-----------------|-----------------------------|
| `WAITING` (game not filled)              | N/A             | revert WrongPhase           |
| `DEALING` (VRF + commitDeck)             | Dealer          | revert WrongPhase (H-01 fix) |
| Betting round active (player owes action)| `currentBettor` | Non-bettor claims; currentBettor loses |
| Between streets (awaiting dealCommunity) | Dealer          | Refund both, no burn (M-06) |
| `SHOWDOWN`, one reveal in                | Non-revealer    | Revealer wins (H-02 fix)    |
| `SHOWDOWN`, neither revealed             | Both            | Refund both, no burn (H-02) |
| `COMPLETE`                               | N/A             | revert WrongPhase           |

### Burn mechanism (C-01 fix)

Settlement burns via `IClawdBurnable(CLAWD).burn(uint256)`, NOT via
`transfer(address(0), ...)`. Real CLAWD on Base reverts `ERC20InvalidReceiver`
on transfer-to-zero; the fix uses the canonical OZ `ERC20Burnable.burn`
entrypoint.
