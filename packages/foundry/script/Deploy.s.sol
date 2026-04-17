//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import { DeployClawdPoker } from "./DeployClawdPoker.s.sol";

/**
 * @notice Main deployment script.
 *
 * For Base mainnet deploy via SE2 wrapper:
 *   VRF_SUBSCRIPTION_ID=<subId> yarn deploy --file DeployClawdPoker.s.sol --network base
 *
 * Or raw forge script (ad-hoc deploy path used by Stage 5):
 *   cd packages/foundry
 *   set -a && source .env && set +a
 *   VRF_SUBSCRIPTION_ID=<subId> forge script script/DeployClawdPoker.s.sol \
 *       --rpc-url base --broadcast --private-key $PRIVATE_KEY --ffi
 *
 * Running `yarn deploy` with no --file falls back to this script, which in
 * turn delegates to DeployClawdPoker. Keep this shim so the SE2 convention
 * (yarn deploy with no args = "deploy everything") keeps working.
 */
contract DeployScript is ScaffoldETHDeploy {
    function run() external {
        DeployClawdPoker d = new DeployClawdPoker();
        d.run();
    }
}
