// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {FluentBridge} from "../../contracts/FluentBridge.sol";

/// @notice Relays a native bridge message on destination chain.
/// @dev Reads encoded message metadata from a sendNative broadcast JSON file.
/// Environment:
/// - BRIDGE_ADDRESS      (address, required): destination-chain FluentBridge
/// - FROM_GATEWAY        (address, required): source-chain gateway (msg `from`)
/// - TO_GATEWAY          (address, required): destination-chain gateway (msg `to`)
/// - SOURCE_BROADCAST_JSON (string, optional): path to sendNative broadcast json
///   default: broadcast/sendNative.s.sol/11155111/run-latest.json
contract ReceiveNative is Script {
    function run() external {
        address bridgeAddress = vm.envAddress("BRIDGE_ADDRESS");
        address fromGateway = vm.envAddress("FROM_GATEWAY");
        address toGateway = vm.envAddress("TO_GATEWAY");
        string memory sourceJson = vm.envOr("SOURCE_BROADCAST_JSON", string("broadcast/sendNative.s.sol/11155111/run-latest.json"));

        require(bridgeAddress != address(0) && fromGateway != address(0) && toGateway != address(0), "zero address");

        string memory json = vm.readFile(sourceJson);
        bytes memory data = vm.parseJsonBytes(json, ".receipts[0].logs[0].data");
        (uint256 value, uint256 srcChainId, uint256 srcBlockNumber, uint256 nonce, , bytes memory message) = abi.decode(
            data,
            (uint256, uint256, uint256, uint256, bytes32, bytes)
        );

        vm.startBroadcast();
        FluentBridge(payable(bridgeAddress)).receiveMessage{value: value}(
            fromGateway, payable(toGateway), value, srcChainId, srcBlockNumber, nonce, message
        );
        vm.stopBroadcast();
    }
}
