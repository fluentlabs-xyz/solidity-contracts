// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, stdJson, console2} from "forge-std/Script.sol";

import {WETHGateway} from "../../contracts/gateways/WETHGateway.sol";

/// @dev Minimal surface for {FluentBridge} gateway registration checks.
interface IFluentBridgeGatewayRegistry {
    function isGatewayRegistered(address gateway) external view returns (bool);
}

/// @dev Minimal surface for {UniversalTokenFactory} / {GenericTokenFactory} payment gateway.
interface IUniversalFactoryPaymentGateway {
    function paymentGateway() external view returns (address);
}

/// @dev Minimal surface for {ERC20Gateway} L1-WETH exclusion map.
interface IERC20GatewayBridgingCheck {
    function isBridgingExcludedOrigin(address originToken) external view returns (bool);
}

/// @title VerifyWethReleaseDeployment
/// @author Fluent Labs
///
/// @notice Post-migration sanity checks for WETH gateway wiring across L1 and L2.
///         Runs entirely in Solidity: forks Sepolia (or `L1_RPC`) then Fluent L2 (`FLUENT_TESTNET_RPC_URL`
///         or `L2_RPC`) and asserts on-chain state matches expectations.
///
/// @dev Run (no broadcast):
///        source .env && forge script scripts/verify/VerifyWethReleaseDeployment.s.sol:VerifyWethReleaseDeployment \
///          --sig run -vvv
///
///      Environment:
///        - `ENV` (default `testnet`) — reads `deployments/<ENV>/l1.json` and `l2.json` for bridge + factory + erc20_gateway.
///        - `SEPOLIA_RPC_URL` or `L1_RPC` — L1 fork URL (required).
///        - `FLUENT_TESTNET_RPC_URL` or `L2_RPC` — L2 fork URL (required).
///        - `WETH_GATEWAY_L1` — L1 WETH gateway proxy (required).
///        - `WETH_GATEWAY_L2` — L2 WETH gateway proxy (required).
///        - `L1_WETH_ADDRESS` (optional) — if set: asserted against `WETHGateway.getWETH()` on L1, and both
///          chains' `ERC20Gateway.isBridgingExcludedOrigin(L1_WETH_ADDRESS)` must be true.
contract VerifyWethReleaseDeployment is Script {
    using stdJson for string;

    function run() external {
        string memory env = vm.envOr("ENV", string("testnet"));
        string memory l1Json = vm.readFile(string.concat("deployments/", env, "/l1.json"));
        string memory l2Json = vm.readFile(string.concat("deployments/", env, "/l2.json"));

        address l1Bridge = _readAddr(l1Json, "bridge");
        address l2Bridge = _readAddr(l2Json, "bridge");
        address l2Factory = _readAddr(l2Json, "factory");
        address l2Erc20Gateway = _readAddr(l2Json, "erc20_gateway");
        address l1Erc20Gateway = _readAddr(l1Json, "erc20_gateway");

        address wethGwL1 = vm.envAddress("WETH_GATEWAY_L1");
        address wethGwL2 = vm.envAddress("WETH_GATEWAY_L2");

        require(l1Bridge != address(0) && l2Bridge != address(0), "manifest: bridge missing");
        require(l2Factory != address(0) && l2Erc20Gateway != address(0), "manifest: L2 factory or erc20_gateway missing");
        require(l1Erc20Gateway != address(0), "manifest: L1 erc20_gateway missing");
        require(wethGwL1 != address(0) && wethGwL2 != address(0), "WETH_GATEWAY_L1 / WETH_GATEWAY_L2 required");

        // ---------- L1 fork ----------
        string memory l1Rpc = _l1Rpc();
        vm.createSelectFork(l1Rpc);
        console2.log("--- L1 fork ---", l1Rpc);
        console2.log("chainId:", block.chainid);

        WETHGateway gw1 = WETHGateway(payable(wethGwL1));
        address l1Weth = gw1.getWETH();
        require(l1Weth != address(0), "L1: getWETH is zero");
        console2.log("L1 getWETH        :", l1Weth);

        address envL1Weth = vm.envOr("L1_WETH_ADDRESS", address(0));
        if (envL1Weth != address(0)) {
            require(l1Weth == envL1Weth, "L1: getWETH != L1_WETH_ADDRESS env");
            console2.log("L1_WETH_ADDRESS env matches getWETH");
        }

        address l1Peer = gw1.getOtherSideGateway();
        require(l1Peer == wethGwL2, "L1: getOtherSideGateway != WETH_GATEWAY_L2");
        console2.log("L1 otherSideGateway:", l1Peer);

        IFluentBridgeGatewayRegistry br1 = IFluentBridgeGatewayRegistry(l1Bridge);
        require(br1.isGatewayRegistered(wethGwL1), "L1 bridge: WETH_GATEWAY_L1 not registered");
        require(br1.isGatewayRegistered(wethGwL2), "L1 bridge: WETH_GATEWAY_L2 not registered");
        console2.log("L1 bridge: both WETH gateways registered");

        address envL1WethEx = vm.envOr("L1_WETH_ADDRESS", address(0));
        if (envL1WethEx != address(0)) {
            require(
                IERC20GatewayBridgingCheck(l1Erc20Gateway).isBridgingExcludedOrigin(envL1WethEx),
                "L1: ERC20Gateway must exclude L1_WETH_ADDRESS"
            );
            console2.log("L1 ERC20Gateway: L1 WETH excluded OK");
        }

        // ---------- L2 fork ----------
        string memory l2Rpc = _l2Rpc();
        vm.createSelectFork(l2Rpc);
        console2.log("--- L2 fork ---", l2Rpc);
        console2.log("chainId:", block.chainid);

        address pg = IUniversalFactoryPaymentGateway(l2Factory).paymentGateway();
        require(pg == l2Erc20Gateway, "L2: factory.paymentGateway != manifest erc20_gateway");
        console2.log("L2 factory.paymentGateway == erc20_gateway OK");

        WETHGateway gw2 = WETHGateway(payable(wethGwL2));
        address universalWeth = gw2.getWETH();
        require(universalWeth != address(0), "L2: getWETH is zero");
        console2.log("L2 getWETH (Universal):", universalWeth);

        address l2Peer = gw2.getOtherSideGateway();
        require(l2Peer == wethGwL1, "L2: getOtherSideGateway != WETH_GATEWAY_L1");
        console2.log("L2 otherSideGateway:", l2Peer);

        IFluentBridgeGatewayRegistry br2 = IFluentBridgeGatewayRegistry(l2Bridge);
        require(br2.isGatewayRegistered(wethGwL2), "L2 bridge: WETH_GATEWAY_L2 not registered");
        require(br2.isGatewayRegistered(wethGwL1), "L2 bridge: WETH_GATEWAY_L1 not registered");
        console2.log("L2 bridge: both WETH gateways registered");

        if (envL1WethEx != address(0)) {
            require(
                IERC20GatewayBridgingCheck(l2Erc20Gateway).isBridgingExcludedOrigin(envL1WethEx),
                "L2: ERC20Gateway must exclude L1_WETH_ADDRESS"
            );
            console2.log("L2 ERC20Gateway: L1 WETH excluded OK");
        }

        console2.log("");
        console2.log("== All WETH release deployment checks passed ==");
    }

    function _l1Rpc() internal view returns (string memory) {
        string memory u = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(u).length > 0) return u;
        u = vm.envOr("L1_RPC", string(""));
        require(bytes(u).length > 0, "SEPOLIA_RPC_URL or L1_RPC required");
        return u;
    }

    function _l2Rpc() internal view returns (string memory) {
        string memory u = vm.envOr("FLUENT_TESTNET_RPC_URL", string(""));
        if (bytes(u).length > 0) return u;
        u = vm.envOr("FLUENT_DEV_RPC_URL", string(""));
        if (bytes(u).length > 0) return u;
        u = vm.envOr("L2_RPC", string(""));
        require(bytes(u).length > 0, "FLUENT_TESTNET_RPC_URL, FLUENT_DEV_RPC_URL, or L2_RPC required");
        return u;
    }

    function _readAddr(string memory json, string memory key) internal view returns (address) {
        string memory nested = string.concat(".deployment.", key);
        if (vm.keyExistsJson(json, nested)) return json.readAddress(nested);
        string memory flat = string.concat(".", key);
        if (vm.keyExistsJson(json, flat)) return json.readAddress(flat);
        return address(0);
    }
}
