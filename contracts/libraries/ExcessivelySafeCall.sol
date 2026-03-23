// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title ExcessivelySafeCall
 * @notice A library for making safe external calls that protect against return bombs.
 * @dev This library provides functions to make external calls with a maximum return data size limit.
 */
library ExcessivelySafeCall {
    /// @dev Maximum bytes copied from returndata to prevent return-bomb attacks.
    uint256 private constant _MAX_RETURN_SIZE = 1024;

    /**
     * @notice Makes an external call with a maximum return data size limit.
     * @param target The address to call.
     * @param value The amount of ETH to send with the call.
     * @param data The calldata to send.
     * @param gasLimit The maximum gas to forward to the external call.
     * @return success Whether the call was successful.
     * @return returnData The return data, truncated to _MAX_RETURN_SIZE if necessary.
     */
    function excessivelySafeCall(
        address target,
        uint256 value,
        bytes memory data,
        uint256 gasLimit
    ) internal returns (bool success, bytes memory returnData) {
        // set up for assembly call
        uint256 toCopy;
        bool callSuccess;
        bytes memory result = new bytes(_MAX_RETURN_SIZE);
        // we call via assembly to avoid memcopying a very large returndata
        // returned by a malicious contract
        assembly ("memory-safe") {
            callSuccess := call(
                gasLimit, // gas
                target, // recipient
                value, // ether value
                add(data, 0x20), // inloc: skip 32-byte length prefix of bytes array
                mload(data), // inlen: first word of bytes array is its length
                0, // outloc: do not auto-copy returndata (return-bomb protection)
                0 // outlen: do not auto-copy returndata (return-bomb protection)
            )
            // limit our copy to _MAX_RETURN_SIZE bytes
            toCopy := returndatasize()
            if gt(toCopy, _MAX_RETURN_SIZE) {
                toCopy := _MAX_RETURN_SIZE
            }
            // store the length of the copied bytes
            mstore(result, toCopy)
            // copy the bytes from returndata[0:toCopy]
            returndatacopy(add(result, 0x20), 0, toCopy)
        }
        return (callSuccess, result);
    }
}
