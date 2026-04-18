// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";
import {FastWithdrawalList} from "../../contracts/fastlist/FastWithdrawalList.sol";

import {DeployBase} from "../deploy/DeployBase.s.sol";

/// @notice Whitelist-feature migration for L1.
///
/// @dev What this script does, in order:
///        1.  Deploys a fresh {FastWithdrawalList} behind a UUPS proxy.
///        2.  Upgrades the existing L1FluentBridge implementation to the new one
///            (adds `_gatewayWhitelist` mapping, transient `_currentBatchIndex`,
///            `registerGateway` / `deregisterGateway` admin API, gateway-symmetric
///            `GatewayNotWhitelisted` guards on send + receive).
///        3.  Upgrades the existing ERC20Gateway and NativeGateway implementations
///            (adds `_fastWithdrawalList` storage + `_whitelistEnabled` toggle, drops
///            the old per-gateway `_tokenLimitConfig` / `_usageInfo` mappings).
///        4.  Wires the new FastWithdrawalList into both gateways via
///            `setFastWithdrawalList`.
///        5.  Registers both gateways as `consumers` on the FastWithdrawalList so
///            their `_consumeLimit` calls are accepted.
///        6.  Registers the *local* gateway addresses on the bridge so receives into
///            them and sends originating from them stay admitted.
///        7.  Registers the *remote* (L2) gateway addresses on the bridge so user-side
///            `gateway.sendTokens(...)` / `gateway.sendNativeTokens(...)` calls — which
///            target the remote gateway — pass the new symmetric admission check.
///
///      The script does **not** flip `setWhitelistEnabled(true)`. Enabling the policy is a
///      separate operational step that must follow:
///        a) admin-registering each token to be allowed for fast withdrawal via
///           `fastWithdrawalList.registerToken(token, hourlyCap, dailyCap)`,
///        b) for ETH/WETH, additionally calling `setAlias(WETH, NATIVE_LIMIT_KEY)` so a
///           single combined cap covers both gateways.
///
/// @dev Environment:
///        ENV (default: testnet) — manifest dir under deployments/<ENV>/
///        FAST_WITHDRAWAL_LIST_OWNER (required) — initial owner of the new list
///                                                (typically the existing L1 admin / timelock)
///
/// @dev Storage layout: this migration appends fields to existing ERC-7201 namespaced
///      structs. No deployed slots are removed or reordered. The audit-time validation
///      of layout compatibility is the operator's responsibility before broadcast —
///      this script uses {UnsafeUpgrades} to match the existing migration convention.
contract MigrateL1_Whitelist is DeployBase {
    using stdJson for string;

    struct L1Addresses {
        address payable bridge;
        address payable erc20Gateway;
        address payable nativeGateway;
        address payable remoteErc20Gateway;
        address payable remoteNativeGateway;
        address fastWithdrawalListOwner;
    }

    function run() external {
        string memory env = vm.envOr("ENV", string("testnet"));
        L1Addresses memory addrs = _loadAddresses(env);

        _logPlan(env, addrs);

        vm.startBroadcast();

        // 1. Deploy FastWithdrawalList behind a UUPS proxy.
        FastWithdrawalList listImpl = new FastWithdrawalList();
        ERC1967Proxy listProxy = new ERC1967Proxy(
            address(listImpl),
            abi.encodeCall(FastWithdrawalList.initialize, (addrs.fastWithdrawalListOwner))
        );
        FastWithdrawalList list = FastWithdrawalList(address(listProxy));
        console2.log("FastWithdrawalList proxy:", address(list));
        console2.log("FastWithdrawalList impl :", address(listImpl));

        // 2. Upgrade L1FluentBridge.
        address newBridgeImpl = address(new L1FluentBridge());
        UnsafeUpgrades.upgradeProxy(addrs.bridge, newBridgeImpl, "");
        console2.log("L1FluentBridge:", addrs.bridge, "->", newBridgeImpl);

        // 3. Upgrade gateways.
        address newErc20GatewayImpl = address(new ERC20Gateway());
        UnsafeUpgrades.upgradeProxy(addrs.erc20Gateway, newErc20GatewayImpl, "");
        console2.log("ERC20Gateway:  ", addrs.erc20Gateway, "->", newErc20GatewayImpl);

        address newNativeGatewayImpl = address(new NativeGateway());
        UnsafeUpgrades.upgradeProxy(addrs.nativeGateway, newNativeGatewayImpl, "");
        console2.log("NativeGateway: ", addrs.nativeGateway, "->", newNativeGatewayImpl);

        // 4. Wire FastWithdrawalList into both gateways.
        ERC20Gateway(addrs.erc20Gateway).setFastWithdrawalList(address(list));
        NativeGateway(addrs.nativeGateway).setFastWithdrawalList(address(list));
        console2.log("setFastWithdrawalList: erc20Gateway, nativeGateway");

        // 5. Grant CONSUMER_ROLE to both gateways via the standard OZ AccessControl API.
        bytes32 consumerRole = list.CONSUMER_ROLE();
        list.grantRole(consumerRole, addrs.erc20Gateway);
        list.grantRole(consumerRole, addrs.nativeGateway);
        console2.log("grantRole(CONSUMER_ROLE): erc20Gateway, nativeGateway");

        // 6. Register the local gateways on the bridge — required for both
        //    `_receiveMessage` (inbound) and `sendMessage` (outbound) admission.
        L1FluentBridge bridge = L1FluentBridge(addrs.bridge);
        bridge.registerGateway(addrs.erc20Gateway);
        bridge.registerGateway(addrs.nativeGateway);
        console2.log("registerGateway (local): erc20Gateway, nativeGateway");

        // 7. Register the remote (L2) gateways on the bridge so outbound sends targeting
        //    them are admitted under the new symmetric send-side check.
        bridge.registerGateway(addrs.remoteErc20Gateway);
        bridge.registerGateway(addrs.remoteNativeGateway);
        console2.log("registerGateway (remote): erc20Gateway, nativeGateway");

        vm.stopBroadcast();

        console2.log("");
        console2.log("== Migration complete. Whitelist policy is NOT yet enabled. ==");
        console2.log("Next steps (separate broadcast):");
        console2.log("  1. fastWithdrawalList.registerToken(...) for each fast-withdrawable token");
        console2.log("  2. fastWithdrawalList.setAlias(WETH, NATIVE_LIMIT_KEY) if ETH/WETH share a cap");
        console2.log("  3. erc20Gateway.setWhitelistEnabled(true) and nativeGateway.setWhitelistEnabled(true)");
    }

    /// @dev Loads addresses from the L1 deployment manifest plus the remote (L2) manifest,
    ///      and from the `FAST_WITHDRAWAL_LIST_OWNER` env var.
    function _loadAddresses(string memory env) internal view returns (L1Addresses memory addrs) {
        string memory l1Manifest = vm.readFile(string.concat("deployments/", env, "/l1.json"));
        string memory l2Manifest = vm.readFile(string.concat("deployments/", env, "/l2.json"));

        addrs.bridge = payable(_readAddr(l1Manifest, "bridge"));
        addrs.erc20Gateway = payable(_readAddr(l1Manifest, "erc20_gateway"));
        addrs.nativeGateway = payable(_readAddr(l1Manifest, "native_gateway"));
        addrs.remoteErc20Gateway = payable(_readAddr(l2Manifest, "erc20_gateway"));
        addrs.remoteNativeGateway = payable(_readAddr(l2Manifest, "native_gateway"));
        addrs.fastWithdrawalListOwner = vm.envAddress("FAST_WITHDRAWAL_LIST_OWNER");

        require(addrs.bridge != address(0), "L1 bridge address missing in manifest");
        require(addrs.erc20Gateway != address(0), "L1 erc20_gateway address missing in manifest");
        require(addrs.nativeGateway != address(0), "L1 native_gateway address missing in manifest");
        require(addrs.remoteErc20Gateway != address(0), "L2 erc20_gateway address missing in manifest");
        require(addrs.remoteNativeGateway != address(0), "L2 native_gateway address missing in manifest");
        require(addrs.fastWithdrawalListOwner != address(0), "FAST_WITHDRAWAL_LIST_OWNER required");
    }

    function _logPlan(string memory env, L1Addresses memory addrs) internal pure {
        console2.log("== MigrateL1_Whitelist ==");
        console2.log("env:                 ", env);
        console2.log("L1 bridge:           ", addrs.bridge);
        console2.log("L1 erc20Gateway:     ", addrs.erc20Gateway);
        console2.log("L1 nativeGateway:    ", addrs.nativeGateway);
        console2.log("L2 erc20Gateway:     ", addrs.remoteErc20Gateway);
        console2.log("L2 nativeGateway:    ", addrs.remoteNativeGateway);
        console2.log("FastWithdrawal owner:", addrs.fastWithdrawalListOwner);
        console2.log("");
    }
}
