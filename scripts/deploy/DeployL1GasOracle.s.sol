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

    /// @dev Hot key allowed to call `updateL1GasPrice` (must be non-zero). Replace for your chain.
    address internal constant SUBMITTER = 0x1C92DffBCe76670F69007F22A54e31ff3Ab45d5E;

    /// @dev Commitment window in seconds (`1` .. `type(uint32).max`).
    uint256 internal constant GAS_PRICE_WINDOW_SECONDS = 30;

    // -------------------------------------------------------------------------

    /// @notice Deploys a new `L1GasOracle` with the given submitter and window length.
    /// @param submitter Address authorized to call `updateL1GasPrice` (must not be zero).
    /// @param gasPriceWindowSeconds Commitment window in seconds (`1` .. `type(uint32).max`).
    /// @return oracle The deployed oracle address.
    function _deployL1GasOracle(address submitter, uint256 gasPriceWindowSeconds) internal returns (address oracle) {
        require(submitter != address(0), "SUBMITTER required");
        oracle = address(new L1GasOracle(submitter, gasPriceWindowSeconds));
    }

    function run() external virtual {
        console2.log("Deploying L1GasOracle");
        console2.log("  submitter:", SUBMITTER);
        console2.log("  gasPriceWindowSeconds:", GAS_PRICE_WINDOW_SECONDS);

        vm.startBroadcast();
        address oracle = _deployL1GasOracle(SUBMITTER, GAS_PRICE_WINDOW_SECONDS);
        vm.stopBroadcast();

        console2.log("L1GasOracle deployed:", oracle);
    }
}
