// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {FluentBridge} from "../../contracts/FluentBridge.sol";

/// @notice Low-level helper script to call FluentBridge.receiveMessage on a target chain.
/// @dev Primarily for debugging/manual recovery. Environment:
/// - BRIDGE_ADDRESS    (address, required): FluentBridge contract address on this chain
/// - FROM              (address, required): original sender on source chain
/// - TO                (address, required): message recipient on this chain
/// - VALUE_WEI         (uint256, optional): msg.value to forward (default: 0)
/// - SRC_CHAIN_ID      (uint256, required): source chain ID encoded in the message
/// - SRC_BLOCK_NUMBER  (uint256, required): source block number encoded in the message
/// - NONCE             (uint256, required): message nonce
/// - MESSAGE_HEX       (string, required): ABI-encoded payload as 0x-prefixed hex
contract ReceiveTokens is Script {
    function run() external {
        address bridgeAddress = vm.envAddress("BRIDGE_ADDRESS");
        address from = vm.envAddress("FROM");
        address to = vm.envAddress("TO");
        uint256 valueWei = vm.envOr("VALUE_WEI", uint256(0));
        uint256 srcChainId = vm.envOr("SRC_CHAIN_ID", uint256(0));
        uint256 srcBlockNumber = vm.envOr("SRC_BLOCK_NUMBER", uint256(0));
        uint256 nonce = vm.envOr("NONCE", uint256(0));
        string memory messageHex = vm.envOr("MESSAGE_HEX", string(""));

        require(bytes(messageHex).length > 2, "MESSAGE_HEX must be non-empty 0x hex");

        bytes memory message = _hexStringToBytes(messageHex);

        FluentBridge bridge = FluentBridge(payable(bridgeAddress));

        vm.startBroadcast();
        bridge.receiveMessage{value: valueWei}(from, payable(to), valueWei, srcChainId, srcBlockNumber, nonce, message);
        vm.stopBroadcast();
    }

    function _hexStringToBytes(string memory s) internal pure returns (bytes memory) {
        bytes memory strBytes = bytes(s);
        require(strBytes.length >= 2, "hex string too short");

        uint256 start = 0;
        if (strBytes[0] == "0" && (strBytes[1] == "x" || strBytes[1] == "X")) {
            start = 2;
        }

        require((strBytes.length - start) % 2 == 0, "hex string length must be even");
        uint256 len = (strBytes.length - start) / 2;
        bytes memory result = new bytes(len);

        for (uint256 i = 0; i < len; i++) {
            uint8 msn = _fromHexChar(uint8(strBytes[start + 2 * i]));
            uint8 lsn = _fromHexChar(uint8(strBytes[start + 2 * i + 1]));
            result[i] = bytes1((msn << 4) | lsn);
        }

        return result;
    }

    function _fromHexChar(uint8 c) internal pure returns (uint8) {
        if (c >= uint8(bytes1("0")) && c <= uint8(bytes1("9"))) {
            return c - uint8(bytes1("0"));
        }
        if (c >= uint8(bytes1("a")) && c <= uint8(bytes1("f"))) {
            return 10 + c - uint8(bytes1("a"));
        }
        if (c >= uint8(bytes1("A")) && c <= uint8(bytes1("F"))) {
            return 10 + c - uint8(bytes1("A"));
        }
        revert("invalid hex char");
    }
}
