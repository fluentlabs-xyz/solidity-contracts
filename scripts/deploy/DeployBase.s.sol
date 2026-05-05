// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, stdJson} from "forge-std/Script.sol";

/// @notice Shared utilities for deployment scripts: config reading and manifest address lookup.
abstract contract DeployBase is Script {
    using stdJson for string;

    struct TargetChain {
        string chain;
        string envName;
        string layer;
        string network;
        string manifestPath;
        uint256 chainId;
    }

    /// @dev Resolves the deployment target from CHAIN. `NETWORK` is still accepted for older scripts,
    ///      but release/migration flows should use CHAIN so the wrapper can also select the matching RPC.
    ///      Supported CHAIN values: L1_MAINNET, L1_SEPOLIA, L2_MAINNET, L2_TESTNET, LOCAL_L1, LOCAL_L2.
    function _activeChain() internal view returns (TargetChain memory c) {
        string memory chain = vm.envOr("CHAIN", string(""));
        if (bytes(chain).length == 0) {
            string memory network = vm.envOr("NETWORK", string(""));
            require(bytes(network).length != 0, "CHAIN required (or legacy NETWORK)");
            c.network = network;
            c.chain = network;
            (c.envName, c.layer) = _splitNetwork(network);
        } else {
            c.chain = chain;
            bytes32 h = keccak256(bytes(chain));
            if (h == keccak256("L1_MAINNET")) {
                c.envName = "mainnet";
                c.layer = "l1";
            } else if (h == keccak256("L2_MAINNET")) {
                c.envName = "mainnet";
                c.layer = "l2";
            } else if (h == keccak256("L1_SEPOLIA") || h == keccak256("L1_TESTNET")) {
                c.envName = "testnet";
                c.layer = "l1";
            } else if (h == keccak256("L2_TESTNET")) {
                c.envName = "testnet";
                c.layer = "l2";
            } else if (h == keccak256("LOCAL_L1")) {
                c.envName = "local";
                c.layer = "l1";
            } else if (h == keccak256("LOCAL_L2")) {
                c.envName = "local";
                c.layer = "l2";
            } else {
                revert(string.concat("Unsupported CHAIN: ", chain));
            }
            c.network = string.concat(c.envName, "/", c.layer);
        }

        string memory json = _readConfig(c.network);
        c.chainId = json.readUint(".chainId");
        c.manifestPath = string.concat("deployments/", c.network, ".json");
    }

    function _readActiveConfig() internal view returns (TargetChain memory c, string memory json) {
        c = _activeChain();
        json = _readConfig(c.network);
        _assertChainId(c, json);
    }

    function _assertChainId(TargetChain memory c, string memory json) internal view {
        uint256 expected = c.chainId == 0 ? json.readUint(".chainId") : c.chainId;
        require(block.chainid == expected, "wrong RPC: block.chainid != config chainId");
    }

    function _assertHasCode(address target, string memory label) internal view {
        require(target != address(0), string.concat(label, " is zero"));
        require(target.code.length != 0, string.concat(label, " has no code"));
    }

    function _assertNoCode(address target, string memory label) internal view {
        require(target.code.length == 0, string.concat(label, " already has code"));
    }

    /// @dev Reads a chain config JSON from scripts/config/<network>.json.
    ///      Network can include subdirectories, e.g. "testnet/l1" → scripts/config/testnet/l1.json.
    function _readConfig(string memory network) internal view returns (string memory) {
        return vm.readFile(string.concat("scripts/config/", network, ".json"));
    }

    function _splitNetwork(string memory network) internal pure returns (string memory envName, string memory layer) {
        bytes memory raw = bytes(network);
        for (uint256 i = 0; i < raw.length; i++) {
            if (raw[i] == "/") {
                bytes memory envBytes = new bytes(i);
                bytes memory layerBytes = new bytes(raw.length - i - 1);
                for (uint256 j = 0; j < i; j++) {
                    envBytes[j] = raw[j];
                }
                for (uint256 j = i + 1; j < raw.length; j++) {
                    layerBytes[j - i - 1] = raw[j];
                }
                return (string(envBytes), string(layerBytes));
            }
        }
        revert("NETWORK must be <env>/<layer>");
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
