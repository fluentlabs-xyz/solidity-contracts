// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, stdJson, console2} from "forge-std/Script.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";

/**
 * @notice Configure L2 bridge and gateways to point at L1 counterparts.
 * @dev Reads deployment manifests from deployments/<ENV>/ and L1 config for chain ID.
 *      Broadcasts against L2 RPC only.
 *
 * Environment:
 * - ENV (optional, default: "testnet") — deployment environment
 * - DEST_CONFIG (optional, default: "scripts/config/<ENV>/l1.json") — L1 chain config
 */
contract SetupL2Bridge is Script {
    using stdJson for string;

    function run() external {
        string memory env = vm.envOr("ENV", string("testnet"));
        string memory sourceJson = vm.readFile(vm.envOr("SOURCE_JSON", string.concat("deployments/", env, "/l2.json")));
        string memory destJson = vm.readFile(vm.envOr("DEST_JSON", string.concat("deployments/", env, "/l1.json")));
        string memory sourceConfig = vm.readFile(vm.envOr("SOURCE_CONFIG", string.concat("scripts/config/", env, "/l2.json")));
        string memory destConfig = vm.readFile(vm.envOr("DEST_CONFIG", string.concat("scripts/config/", env, "/l1.json")));

        address l2Bridge = _readAddr(sourceJson, "bridge");
        address l2Erc20Gateway = _readAddr(sourceJson, "erc20_gateway");
        address l2NativeGateway = _readAddr(sourceJson, "native_gateway");
        address l1Bridge = _readAddr(destJson, "bridge");
        address l1Erc20Gateway = _readAddr(destJson, "erc20_gateway");
        address l1NativeGateway = _readAddr(destJson, "native_gateway");

        address l1Factory = _readAddr(destJson, "factory");
        address l1FactoryBeacon = _readAddr(destJson, "factory_beacon");
        address l1PeggedImpl = _readAddr(destJson, "pegged_impl");
        uint256 l1ChainId = destConfig.readUint(".chainId");
        uint256 executeGasLimit = sourceConfig.readUint(".bridge.executeGasLimit");

        require(l2Bridge != address(0) && l1Bridge != address(0), "bridge addresses missing");
        require(l2Erc20Gateway != address(0) && l1Erc20Gateway != address(0), "erc20 gateway addresses missing");
        require(l2NativeGateway != address(0) && l1NativeGateway != address(0), "native gateway addresses missing");
        require(l1Factory != address(0), "L1 factory address missing");
        require(l1FactoryBeacon != address(0), "L1 factory beacon address missing");
        require(l1PeggedImpl != address(0), "L1 pegged impl address missing");
        require(l1ChainId != 0, "L1 chain ID missing");

        console2.log("L2 bridge", l2Bridge, "-> L1 bridge", l1Bridge);
        console2.log("L2 erc20 gateway", l2Erc20Gateway, "-> L1 erc20 gateway", l1Erc20Gateway);
        console2.log("L2 native gateway", l2NativeGateway, "-> L1 native gateway", l1NativeGateway);

        vm.startBroadcast();
        L2FluentBridge(payable(l2Bridge)).setOtherBridge(l1Bridge);
        L2FluentBridge(payable(l2Bridge)).setExecuteGasLimit(executeGasLimit);
        ERC20Gateway(payable(l2Erc20Gateway)).setOtherSide(false, l1Erc20Gateway, l1ChainId, l1PeggedImpl, l1Factory, l1FactoryBeacon);
        NativeGateway(payable(l2NativeGateway)).setOtherSideGateway(l1NativeGateway);
        vm.stopBroadcast();
    }

    function _readAddr(string memory json, string memory key) internal view returns (address) {
        string memory nested = string.concat(".deployment.", key);
        if (vm.keyExistsJson(json, nested)) return json.readAddress(nested);
        string memory flat = string.concat(".", key);
        if (vm.keyExistsJson(json, flat)) return json.readAddress(flat);
        return address(0);
    }
}
