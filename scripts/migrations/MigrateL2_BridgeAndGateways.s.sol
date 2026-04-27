// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";
import {WETHGateway} from "../../contracts/gateways/WETHGateway.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";

import {DeployBase} from "../deploy/DeployBase.s.sol";

/// @title MigrateL2_BridgeAndGateways
/// @author Fluent Labs
///
/// @notice Fluent **L2** migration: upgrade {L2FluentBridge}, upgrade all standard L2 proxies
///         ({ERC20Gateway}, {NativeGateway}, {UniversalTokenFactory}), optionally upgrade
///         {WETHGateway}, then **whitelist** every relevant gateway on the L2 bridge via
///         `registerGateway`.
///
/// @dev Multi-signer (same split as L1 fastlist/blacklist migrations):
///
///        - `BRIDGE_ADMIN` — `DEFAULT_ADMIN_ROLE` on the L2 bridge. Signs:
///             * `UnsafeUpgrades.upgradeProxy(bridge, new L2FluentBridge())`,
///             * `L2FluentBridge.registerGateway(...)` for each local + remote address.
///
///        - `GATEWAY_OWNER` — `Ownable` owner of {ERC20Gateway}, {NativeGateway}, and
///           {UniversalTokenFactory} on L2. Signs:
///             * upgrade the three proxies to freshly built implementations.
///
///        - `WETH_GATEWAY_OWNER` (optional) — `Ownable` owner of {WETHGateway} when present
///           in the manifest. If `weth_gateway_proxy` is non-zero in `deployments/<ENV>/l2.json`
///           and this env is unset, it **defaults to `BRIDGE_ADMIN`** (override when the WETH
///           gateway was deployed under a different owner, e.g. `gateway_initial_owner`).
///
/// @dev Whitelist set (mirror of L1 `registerGateway` symmetry):
///
///        **Local (this chain / L2):** `erc20_gateway`, `native_gateway`, and `weth_gateway_proxy`
///        when non-zero — these are the gateways users call on Fluent.
///
///        **Remote (L1 peer addresses):** read from `deployments/<ENV>/l1.json` — same logical
///        gateways on Ethereum: `erc20_gateway`, `native_gateway`, `weth_gateway_proxy`
///        (skip zero). Outbound `sendMessage` targets the **L1** gateway addresses; the bridge
///        must admit them as registered peers.
///
/// @dev Environment:
///        `ENV` (optional, default `testnet`) — `deployments/<ENV>/l2.json` + `l1.json`.
///        `BRIDGE_ADMIN` (required)
///        `GATEWAY_OWNER` (required)
///        `WETH_GATEWAY_OWNER` (optional) — only used when `weth_gateway_proxy != 0`.
///
/// @dev Does not update JSON manifests; operator copies logged impl addresses.
contract MigrateL2_BridgeAndGateways is DeployBase {
    struct Addrs {
        address payable bridge;
        address payable erc20Gateway;
        address payable nativeGateway;
        address payable factory;
        address wethGateway;
        address bridgeAdmin;
        address gatewayOwner;
        address wethGatewayOwner;
        address remoteErc20;
        address remoteNative;
        address remoteWethGw;
    }

    function run() external {
        string memory env = vm.envOr("ENV", string("testnet"));
        Addrs memory a = _load(env);
        _logPlan(env, a);

        // Phase 1 — bridge admin: upgrade L2FluentBridge
        vm.startBroadcast(a.bridgeAdmin);
        address newBridgeImpl = address(new L2FluentBridge());
        UnsafeUpgrades.upgradeProxy(a.bridge, newBridgeImpl, "");
        console2.log("L2FluentBridge:", a.bridge, "->", newBridgeImpl);
        vm.stopBroadcast();

        // Phase 2 — gateway owner: ERC20, Native, Factory
        vm.startBroadcast(a.gatewayOwner);
        address newErc20Impl = address(new ERC20Gateway());
        UnsafeUpgrades.upgradeProxy(a.erc20Gateway, newErc20Impl, "");
        console2.log("ERC20Gateway:  ", a.erc20Gateway, "->", newErc20Impl);

        NativeGateway newNativeImplCtr = new NativeGateway();
        require(
            newNativeImplCtr.NATIVE_LIMIT_KEY() == address(0x0000012345678901234567890123456789012345),
            "NATIVE_LIMIT_KEY mismatch"
        );
        UnsafeUpgrades.upgradeProxy(a.nativeGateway, address(newNativeImplCtr), "");
        console2.log("NativeGateway: ", a.nativeGateway, "->", address(newNativeImplCtr));

        address newFactoryImpl = address(new UniversalTokenFactory());
        UnsafeUpgrades.upgradeProxy(a.factory, newFactoryImpl, "");
        console2.log("UniversalTokenFactory:", a.factory, "->", newFactoryImpl);
        vm.stopBroadcast();

        // Phase 3 — WETH gateway owner (only if proxy configured)
        if (a.wethGateway != address(0)) {
            vm.startBroadcast(a.wethGatewayOwner);
            address newWethImpl = address(new WETHGateway());
            UnsafeUpgrades.upgradeProxy(payable(a.wethGateway), newWethImpl, "");
            console2.log("WETHGateway:     ", a.wethGateway, "->", newWethImpl);
            vm.stopBroadcast();
        }

        // Phase 4 — bridge admin: whitelist local + remote gateways
        vm.startBroadcast(a.bridgeAdmin);
        L2FluentBridge br = L2FluentBridge(a.bridge);

        br.registerGateway(a.erc20Gateway);
        br.registerGateway(a.nativeGateway);
        console2.log("registerGateway (L2 local): erc20, native");

        if (a.wethGateway != address(0)) {
            br.registerGateway(a.wethGateway);
            console2.log("registerGateway (L2 local): weth_gateway");
        }

        br.registerGateway(a.remoteErc20);
        br.registerGateway(a.remoteNative);
        console2.log("registerGateway (L1 remote): erc20, native");

        if (a.remoteWethGw != address(0)) {
            br.registerGateway(a.remoteWethGw);
            console2.log("registerGateway (L1 remote): weth_gateway");
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("== L2 migration complete: bridge + gateways upgraded, peers whitelisted ==");
    }

    function _load(string memory env) internal view returns (Addrs memory a) {
        string memory l2 = vm.readFile(string.concat("deployments/", env, "/l2.json"));
        string memory l1 = vm.readFile(string.concat("deployments/", env, "/l1.json"));

        a.bridge = payable(_readAddr(l2, "bridge"));
        a.erc20Gateway = payable(_readAddr(l2, "erc20_gateway"));
        a.nativeGateway = payable(_readAddr(l2, "native_gateway"));
        a.factory = payable(_readAddr(l2, "factory"));
        a.wethGateway = _readAddr(l2, "weth_gateway_proxy");

        a.bridgeAdmin = vm.envAddress("BRIDGE_ADMIN");
        a.gatewayOwner = vm.envAddress("GATEWAY_OWNER");
        a.wethGatewayOwner = vm.envOr("WETH_GATEWAY_OWNER", a.bridgeAdmin);

        a.remoteErc20 = _readAddr(l1, "erc20_gateway");
        a.remoteNative = _readAddr(l1, "native_gateway");
        a.remoteWethGw = _readAddr(l1, "weth_gateway_proxy");

        require(a.bridge != address(0) && a.bridge.code.length > 0, "L2 bridge missing");
        require(a.erc20Gateway != address(0), "L2 erc20_gateway missing");
        require(a.nativeGateway != address(0), "L2 native_gateway missing");
        require(a.factory != address(0), "L2 factory missing");
        require(a.bridgeAdmin != address(0), "BRIDGE_ADMIN required");
        require(a.gatewayOwner != address(0), "GATEWAY_OWNER required");
        require(a.remoteErc20 != address(0) && a.remoteNative != address(0), "L1 manifest gateways missing");
    }

    function _logPlan(string memory env, Addrs memory a) internal pure {
        console2.log("== MigrateL2_BridgeAndGateways ==");
        console2.log("env:                ", env);
        console2.log("L2 bridge:          ", a.bridge);
        console2.log("L2 erc20Gateway:    ", a.erc20Gateway);
        console2.log("L2 nativeGateway:   ", a.nativeGateway);
        console2.log("L2 factory:         ", a.factory);
        console2.log("L2 weth_gateway:    ", a.wethGateway);
        console2.log("BRIDGE_ADMIN:       ", a.bridgeAdmin);
        console2.log("GATEWAY_OWNER:      ", a.gatewayOwner);
        console2.log("WETH_GATEWAY_OWNER: ", a.wethGatewayOwner);
        console2.log("L1 erc20 (remote):  ", a.remoteErc20);
        console2.log("L1 native (remote): ", a.remoteNative);
        console2.log("L1 weth_gw (remote):", a.remoteWethGw);
        console2.log("");
    }
}
