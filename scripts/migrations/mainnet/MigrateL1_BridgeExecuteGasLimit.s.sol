// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";

import {L1FluentBridge} from "../../../contracts/bridge/L1/L1FluentBridge.sol";
import {DeployBase} from "../../deploy/DeployBase.s.sol";

interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IBridgeExecuteGasLimitAdmin {
    function setExecuteGasLimit(uint256 newExecuteGasLimit) external;
}

/**
 * @title MigrateL1_BridgeExecuteGasLimit
 *
 * @notice Prepares the L1 mainnet bridge execute-gas-limit migration for multisig execution.
 *
 * @dev What this script does:
 *           1. Deploys a fresh {L1FluentBridge} implementation.
 *           2. Writes a Safe Transaction Builder JSON batch with:
 *                - `upgradeToAndCall(newImpl, "")`;
 *                - `setExecuteGasLimit(EXECUTE_GAS_LIMIT)`.
 *
 * @dev Both the UUPS upgrade hook ({_authorizeUpgrade}) and {setExecuteGasLimit} are gated
 *      by `DEFAULT_ADMIN_ROLE`. The Safe configured in this script MUST hold that role on
 *      the proxy. The broadcasting key only deploys the implementation and writes the batch.
 *
 * @dev What this script does NOT do:
 *        - Touches no other contract. Gateways, rollup, oracle, and factory are untouched.
 *        - Does not update `deployments/mainnet/l1.json`. The operator copies the logged
 *          new impl address into the manifest (`bridge_impl`) after Safe execution.
 *        - Does not run storage-layout compatibility checks. Verify layout compatibility with
 *          `forge inspect contracts/bridge/L1/L1FluentBridge.sol:L1FluentBridge storage-layout`
 *          before running on mainnet.
 *
 * @dev Environment:
 *        EXECUTE_GAS_LIMIT (optional) — new gas limit forwarded to message targets.
 *                                        Defaults to 200_000.
 *        SAFE_ADDRESS      (optional) — Safe/Timelock that holds DEFAULT_ADMIN_ROLE.
 *                                        Defaults to manifest `safe`, then `timelock`.
 *        SAFE_BATCH_PATH   (optional) — output JSON path. Defaults to
 *                                        deployments/mainnet/bridge-execute-gas-limit-safe-batch.json.
 *
 * @dev Usage (forge):
 *        source .env && forge script \
 *          scripts/migrations/mainnet/MigrateL1_BridgeExecuteGasLimit.s.sol:MigrateL1_BridgeExecuteGasLimit \
 *          --rpc-url "$MAINNET_RPC" --broadcast -vvvv
 */
contract MigrateL1_BridgeExecuteGasLimit is DeployBase {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @dev Manifest containing the deployed bridge proxy address.
    string internal constant L1_MANIFEST_PATH = "deployments/mainnet/l1.json";
    /// @dev Default Safe Transaction Builder output path.
    string internal constant DEFAULT_SAFE_BATCH_PATH = "deployments/mainnet/bridge-execute-gas-limit-safe-batch.json";

    /// @dev Default target for `_executeGasLimit` if `EXECUTE_GAS_LIMIT` env is unset.
    uint256 internal constant DEFAULT_NEW_EXECUTE_GAS_LIMIT = 200_000;

    function run() external {
        uint256 newLimit = vm.envOr("EXECUTE_GAS_LIMIT", DEFAULT_NEW_EXECUTE_GAS_LIMIT);
        require(newLimit > 0, "EXECUTE_GAS_LIMIT must be > 0");

        string memory manifest = vm.readFile(L1_MANIFEST_PATH);
        address payable bridgeProxy = payable(_readAddr(manifest, "bridge"));
        require(bridgeProxy != address(0), "bridge proxy missing in deployments/mainnet/l1.json");

        address safe = vm.envOr("SAFE_ADDRESS", address(0));
        if (safe == address(0)) safe = _readAddr(manifest, "safe");
        if (safe == address(0)) safe = _readAddr(manifest, "timelock");
        require(safe != address(0), "SAFE_ADDRESS/manifest safe missing");
        require(L1FluentBridge(bridgeProxy).hasRole(DEFAULT_ADMIN_ROLE, safe), "Safe lacks DEFAULT_ADMIN_ROLE");

        string memory safeBatchPath = vm.envOr("SAFE_BATCH_PATH", DEFAULT_SAFE_BATCH_PATH);
        uint256 currentLimit = L1FluentBridge(bridgeProxy).getExecuteGasLimit();

        _logPlan(bridgeProxy, safe, safeBatchPath, currentLimit, newLimit);

        vm.startBroadcast();

        // 1. Deploy fresh implementation. Constructor is only `_disableInitializers()`.
        address newImpl = address(new L1FluentBridge());
        console2.log("L1FluentBridge new impl:", newImpl);

        vm.stopBroadcast();

        SafeTransaction[] memory transactions = new SafeTransaction[](2);
        transactions[0] = SafeTransaction({
            to: bridgeProxy,
            value: 0,
            data: abi.encodeCall(IUUPSUpgradeable.upgradeToAndCall, (newImpl, "")),
            contractMethod: _upgradeToAndCallMethodJson(),
            contractInputsValues: _upgradeToAndCallInputsJson(newImpl)
        });
        transactions[1] = SafeTransaction({
            to: bridgeProxy,
            value: 0,
            data: abi.encodeCall(IBridgeExecuteGasLimitAdmin.setExecuteGasLimit, (newLimit)),
            contractMethod: _setExecuteGasLimitMethodJson(),
            contractInputsValues: _setExecuteGasLimitInputsJson(newLimit)
        });
        _writeSafeBatch(
            safeBatchPath,
            safe,
            "MigrateL1_BridgeExecuteGasLimit",
            "Upgrade L1 bridge implementation and update execute gas limit.",
            transactions
        );

        console2.log("");
        console2.log("== Migration prepared ==");
        console2.log("bridge proxy          :", bridgeProxy);
        console2.log("bridge impl (new)     :", newImpl);
        console2.log("executeGasLimit before:", currentLimit);
        console2.log("executeGasLimit new   :", newLimit);
        console2.log("safe batch            :", safeBatchPath);
        console2.log("");
        console2.log("After Safe execution, update deployments/mainnet/l1.json:");
        console2.log("  bridge_impl ->", newImpl);
    }

    function _logPlan(
        address bridgeProxy,
        address safe,
        string memory safeBatchPath,
        uint256 currentLimit,
        uint256 newLimit
    ) internal pure {
        console2.log("== MigrateL1_BridgeExecuteGasLimit ==");
        console2.log("bridge proxy         :", bridgeProxy);
        console2.log("Safe:                 ", safe);
        console2.log("Safe batch path:      ", safeBatchPath);
        console2.log("executeGasLimit (now):", currentLimit);
        console2.log("executeGasLimit (new):", newLimit);
        console2.log("");
    }

    function _upgradeToAndCallMethodJson() internal pure returns (string memory) {
        return string.concat(
            "{",
            '"inputs":[{"internalType":"address","name":"newImplementation","type":"address"},',
            '{"internalType":"bytes","name":"data","type":"bytes"}],',
            '"name":"upgradeToAndCall",',
            '"payable":true',
            "}"
        );
    }

    function _upgradeToAndCallInputsJson(address newImpl) internal pure returns (string memory) {
        return string.concat(
            "{",
            '"newImplementation":"',
            _addressToHex(newImpl),
            '",',
            '"data":"0x"',
            "}"
        );
    }

    function _setExecuteGasLimitMethodJson() internal pure returns (string memory) {
        return string.concat(
            "{",
            '"inputs":[{"internalType":"uint256","name":"newExecuteGasLimit","type":"uint256"}],',
            '"name":"setExecuteGasLimit",',
            '"payable":false',
            "}"
        );
    }

    function _setExecuteGasLimitInputsJson(uint256 newLimit) internal pure returns (string memory) {
        return string.concat("{", '"newExecuteGasLimit":"', _uintToString(newLimit), '"', "}");
    }
}
