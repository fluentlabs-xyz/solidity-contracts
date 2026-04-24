// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {L1GasOracle} from "../../contracts/oracles/L1GasOracle.sol";

/// @notice Deploys `L1GasOracle` (plain contract, not upgradeable).
/// @dev Edit the constants below, then run:
///      `forge script scripts/deploy/DeployL1GasOracle.s.sol:DeployL1GasOracle --rpc-url $RPC_URL --broadcast`
contract DeployL1GasOracle is Script {
    // -------------------------------------------------------------------------
    // Edit these before broadcasting
    // -------------------------------------------------------------------------
    address internal constant SUBMITTER = 0x1C92DffBCe76670F69007F22A54e31ff3Ab45d5E;
    uint256 internal constant MIN_L1_GAS_PRICE = 0;
    uint256 internal constant MAX_L1_GAS_PRICE = 0;

    function _deployL1GasOracle(address submitter, uint256 minPrice, uint256 maxPrice) internal returns (address) {
        return address(new L1GasOracle(submitter, minPrice, maxPrice));
    }

    function run() external virtual {
        console2.log("Deploying L1GasOracle");
        console2.log("  submitter:", SUBMITTER);
        console2.log("  minPrice:", MIN_L1_GAS_PRICE);
        console2.log("  maxPrice:", MAX_L1_GAS_PRICE);

        vm.startBroadcast();
        address oracle = _deployL1GasOracle(SUBMITTER, MIN_L1_GAS_PRICE, MAX_L1_GAS_PRICE);
        vm.stopBroadcast();

        console2.log("L1GasOracle deployed:", oracle);
    }
}
