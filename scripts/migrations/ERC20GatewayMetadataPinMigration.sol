// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "../../lib/forge-std/src/console2.sol";

import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {DeployBase} from "../deploy/DeployBase.s.sol";

/// @notice Shared logic: UUPS-upgrade {ERC20Gateway} to the build pinned in this repo.
///
/// @dev Adds `_pinnedMetadataForOrigin` (ERC-7201 `ERC20GatewayStorage`) so CREATE2 / bridge
///      metadata stays stable if an origin token's `name` / `symbol` / `decimals` change later.
///      No post-upgrade setter calls are required — pins populate lazily on first send/receive.
///
/// @dev Storage: the new mapping is appended before a shortened `__gap`; existing `__gap` slots
///      must remain zero (standard OZ pattern). Validate layout off-chain before mainnet broadcast.
abstract contract ERC20GatewayMetadataPinMigration is DeployBase {
    /// @param env Manifest directory name, e.g. `testnet` or `mainnet` under `deployments/<env>/`.
    /// @param isL1 When true, reads `l1.json`; otherwise `l2.json`.
    function _erc20GatewayProxy(string memory env, bool isL1) internal view returns (address payable) {
        string memory path = string.concat("deployments/", env, isL1 ? "/l1.json" : "/l2.json");
        string memory json = vm.readFile(path);
        address proxy = _readAddr(json, "erc20_gateway");
        require(proxy != address(0), string.concat("erc20_gateway missing in ", path));
        return payable(proxy);
    }

    function _upgradeErc20Gateway(address payable proxy) internal {
        require(proxy.code.length > 0, "ERC20Gateway proxy has no code");

        vm.startBroadcast();
        address newImpl = address(new ERC20Gateway());
        UnsafeUpgrades.upgradeProxy(proxy, newImpl, "");
        vm.stopBroadcast();

        console2.log("ERC20Gateway metadata-pin upgrade");
        console2.log("  proxy:", proxy);
        console2.log("  impl :", newImpl);
    }

    function _run(string memory env, bool isL1) internal {
        address payable proxy = _erc20GatewayProxy(env, isL1);
        console2.log("ENV:", env);
        console2.log(isL1 ? "Layer: L1" : "Layer: L2");
        _upgradeErc20Gateway(proxy);
    }
}
