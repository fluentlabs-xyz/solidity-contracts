// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {L1FluentBridge} from "../../../contracts/bridge/L1/L1FluentBridge.sol";
import {DeployBase} from "../../deploy/DeployBase.s.sol";

/**
 * @title MigrateL1_BridgeExecuteGasLimit
 *
 * @notice One-shot L1 mainnet migration that:
 *           1. Deploys a fresh {L1FluentBridge} implementation.
 *           2. Upgrades the existing bridge proxy (from `deployments/mainnet/l1.json`
 *              under `bridge`) to the new implementation via the UUPS hook.
 *           3. Raises {FluentBridgeStorageLayout._executeGasLimit} to `EXECUTE_GAS_LIMIT`
 *              (default 200_000) by calling {setExecuteGasLimit}.
 *
 * @dev Both the UUPS upgrade hook ({_authorizeUpgrade}) and {setExecuteGasLimit} are gated
 *      by `DEFAULT_ADMIN_ROLE`. The broadcasting key MUST hold that role on the proxy,
 *      otherwise step 2 or step 3 will revert and roll the whole migration back.
 *
 * @dev What this script does NOT do:
 *        - Touches no other contract. Gateways, rollup, oracle, and factory are untouched.
 *        - Does not update `deployments/mainnet/l1.json`. The operator copies the logged
 *          new impl address into the manifest (`bridge_impl`) after the run.
 *        - Does not run any storage-layout compatibility check beyond what {UnsafeUpgrades}
 *          provides (which is "none"). Verify layout compatibility with
 *          `forge inspect contracts/bridge/L1/L1FluentBridge.sol:L1FluentBridge storage-layout`
 *          before running on mainnet.
 *
 * @dev Environment:
 *        EXECUTE_GAS_LIMIT (optional) — new gas limit forwarded to message targets.
 *                                        Defaults to 200_000.
 *
 * @dev Usage (forge):
 *        source .env && forge script \
 *          scripts/migrations/mainnet/MigrateL1_BridgeExecuteGasLimit.s.sol:MigrateL1_BridgeExecuteGasLimit \
 *          --rpc-url "$MAINNET_RPC" --broadcast -vvvv
 */
contract MigrateL1_BridgeExecuteGasLimit is DeployBase {
    /// @dev Manifest containing the deployed bridge proxy address.
    string internal constant L1_MANIFEST_PATH = "deployments/mainnet/l1.json";

    /// @dev Default target for `_executeGasLimit` if `EXECUTE_GAS_LIMIT` env is unset.
    uint256 internal constant DEFAULT_NEW_EXECUTE_GAS_LIMIT = 200_000;

    function run() external {
        uint256 newLimit = vm.envOr("EXECUTE_GAS_LIMIT", DEFAULT_NEW_EXECUTE_GAS_LIMIT);
        require(newLimit > 0, "EXECUTE_GAS_LIMIT must be > 0");

        string memory manifest = vm.readFile(L1_MANIFEST_PATH);
        address payable bridgeProxy = payable(_readAddr(manifest, "bridge"));
        require(bridgeProxy != address(0), "bridge proxy missing in deployments/mainnet/l1.json");

        uint256 currentLimit = L1FluentBridge(bridgeProxy).getExecuteGasLimit();

        _logPlan(bridgeProxy, currentLimit, newLimit);

        vm.startBroadcast();

        // 1. Deploy fresh implementation. Constructor is only `_disableInitializers()`.
        address newImpl = address(new L1FluentBridge());
        console2.log("L1FluentBridge new impl:", newImpl);

        // 2. Upgrade the proxy. Empty init-calldata — re-running initializers is not
        //    permitted on an already-initialized proxy, and there's nothing new to init.
        UnsafeUpgrades.upgradeProxy(bridgeProxy, newImpl, "");
        console2.log("bridge", bridgeProxy, "->", newImpl);

        // 3. Raise execute-gas-limit. Gated by DEFAULT_ADMIN_ROLE on the proxy.
        L1FluentBridge(bridgeProxy).setExecuteGasLimit(newLimit);

        vm.stopBroadcast();

        // Post-condition: read through the upgraded proxy to prove the setter landed.
        uint256 applied = L1FluentBridge(bridgeProxy).getExecuteGasLimit();
        require(applied == newLimit, "executeGasLimit did not apply");

        console2.log("");
        console2.log("== Migration complete ==");
        console2.log("bridge proxy          :", bridgeProxy);
        console2.log("bridge impl (new)     :", newImpl);
        console2.log("executeGasLimit before:", currentLimit);
        console2.log("executeGasLimit after :", applied);
        console2.log("");
        console2.log("Update deployments/mainnet/l1.json:");
        console2.log("  bridge_impl ->", newImpl);
    }

    function _logPlan(address bridgeProxy, uint256 currentLimit, uint256 newLimit) internal pure {
        console2.log("== MigrateL1_BridgeExecuteGasLimit ==");
        console2.log("bridge proxy         :", bridgeProxy);
        console2.log("executeGasLimit (now):", currentLimit);
        console2.log("executeGasLimit (new):", newLimit);
        console2.log("");
    }
}
