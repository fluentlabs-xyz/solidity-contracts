// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Foundry script cheatcodes interface.
interface Vm {
    function startBroadcast() external;
    function stopBroadcast() external;

    function envAddress(string calldata name) external returns (address);
    function envOr(string calldata name, address defaultValue) external returns (address);
    function envOr(string calldata name, uint256 defaultValue) external returns (uint256);
    function envOr(string calldata name, bool defaultValue) external returns (bool);
    function envOr(string calldata name, string calldata defaultValue) external returns (string memory);

    function serializeAddress(string calldata objectKey, string calldata valueKey, address value)
        external
        returns (string memory);
    function writeJson(string calldata json, string calldata path) external;
}

/// @notice Base contract for all deployment/upgrade scripts.
abstract contract BaseScript {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
}
