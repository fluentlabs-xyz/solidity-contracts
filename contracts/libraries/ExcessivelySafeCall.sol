// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ExcessivelySafeCall
 * @notice A library for making safe external calls that protect against return bombs.
 * @dev This library provides functions to make external calls with a maximum return data size limit.
 */
library ExcessivelySafeCall {
    uint256 private constant _MAX_RETURN_SIZE = 1024;

    /**
     * @notice Makes an external call with a maximum return data size limit.
     * @param target The address to call.
     * @param value The amount of ETH to send with the call.
     * @param data The calldata to send.
     * @return success Whether the call was successful.
     * @return returnData The return data, truncated to _MAX_RETURN_SIZE if necessary.
     */
    function excessivelySafeCall(
        address target,
        uint256 value,
        bytes memory data
    ) internal returns (bool success, bytes memory returnData) {
        // solhint-disable-next-line avoid-low-level-calls
        (success, returnData) = target.call{value: value}(data);
        
        if (success && returnData.length > _MAX_RETURN_SIZE) {
            // Truncate the return data to the maximum allowed size
            assembly {
                mstore(returnData, _MAX_RETURN_SIZE)
            }
        }
    }
} 