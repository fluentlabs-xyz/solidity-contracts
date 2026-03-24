// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, stdJson, console2} from "forge-std/Script.sol";
import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";

/**
 * @notice Configure L1 bridge and gateway to point at L2 counterparts.
 * @dev Reads both deployment manifests. Broadcasts against L1 RPC only.
 *      Run SetupL2Bridge.s.sol separately against L2 RPC to complete linking.
 *
 * Environment:
 * - SOURCE_JSON (optional, default: "deployments/sepolia.json")
 * - DEST_JSON (optional, default: "deployments/fluent_testnet.json")
 */
contract SetupL1Bridge is Script {
    using stdJson for string;

    function run() external {
        string memory sourceJson = vm.readFile(vm.envOr("SOURCE_JSON", string("deployments/sepolia.json")));
        string memory destJson = vm.readFile(vm.envOr("DEST_JSON", string("deployments/fluent_testnet.json")));

        address l1Bridge = _readAddr(sourceJson, "bridge");
        address l1Gateway = _readAddr(sourceJson, "gateway");
        address l2Bridge = _readAddr(destJson, "bridge");
        address l2Gateway = _readAddr(destJson, "gateway");

        require(l1Bridge != address(0) && l2Bridge != address(0), "bridge addresses missing");
        require(l1Gateway != address(0) && l2Gateway != address(0), "gateway addresses missing");

        console2.log("L1 bridge", l1Bridge, "-> L2 bridge", l2Bridge);
        console2.log("L1 gateway", l1Gateway, "-> L2 gateway", l2Gateway);

        vm.startBroadcast();
        L1FluentBridge(payable(l1Bridge)).setOtherBridge(l2Bridge);
        ERC20Gateway(payable(l1Gateway)).setOtherSideGateway(l2Gateway);
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
