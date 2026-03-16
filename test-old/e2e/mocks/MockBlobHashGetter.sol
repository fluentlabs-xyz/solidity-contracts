// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockBlobHashGetter {
    bytes32 internal blobHash;

    function setBlobHash(bytes32 value) external {
        blobHash = value;
    }

    fallback() external {
        bytes32 value = blobHash;
        assembly {
            mstore(0x00, value)
            return(0x00, 0x20)
        }
    }
}
