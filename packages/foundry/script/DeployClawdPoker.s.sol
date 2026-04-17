// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DeployHelpers.s.sol";
import { ClawdPoker } from "../contracts/ClawdPoker.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Deploys ClawdPoker to Base mainnet (chain 8453).
 *
 * VRF V2.5 parameters verified against
 *   https://docs.chain.link/vrf/v2-5/supported-networks
 * at deploy time (2026-04-16):
 *   - Base VRFCoordinator V2.5 : 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634
 *   - Base LINK                : 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196
 *   - Key hash (2 gwei lane)   : 0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab
 *   - Key hash (30 gwei lane)  : 0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70
 *
 * We pick the 2 gwei lane — Base mainnet gas prices sit well below that and
 * this minimizes VRF fulfillment cost. The higher lane is only needed on
 * congested L1s.
 *
 * Ownership handoff sequence (NOT performed by this script):
 *   1. Deploy (this script). Deployer stays owner.
 *   2. Deployer calls `addConsumer(subId, pokerAddr)` on the coordinator.
 *   3. Deployer calls `transferOwnership(client)` on the contract.
 *   4. Deployer calls `requestSubscriptionOwnerTransfer(subId, client)` on the coordinator.
 *   5. Client calls `acceptOwnership()` on ClawdPoker.
 *   6. Client calls `acceptSubscriptionOwnerTransfer(subId)` on the coordinator.
 *
 * We leave steps 2-4 as explicit off-script `cast send` operations so the
 * orchestrator can audit each tx receipt individually.
 */
contract DeployClawdPoker is ScaffoldETHDeploy {
    // Base mainnet — verified against Chainlink docs 2026-04-16
    address constant VRF_COORDINATOR = 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634;
    bytes32 constant KEY_HASH = 0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab; // 2 gwei lane
    address constant CLAWD_TOKEN = 0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07;

    function run() external ScaffoldEthDeployerRunner {
        uint256 subId = vm.envUint("VRF_SUBSCRIPTION_ID");
        require(subId != 0, "VRF_SUBSCRIPTION_ID not set");

        ClawdPoker poker = new ClawdPoker(VRF_COORDINATOR, subId, KEY_HASH, IERC20(CLAWD_TOKEN));

        // Record the deployment so SE2's exportDeployments picks it up and
        // generateTsAbis emits deployedContracts.ts for the frontend.
        deployments.push(Deployment({ name: "ClawdPoker", addr: address(poker) }));
    }
}
