// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson, console2} from "forge-std/Script.sol";
import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";
import {DeployBase} from "./DeployBase.s.sol";

/**
 * @notice Configure L1 bridge and gateways to point at L2 counterparts.
 * @dev Reads deployment manifests from deployments/<ENV>/ and L2 config for chain ID.
 *      Broadcasts against L1 RPC only.
 *
 * Environment:
 * - ENV (optional, default: "testnet") — deployment environment
 * - DEST_CONFIG (optional, default: "scripts/config/<ENV>/l2.json") — L2 chain config
 */
contract SetupL1Bridge is DeployBase {
    using stdJson for string;

    function run() external {
        string memory env = vm.envOr("ENV", string("testnet"));
        string memory sourceJson = vm.readFile(vm.envOr("SOURCE_JSON", string.concat("deployments/", env, "/l1.json")));
        string memory destJson = vm.readFile(vm.envOr("DEST_JSON", string.concat("deployments/", env, "/l2.json")));
        string memory sourceConfig = vm.readFile(vm.envOr("SOURCE_CONFIG", string.concat("scripts/config/", env, "/l1.json")));
        string memory destConfig = vm.readFile(vm.envOr("DEST_CONFIG", string.concat("scripts/config/", env, "/l2.json")));

        address l1Bridge = _readAddr(sourceJson, "bridge");
        address l1Erc20Gateway = _readAddr(sourceJson, "erc20_gateway");
        address l1NativeGateway = _readAddr(sourceJson, "native_gateway");
        address l1TokenFactory = _readAddr(sourceJson, "factory");
        address l1Rollup = _readAddr(sourceJson, "rollup");
        address l2Bridge = _readAddr(destJson, "bridge");
        address l2Erc20Gateway = _readAddr(destJson, "erc20_gateway");
        address l2NativeGateway = _readAddr(destJson, "native_gateway");

        address l2Factory = _readAddr(destJson, "factory");
        address l2FactoryBeacon = _readAddr(destJson, "factory_beacon");
        address l2PeggedImpl = _readAddr(destJson, "pegged_impl");
        uint256 l2ChainId = destConfig.readUint(".chainId");
        uint256 executeGasLimit = sourceConfig.readUint(".bridge.executeGasLimit");

        require(l1Bridge != address(0) && l2Bridge != address(0), "bridge addresses missing");
        require(l1Erc20Gateway != address(0) && l2Erc20Gateway != address(0), "erc20 gateway addresses missing");
        require(l1NativeGateway != address(0) && l2NativeGateway != address(0), "native gateway addresses missing");
        require(l2Factory != address(0), "L2 factory address missing");
        require(l2PeggedImpl != address(0), "L2 pegged impl address missing");
        require(l2ChainId != 0, "L2 chain ID missing");

        console2.log("L1 bridge", l1Bridge, "-> L2 bridge", l2Bridge);
        console2.log("L1 erc20 gateway", l1Erc20Gateway, "-> L2 erc20 gateway", l2Erc20Gateway);
        console2.log("L1 native gateway", l1NativeGateway, "-> L2 native gateway", l2NativeGateway);
        console2.log("L2 factory", l2Factory, "L2 pegged impl", l2PeggedImpl);

        vm.startBroadcast();
        L1FluentBridge(payable(l1Bridge)).setOtherBridge(l2Bridge);
        L1FluentBridge(payable(l1Bridge)).setExecuteGasLimit(executeGasLimit);
        ERC20Gateway(payable(l1Erc20Gateway)).setOtherSide(true, l2Erc20Gateway, l2ChainId, l2PeggedImpl, l2Factory, l2FactoryBeacon);
        NativeGateway(payable(l1NativeGateway)).setOtherSideGateway(l2NativeGateway);
        L1FluentBridge(payable(l1Bridge)).setRollup(l1Rollup);
        ERC20Gateway(payable(l1Erc20Gateway)).setBridgeContract(l1Bridge);
        ERC20Gateway(payable(l1Erc20Gateway)).setTokenFactory(l1TokenFactory);
        vm.stopBroadcast();
    }
}
