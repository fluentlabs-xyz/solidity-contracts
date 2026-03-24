// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, stdJson, console2} from "forge-std/Script.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";

/**
 * @notice Configure L2 bridge and gateway to point at L1 counterparts.
 * @dev Reads both deployment manifests. Broadcasts against L2 RPC only.
 *      Run SetupL1Bridge.s.sol separately against L1 RPC to complete linking.
 *
 * Environment:
 * - SOURCE_JSON (optional, default: "deployments/fluent_testnet.json") — L2 manifest
 * - DEST_JSON (optional, default: "deployments/sepolia.json") — L1 manifest
 */
contract SetupL2Bridge is Script {
    using stdJson for string;

    function run() external {
        string memory sourceJson = vm.readFile(vm.envOr("SOURCE_JSON", string("deployments/fluent_testnet.json")));
        string memory destJson = vm.readFile(vm.envOr("DEST_JSON", string("deployments/sepolia.json")));

        address l2Bridge = _readAddr(sourceJson, "bridge");
        address l2Gateway = _readAddr(sourceJson, "gateway");
        address l1Bridge = _readAddr(destJson, "bridge");
        address l1Gateway = _readAddr(destJson, "gateway");

        require(l2Bridge != address(0) && l1Bridge != address(0), "bridge addresses missing");
        require(l2Gateway != address(0) && l1Gateway != address(0), "gateway addresses missing");

        console2.log("L2 bridge", l2Bridge, "-> L1 bridge", l1Bridge);
        console2.log("L2 gateway", l2Gateway, "-> L1 gateway", l1Gateway);

        vm.startBroadcast();
        L2FluentBridge(payable(l2Bridge)).setOtherBridge(l1Bridge);
        ERC20Gateway(payable(l2Gateway)).setOtherSideGateway(l1Gateway);
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
