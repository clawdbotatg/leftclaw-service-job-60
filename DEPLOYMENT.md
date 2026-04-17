# ClawdPoker — Base Mainnet Deployment

Stage 5 deployment log. All txs broadcast from the deployer
`0x5430757ee25f25D11987B206C1789d394a779200` to Base mainnet (chain 8453)
via Alchemy RPC. See `PLAN.md` for the operational runbook.

## Contract

| Field            | Value |
|------------------|-------|
| Contract         | `ClawdPoker` |
| Address          | `0x10cd417a4197153a90d88cb47F132f5bCD996535` |
| Chain            | Base mainnet (8453) |
| Basescan         | https://basescan.org/address/0x10cd417a4197153a90d88cb47f132f5bcd996535#code |
| Verification     | Passed (source verified on Basescan) |
| Compiler         | solc 0.8.20, optimizer on, runs=200, `via_ir=true` |
| Deploy tx        | `0xecb1d191c3beb5ecb5706ef1cecffaf10ea1edcf2154d0ea57beaafd120f8292` |
| Deploy gas used  | 2,816,098 |

## VRF v2.5

| Field            | Value |
|------------------|-------|
| Coordinator      | `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634` |
| LINK token       | `0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196` |
| Key hash         | `0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab` (2 gwei lane) |
| Subscription ID  | `88758036625967445277542971857840004152303626056035743996234076678281404054993` |
| Subscription UI  | https://vrf.chain.link/base/88758036625967445277542971857840004152303626056035743996234076678281404054993 |

All values verified against
<https://docs.chain.link/vrf/v2-5/supported-networks> on 2026-04-16.

### VRF subscription setup txs

| Action                          | Tx hash |
|---------------------------------|---------|
| `createSubscription()`          | `0x49278e1f767fef51fe4728d3f98728584785f73e4917014ad473a96bac276f2e` |
| `addConsumer(subId, poker)`     | `0x6aa75dc638724ebe6f7bc60cfbfc71f87263443939a66185acde968701025c67` |

Coordinator state after setup:
- Sub owner: `0x5430757ee25f25D11987B206C1789d394a779200` (deployer — pending transfer to client)
- Consumers: `[0x10cd417a4197153a90d88cb47F132f5bCD996535]`
- LINK / native balance: 0 (client must fund)

## Constructor arguments

| Position | Name            | Value |
|----------|-----------------|-------|
| 0        | vrfCoordinator  | `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634` |
| 1        | subId           | `88758036625967445277542971857840004152303626056035743996234076678281404054993` |
| 2        | keyHash         | `0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab` |
| 3        | clawdToken      | `0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07` |

ABI-encoded: `0x000000000000000000000000d5d517abe5cf79b7e95ec98db0f0277788aff634c43b44b9c280db67abcd4894c9e94efa265a95c296a8232dc6fca82ec3fb7dd100b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab0000000000000000000000009f86db9fc6f7c9408e8fda3ff8ce4e78ac7a6b07`

## Ownership

Two independent surfaces, both two-step transfers, both currently **pending
client acceptance**.

| Surface          | Current owner | Pending owner | Transfer tx |
|------------------|---------------|---------------|-------------|
| Contract         | deployer      | client        | `0xb5b618603af363c010adc5936f52142a59a8b8a5b04e0e619c7a1dc39cfbde22` |
| VRF subscription | deployer      | client        | `0x5dcd9502fb196b17c2a63937e0bc5f4cedaa1bf5662077efa5ef34589dca5dcc` |

Client (`0x7E6Db18aea6b54109f4E5F34242d4A8786E0C471`) must run both accept
calls to finalize ownership. Until then the deployer retains control.

### Client accept commands

Run from the client wallet (`0x7E6Db18aea6b54109f4E5F34242d4A8786E0C471`). Replace
`$CLIENT_PK` with your private key (or use a keystore / Ledger flow; whatever
wallet tool you prefer, the calldata is the same).

```bash
# Accept contract ownership
cast send 0x10cd417a4197153a90d88cb47F132f5bCD996535 \
  "acceptOwnership()" \
  --private-key $CLIENT_PK \
  --rpc-url $YOUR_BASE_RPC

# Accept VRF subscription ownership
cast send 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634 \
  "acceptSubscriptionOwnerTransfer(uint256)" \
  88758036625967445277542971857840004152303626056035743996234076678281404054993 \
  --private-key $CLIENT_PK \
  --rpc-url $YOUR_BASE_RPC
```

### Verifying after accept

```bash
# Should return the client address
cast call 0x10cd417a4197153a90d88cb47F132f5bCD996535 \
  "owner()(address)" \
  --rpc-url $YOUR_BASE_RPC

# getSubscription should return the client as subOwner (4th field) with
# [0x10cd417a4197153a90d88cb47F132f5bCD996535] as the consumer list
cast call 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634 \
  "getSubscription(uint256)(uint96,uint96,uint64,address,address[])" \
  88758036625967445277542971857840004152303626056035743996234076678281404054993 \
  --rpc-url $YOUR_BASE_RPC
```

## Fund the subscription (client action)

The subscription holds zero LINK. Every VRF request costs LINK; the contract
will revert inside `requestRandomWords` with an insufficient-balance error
until the sub is funded. Recommended initial funding: 10 LINK on Base.

```bash
# Base LINK token
LINK=0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196
SUB_ID=88758036625967445277542971857840004152303626056035743996234076678281404054993
VRF=0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634

# transferAndCall forwards the LINK to the coordinator with the subId encoded
cast send $LINK \
  "transferAndCall(address,uint256,bytes)" \
  $VRF \
  10000000000000000000 \
  $(cast abi-encode "f(uint256)" $SUB_ID) \
  --private-key $CLIENT_PK \
  --rpc-url $YOUR_BASE_RPC
```

Alternatively use the hosted UI at <https://vrf.chain.link/base>. Connect as
the client wallet (after accepting the sub transfer) and click "Fund".

## Gas accounting

| Tx                                   | Gas used |
|--------------------------------------|----------|
| createSubscription                   | ~110,334 |
| Deploy ClawdPoker                    | 2,816,098 |
| addConsumer                          | 95,278 |
| transferOwnership (contract)         | ~46,000 |
| requestSubscriptionOwnerTransfer     | 50,966 |

| Balance checkpoint                   | ETH |
|--------------------------------------|-----|
| Pre-deploy                           | 0.004854082756294928 |
| Post all txs                         | 0.004838144863419416 |
| **Total spent**                      | **~0.0000159 ETH** |

Well under the 0.003 ETH budget for Stage 5.

## Re-deploy checklist (for future stages that re-run deploy)

1. `VRF_SUBSCRIPTION_ID` env var set to the existing subId (don't create a
   second sub unless you intend to — old one stays on the coordinator).
2. `cd packages/foundry && source /path/to/.env && set -a && source .env && set +a`.
3. `VRF_SUBSCRIPTION_ID=<id> forge script script/DeployClawdPoker.s.sol
   --rpc-url base --broadcast --private-key $PRIVATE_KEY --ffi`.
4. `cast send $VRF "addConsumer(uint256,address)" $SUB_ID $NEW_POKER ...`.
5. `cast send $NEW_POKER "transferOwnership(address)" $CLIENT ...`.
6. Update `DEPLOYMENT.md` with the new tx hashes.
