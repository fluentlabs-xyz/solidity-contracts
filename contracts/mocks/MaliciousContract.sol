// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title MaliciousContract
 * @notice A contract that returns a large amount of data to test return bomb protection.
 * @dev This contract is used only for testing purposes.
 */
contract MaliciousContract {
    /**
     * @notice Returns a large amount of data (2KB) to test return bomb protection.
     * @return A large bytes array.
     */
    function maliciousFunction() internal pure returns (bytes memory) {
        // Create a 2KB array of bytes
        bytes memory largeData = new bytes(2048);
        // Fill it with some data
        for (uint256 i = 0; i < 2048; i++) {
            largeData[i] = bytes1(uint8(i % 256));
        }
        return largeData;
    }

    /**
     * @notice Fallback function that returns a large amount of data.
     */
    fallback(bytes calldata) external returns (bytes memory) {
        return maliciousFunction();
    }
}
