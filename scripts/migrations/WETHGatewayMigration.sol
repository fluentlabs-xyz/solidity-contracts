// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console2} from "forge-std/console2.sol";

import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";
import {WETHGateway} from "../../contracts/gateways/WETHGateway.sol";

import {DeployBase} from "../deploy/DeployBase.s.sol";

/// @title WETHGatewayMigration
/// @author Fluent Labs
///
/// @notice Shared deployment steps for {WETHGateway} on L1 (WETH9 or mock) and L2
///         (Universal-token WETH via {UniversalTokenFactory}). Thin wrappers live in
///         `scripts/migrations/testnet/` and `scripts/migrations/mainnet/` with different
///         default `ENV` when `ENV` is unset.
///
/// @dev Three broadcasts (L1 deploy → L2 deploy → L1 wire). See wrapper NatSpec for env vars.
abstract contract WETHGatewayMigration is DeployBase {
    /// @dev Default manifest directory when `ENV` is not set (`testnet` vs `mainnet`).
    function _defaultEnv() internal pure virtual returns (string memory);

    /// @notice Step A — L1: deploy {WETHGateway} proxy and `registerGateway` on the L1 bridge.
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

    /// @notice Step B — L2: deploy gateway (deferred WETH), Universal WETH, pair, register on L2 bridge.
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

        WETHGateway impl = new WETHGateway();
        address gwProxy = address(new ERC1967Proxy(address(impl), abi.encodeCall(WETHGateway.initialize, (initialOwner, l2Bridge, address(0)))));
        WETHGateway gateway = WETHGateway(payable(gwProxy));

        // `wrapped = true` activates the WETH9 `deposit` / `withdraw` surface on the L2
        // precompile, so {WETHGateway} can wrap/unwrap against it like canonical WETH9.
        bytes memory deployArgs = abi.encode("Wrapped Ether", "WETH", uint8(18), uint256(0), gwProxy, gwProxy, true);
        address universalWeth = UniversalTokenFactory(universalFactory).deployToken(gwProxy, l1WethOrigin, deployArgs);

        gateway.setWETH(universalWeth);
        gateway.setOtherSideGateway(l1Gateway);

        L2FluentBridge(l2Bridge).registerGateway(gwProxy);
        L2FluentBridge(l2Bridge).registerGateway(l1Gateway);

        vm.stopBroadcast();

        console2.log("WETH_GATEWAY_L2 (proxy):", gwProxy);
        console2.log("UNIVERSAL_WETH_L2     :", universalWeth);
        console2.log("export WETH_GATEWAY_L2=", gwProxy);
        console2.log("Next: runL1WireWethGateway on the L1 chain RPC");
    }

    /// @notice Step C — L1: `setOtherSideGateway(L2)` and `registerGateway(L2)` on the L1 bridge.
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

    function _initialOwner() internal view returns (address) {
        try vm.envAddress("WETH_GATEWAY_INITIAL_OWNER") returns (address o) {
            if (o != address(0)) return o;
        } catch {}
        return tx.origin;
    }
}
