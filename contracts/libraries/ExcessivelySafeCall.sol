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
     * @param _target The address to call.
     * @param _value The amount of ETH to send with the call.
     * @param _calldata The calldata to send.
     * @return success Whether the call was successful.
     * @return returnData The return data, truncated to _MAX_RETURN_SIZE if necessary.
     */
    function excessivelySafeCall(
        address _target,
        uint256 _value,
        bytes memory _calldata
    ) internal returns (bool success, bytes memory returnData) {
        // set up for assembly call
        uint256 _toCopy;
        bool _success;
        bytes memory _returnData = new bytes(_MAX_RETURN_SIZE);
        // dispatch message to recipient
        // by assembly calling "handle" function
        // we call via assembly to avoid memcopying a very large returndata
        // returned by a malicious contract
        assembly {
            _success := call(
                gas(), // gas
                _target, // recipient
                _value, // ether value
                add(_calldata, 0x20), // inloc
                mload(_calldata), // inlen
                0, // outloc
                0 // outlen
            )
        // limit our copy to 256 bytes
            _toCopy := returndatasize()
            if gt(_toCopy, _MAX_RETURN_SIZE) {
                _toCopy := _MAX_RETURN_SIZE
            }
        // Store the length of the copied bytes
            mstore(_returnData, _toCopy)
        // copy the bytes from returndata[0:_toCopy]
            returndatacopy(add(_returnData, 0x20), 0, _toCopy)
        }
        return (_success, _returnData);

    }
} 