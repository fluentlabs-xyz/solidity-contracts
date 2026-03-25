// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, stdJson} from "forge-std/Script.sol";

/// @notice Shared utilities for deployment scripts: config reading and manifest address lookup.
abstract contract DeployBase is Script {
    using stdJson for string;

    /// @dev Reads a chain config JSON from scripts/config/<network>.json.
    ///      Network can include subdirectories, e.g. "testnet/l1" → scripts/config/testnet/l1.json.
    function _readConfig(string memory network) internal view returns (string memory) {
        return vm.readFile(string.concat("scripts/config/", network, ".json"));
    }

    /// @dev Reads an address from a deployment manifest JSON. Supports both flat (".key") and
    ///      nested (".deployment.key") formats for backward compatibility.
    function _readAddr(string memory json, string memory key) internal view returns (address) {
        string memory nested = string.concat(".deployment.", key);
        if (vm.keyExistsJson(json, nested)) return json.readAddress(nested);
        string memory flat = string.concat(".", key);
        if (vm.keyExistsJson(json, flat)) return json.readAddress(flat);
        return address(0);
    }
}
