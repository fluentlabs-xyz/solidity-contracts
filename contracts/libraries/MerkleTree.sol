// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

library MerkleTree {
    /// @notice Merkle tree construction requires at least one leaf.
    error NoLeavesProvided();

    /// @notice Proof length is not a multiple of 32 bytes.
    error InvalidProof();

    /// @notice Structure containing Merkle proof details.
    struct MerkleProof {
        uint256 nonce;
        bytes proof;
    }

    /// @notice Computes a Merkle root from a packed byte array of 32-byte leaves.
    function calculateMerkleRoot(bytes memory _leafs) internal pure returns (bytes32) {
        uint256 count = _leafs.length / 32;
        if (count == 0) revert NoLeavesProvided();

        while (count > 0) {
            bytes32 hash;
            bytes32 left;
            bytes32 right;
            for (uint256 i = 0; i < count / 2; i++) {
                assembly ("memory-safe") {
                    left := mload(add(add(_leafs, 32), mul(mul(i, 2), 32)))
                    right := mload(add(add(_leafs, 32), mul(add(mul(i, 2), 1), 32)))
                }
                hash = _efficientHash(left, right);
                assembly ("memory-safe") {
                    mstore(add(add(_leafs, 32), mul(i, 32)), hash)
                }
            }

            if (count % 2 == 1 && count > 1) {
                assembly ("memory-safe") {
                    left := mload(add(add(_leafs, 32), mul(sub(count, 1), 32)))
                }
                hash = _efficientHash(left, left);
                assembly ("memory-safe") {
                    mstore(add(add(_leafs, 32), mul(div(sub(count, 1), 2), 32)), hash)
                }
                count += 1;
            }

            count = count / 2;
        }

        bytes32 root;
        assembly ("memory-safe") {
            root := mload(add(_leafs, 32))
        }
        return root;
    }

    function verifyMerkleProof(bytes32 _root, bytes32 _hash, uint256 _nonce, bytes memory _proof)
        internal
        pure
        returns (bool)
    {
        require(_proof.length % 32 == 0, InvalidProof());
        uint256 _length = _proof.length / 32;

        for (uint256 i = 0; i < _length; i++) {
            bytes32 item;
            assembly ("memory-safe") {
                item := mload(add(add(_proof, 32), mul(i, 32)))
            }
            if (_nonce % 2 == 0) {
                _hash = _efficientHash(_hash, item);
            } else {
                _hash = _efficientHash(item, _hash);
            }
            _nonce /= 2;
        }
        return _hash == _root;
    }

    function _efficientHash(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }
}
