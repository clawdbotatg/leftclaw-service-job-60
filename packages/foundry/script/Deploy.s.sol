//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";

/**
 * @notice Main deployment script for all contracts
 * @dev Run this when you want to deploy multiple contracts at once
 *
 * Example: yarn deploy # runs this script (without `--file` flag)
 *
 * Stage 2 note: ClawdPoker deployment is intentionally deferred to Stage 5.
 * It requires constructor args (Base mainnet VRF coordinator, subscription id,
 * key hash, CLAWD token address) that must come from environment config.
 * A dedicated DeployClawdPoker.s.sol will be added in Stage 5.
 */
contract DeployScript is ScaffoldETHDeploy {
    function run() external pure {
        // TODO(Stage 5): instantiate and run DeployClawdPoker once constructor args are wired.
        //
        // DeployClawdPoker deployClawdPoker = new DeployClawdPoker();
        // deployClawdPoker.run();
    }
}
