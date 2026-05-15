// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, stdJson} from "forge-std/Script.sol";

/// @notice Shared utilities for deployment scripts: config reading and manifest address lookup.
abstract contract DeployBase is Script {
    using stdJson for string;

    struct SafeTransaction {
        address to;
        uint256 value;
        bytes data;
        string contractMethod;
        string contractInputsValues;
    }

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

    /// @dev Writes a Safe Transaction Builder-compatible JSON batch.
    function _writeSafeBatch(
        string memory path,
        address safe,
        string memory name,
        string memory description,
        SafeTransaction[] memory transactions
    ) internal {
        require(safe != address(0), "safe required");
        require(transactions.length != 0, "transactions required");

        string memory json = string.concat(
            "{\n",
            '  "version": "1.0",\n',
            '  "chainId": "',
            vm.toString(block.chainid),
            '",\n',
            '  "createdAt": 0,\n',
            '  "meta": {\n',
            '    "name": "',
            name,
            '",\n',
            '    "description": "',
            description,
            '",\n',
            '    "txBuilderVersion": "1.18.0",\n',
            '    "createdFromSafeAddress": "',
            _addressToHex(safe),
            '",\n',
            '    "createdFromOwnerAddress": "",\n',
            '    "checksum": ""\n',
            "  },\n",
            '  "transactions": [\n'
        );

        for (uint256 i; i < transactions.length; i++) {
            json = string.concat(json, _safeTransactionJson(transactions[i], i + 1 == transactions.length));
            if (i + 1 < transactions.length) json = string.concat(json, "\n");
        }

        json = string.concat(json, "\n  ]\n", "}\n");
        vm.writeFile(path, json);
    }

    function _safeTransactionJson(SafeTransaction memory transaction, bool last) internal pure returns (string memory) {
        string memory suffix = last ? "" : ",";
        return string.concat(
            "    {\n",
            '      "to": "',
            _addressToHex(transaction.to),
            '",\n',
            '      "value": "',
            _uintToString(transaction.value),
            '",\n',
            '      "data": "',
            _toHex(transaction.data),
            '",\n',
            '      "contractMethod": ',
            bytes(transaction.contractMethod).length == 0 ? "null" : transaction.contractMethod,
            ",\n",
            '      "contractInputsValues": ',
            bytes(transaction.contractInputsValues).length == 0 ? "null" : transaction.contractInputsValues,
            "\n",
            "    }",
            suffix
        );
    }

    function _toHex(bytes memory data) internal pure returns (string memory) {
        bytes16 symbols = "0123456789abcdef";
        bytes memory out = new bytes(2 + data.length * 2);
        out[0] = "0";
        out[1] = "x";

        for (uint256 i; i < data.length; i++) {
            uint8 value = uint8(data[i]);
            out[2 + i * 2] = symbols[value >> 4];
            out[3 + i * 2] = symbols[value & 0x0f];
        }

        return string(out);
    }

    function _addressToHex(address account) internal pure returns (string memory) {
        return _toHex(abi.encodePacked(account));
    }

    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";

        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }

        return string(buffer);
    }
}
