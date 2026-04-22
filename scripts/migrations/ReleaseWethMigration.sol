// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console2} from "forge-std/console2.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {WETHGateway} from "../../contracts/gateways/WETHGateway.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";

import {DeployBase} from "../deploy/DeployBase.s.sol";

/// @title ReleaseWethMigration
/// @author Fluent Labs
///
/// @notice Combined release migration: upgrades {ERC20Gateway} on both chains and
///         {UniversalTokenFactory} on L2, then deploys and wires {WETHGateway}
///         end-to-end. Replaces the prior metadata-pin-only migration scripts.
///
/// @dev Steps (one Forge broadcast each — must run on the right RPC):
///        1. `runL1Upgrade`               — L1: upgrade {ERC20Gateway} implementation.
///        2. `runL2Upgrade`               — L2: upgrade {ERC20Gateway} + {UniversalTokenFactory}.
///        3. `runL1DeployWethGateway`     — L1: deploy {WETHGateway} proxy, register on bridge.
///        4. `runL2DeployWethGateway`     — L2: deploy {WETHGateway}, deploy Universal-WETH,
///                                          pair, register both gateways on the L2 bridge.
///        5. `runL1WireWethGateway`       — L1: `setOtherSideGateway` + register peer on bridge.
///
///      Env (read lazily per step, all optional unless noted):
///        - `ENV`                         — manifest dir (defaults to wrapper's `_defaultEnv()`).
///        - `L1_WETH_ADDRESS` (step 3)   — canonical WETH9 on L1. Must be deployed.
///        - `WETH_GATEWAY_L1` (steps 4/5) — address emitted by step 3.
///        - `WETH_GATEWAY_L2` (step 5)   — address emitted by step 4.
///        - `WETH_GATEWAY_INITIAL_OWNER`  — override `tx.origin` for gateway ownership.
///
/// @dev All step functions are `public virtual` so env wrappers can alias or override.
abstract contract ReleaseWethMigration is DeployBase {
    // ============ Abstract hooks ============

    /// @dev Manifest directory to use when `ENV` is unset (`testnet` / `mainnet`).
    function _defaultEnv() internal pure virtual returns (string memory);

    address L1_WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // ============ 1. Upgrades ============

    /// @notice Step 1 — L1: UUPS-upgrade {ERC20Gateway} to the build in this repo.
    function runL1Upgrade() public virtual {
        string memory env = vm.envOr("ENV", _defaultEnv());
        string memory l1Manifest = vm.readFile(string.concat("deployments/", env, "/l1.json"));
        address payable erc20Gateway = payable(_readAddr(l1Manifest, "erc20_gateway"));
        require(erc20Gateway != address(0), "l1.erc20_gateway missing");
        require(erc20Gateway.code.length > 0, "L1 ERC20Gateway proxy has no code");

        vm.startBroadcast();
        address newImpl = address(new ERC20Gateway());
        UnsafeUpgrades.upgradeProxy(erc20Gateway, newImpl, "");

        ERC20Gateway(erc20Gateway).setBridgingExcludedOrigin(L1_WETH_ADDRESS, true);
        console2.log("L1 ERC20Gateway: excluded L1 WETH from generic bridge");

        vm.stopBroadcast();

        console2.log("L1 ERC20Gateway upgraded");
        console2.log("  proxy:", erc20Gateway);
        console2.log("  impl :", newImpl);
    }

    /// @notice Step 2 — L2: UUPS-upgrade {ERC20Gateway} and {UniversalTokenFactory} in one broadcast.
    function runL2Upgrade() public virtual {
        string memory env = vm.envOr("ENV", _defaultEnv());
        string memory l2Manifest = vm.readFile(string.concat("deployments/", env, "/l2.json"));
        address payable erc20Gateway = payable(_readAddr(l2Manifest, "erc20_gateway"));
        address payable factory = payable(_readAddr(l2Manifest, "factory"));
        require(erc20Gateway != address(0), "l2.erc20_gateway missing");
        require(factory != address(0), "l2.factory missing");
        require(erc20Gateway.code.length > 0, "L2 ERC20Gateway proxy has no code");
        require(factory.code.length > 0, "L2 UniversalTokenFactory proxy has no code");

        vm.startBroadcast();
        address newGatewayImpl = address(new ERC20Gateway());
        UnsafeUpgrades.upgradeProxy(erc20Gateway, newGatewayImpl, "");

        address newFactoryImpl = address(new UniversalTokenFactory());
        UnsafeUpgrades.upgradeProxy(factory, newFactoryImpl, "");

        vm.stopBroadcast();

        console2.log("L2 upgrades complete");
        console2.log("  ERC20Gateway         proxy:", erc20Gateway);
        console2.log("  ERC20Gateway         impl :", newGatewayImpl);
        console2.log("  UniversalTokenFactory proxy:", factory);
        console2.log("  UniversalTokenFactory impl :", newFactoryImpl);
    }

    // ============ 2. WETHGateway deploy & wire ============

    /// @notice Step 3 — L1: deploy {WETHGateway} proxy and `registerGateway` on the L1 bridge.
    function runL1DeployWethGateway() public virtual {
        string memory env = vm.envOr("ENV", _defaultEnv());
        string memory l1Manifest = vm.readFile(string.concat("deployments/", env, "/l1.json"));

        address payable bridge = payable(_readAddr(l1Manifest, "bridge"));
        address l1Weth = vm.envAddress("L1_WETH_ADDRESS");

        require(bridge.code.length > 0, "L1 bridge has no code");
        require(l1Weth.code.length > 0, "L1_WETH_ADDRESS has no code");

        vm.startBroadcast();
        address initialOwner = _initialOwner();

        WETHGateway impl = new WETHGateway();
        address proxy = address(new ERC1967Proxy(address(impl), abi.encodeCall(WETHGateway.initialize, (initialOwner, bridge, l1Weth))));

        L1FluentBridge(bridge).registerGateway(proxy);
        vm.stopBroadcast();

        console2.log("WETH_GATEWAY_L1 (proxy):", proxy);
        console2.log("WETH_GATEWAY_L1 impl    :", address(impl));
        console2.log("export WETH_GATEWAY_L1=", proxy);
        console2.log("Next: runL2DeployWethGateway on the L2 chain RPC");
    }

    /// @notice Step 4 — L2: deploy {WETHGateway} (deferred WETH), deploy Universal-WETH via the
    ///         upgraded factory, pair, and register both gateways on the L2 bridge.
    function runL2DeployWethGateway() public virtual {
        string memory env = vm.envOr("ENV", _defaultEnv());
        string memory l2Manifest = vm.readFile(string.concat("deployments/", env, "/l2.json"));

        address payable l2Bridge = payable(_readAddr(l2Manifest, "bridge"));
        address universalFactory = _readAddr(l2Manifest, "factory");
        address l1Gateway = vm.envAddress("WETH_GATEWAY_L1");
        address l1WethOrigin = vm.envAddress("L1_WETH_ADDRESS");

        require(l2Bridge.code.length > 0, "L2 bridge has no code");
        require(universalFactory.code.length > 0, "UniversalTokenFactory has no code");

        vm.startBroadcast();
        address initialOwner = _initialOwner();

        // `wrapped = true` activates the WETH9 `deposit` / `withdraw` surface on the L2
        // precompile so {WETHGateway} can wrap/unwrap against it like canonical WETH9.
        bytes memory deployArgs = abi.encode("Wrapped Ether", "WETH", uint8(18), uint256(0), address(0), gwProxy, true);
        address universalWeth = UniversalTokenFactory(universalFactory).deployToken(gwProxy, l1WethOrigin, deployArgs);

        WETHGateway impl = new WETHGateway();
        address gwProxy = address(new ERC1967Proxy(address(impl), abi.encodeCall(WETHGateway.initialize, (initialOwner, l2Bridge, universalWeth))));
        WETHGateway gateway = WETHGateway(payable(gwProxy));

        gateway.setOtherSideGateway(l1Gateway);

        L2FluentBridge(l2Bridge).registerGateway(gwProxy);
        if (gwProxy != l1Gateway) {
            L2FluentBridge(l2Bridge).registerGateway(l1Gateway);
        }

        vm.stopBroadcast();

        console2.log("WETH_GATEWAY_L2 (proxy):", gwProxy);
        console2.log("UNIVERSAL_WETH_L2      :", universalWeth);
        console2.log("export WETH_GATEWAY_L2=", gwProxy);
        console2.log("Next: runL1WireWethGateway on the L1 chain RPC");
    }

    /// @notice Step 5 — L1: `setOtherSideGateway(L2)` and `registerGateway(L2)` on the L1 bridge.
    function runL1WireWethGateway() public virtual {
        string memory env = vm.envOr("ENV", _defaultEnv());
        string memory l1Manifest = vm.readFile(string.concat("deployments/", env, "/l1.json"));

        address payable bridge = payable(_readAddr(l1Manifest, "bridge"));
        address l1Gateway = vm.envAddress("WETH_GATEWAY_L1");
        address l2Gateway = vm.envAddress("WETH_GATEWAY_L2");

        require(bridge.code.length > 0, "L1 bridge has no code");

        vm.startBroadcast();
        WETHGateway(payable(l1Gateway)).setOtherSideGateway(l2Gateway);
        L1FluentBridge(bridge).registerGateway(l2Gateway);
        vm.stopBroadcast();

        console2.log("L1 WETH gateway peer set to:", l2Gateway);
        console2.log("L1 bridge registered remote:", l2Gateway);
    }

    // ============ Internals ============

    /// @dev Owner used for freshly deployed WETH gateways. Falls back to `tx.origin`.
    function _initialOwner() internal view returns (address) {
        return 0x9ec3f0d76A6d3847d86374c791C6E170CAd9518D;
    }

    /// @dev Returns `address(0)` if the env var is missing or invalid.
    function _tryEnvAddress(string memory name) internal view returns (address) {
        try vm.envAddress(name) returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }
}
