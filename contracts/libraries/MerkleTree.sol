// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title MerkleTree
 * @dev Merkle root computation from packed byte arrays and inclusion proof verification.
 *      Odd-count layers are handled by duplicating the last leaf. The input buffer
 *      `_leafs` is modified in place during {calculateMerkleRoot}.
 */
library MerkleTree {
    /**
     * @notice Merkle tree construction requires at least one leaf.
     */
    error NoLeavesProvided();

    /**
     * @notice Proof length is not a multiple of 32 bytes.
     */
    error InvalidProof();

    /**
     * @dev Merkle inclusion proof: leaf index plus packed sibling hashes.
     */
    struct MerkleProof {
        /// @dev Leaf index in the tree; determines left/right placement at each level.
        uint256 nonce;
        /// @dev Packed array of 32-byte sibling hashes from leaf to root.
        bytes proof;
    }

    /**
     * @dev Computes a Merkle root from a packed byte array of 32-byte leaves.
     *      WARNING: mutates `_leafs` in place -- callers must not reuse the buffer.
     */
    function calculateMerkleRoot(bytes memory _leafs) internal pure returns (bytes32) {
        // Each leaf is 32 bytes; determine the number of leaves from the buffer length
        uint256 count = _leafs.length / 32;
        // At least one leaf is required to form a valid tree
        require(count != 0, NoLeavesProvided());

        // Reduce layers iteratively: each pass halves the number of nodes
        // by hashing adjacent pairs, writing results back in-place
        while (count > 0) {
            bytes32 hash;
            bytes32 left;
            bytes32 right;
            // Hash each consecutive pair of leaves/nodes
            for (uint256 i = 0; i < count / 2; i++) {
                assembly ("memory-safe") {
                    // Load left child (even index) and right child (odd index)
                    left := mload(add(add(_leafs, 32), mul(mul(i, 2), 32)))
                    right := mload(add(add(_leafs, 32), mul(add(mul(i, 2), 1), 32)))
                }
                hash = _efficientHash(left, right);
                assembly ("memory-safe") {
                    // Write the parent hash at position i, compacting the layer
                    mstore(add(add(_leafs, 32), mul(i, 32)), hash)
                }
            }

            // Handle an odd number of nodes by duplicating the last one
            // This ensures every layer has an even count for pair-wise hashing
            if (count % 2 == 1 && count > 1) {
                assembly ("memory-safe") {
                    // Load the unpaired last leaf
                    left := mload(add(add(_leafs, 32), mul(sub(count, 1), 32)))
                }
                // Self-hash the lone leaf to produce its parent
                hash = _efficientHash(left, left);
                assembly ("memory-safe") {
                    // Place the result at the correct half-layer position
                    mstore(add(add(_leafs, 32), mul(div(sub(count, 1), 2), 32)), hash)
                }
                // Account for the duplicated node so the next division is correct
                count += 1;
            }

            // Move up one level: the number of nodes halves
            count = count / 2;
        }

        // After all reductions, the single remaining hash is the Merkle root
        // It sits at offset 32 (skip the length prefix) of the original buffer
        bytes32 root;
        assembly ("memory-safe") {
            root := mload(add(_leafs, 32))
        }
        return root;
    }

    /**
     * @dev Verifies a Merkle inclusion proof by reconstructing the root from
     *      `_hash` + proof elements. The `_nonce` determines left/right ordering
     *      at each level (even = left, odd = right).
     * @return True if the reconstructed root matches `_root`.
     */
    function verifyMerkleProof(bytes32 _root, bytes32 _hash, uint256 _nonce, bytes memory _proof)
        internal
        pure
        returns (bool)
    {
        // Proof must be a sequence of 32-byte sibling hashes
        require(_proof.length % 32 == 0, InvalidProof());
        // Number of levels in the proof corresponds to the tree depth
        uint256 _length = _proof.length / 32;

        // Walk from the leaf up to the root, hashing with each sibling
        for (uint256 i = 0; i < _length; i++) {
            bytes32 item;
            assembly ("memory-safe") {
                // Load the sibling hash for this level from the packed proof
                item := mload(add(add(_proof, 32), mul(i, 32)))
            }
            // The nonce's parity at each level determines whether the current
            // hash is the left or right child — matching the tree construction order
            if (_nonce % 2 == 0) {
                // Current hash is the left child, sibling goes on the right
                _hash = _efficientHash(_hash, item);
            } else {
                // Current hash is the right child, sibling goes on the left
                _hash = _efficientHash(item, _hash);
            }
            // Shift the nonce right to get the parent's position at the next level
            _nonce /= 2;
        }
        // If the reconstructed root matches, the leaf is included in the tree
        return _hash == _root;
    }

    /**
     * @dev Gas-efficient keccak256(a || b) using Solidity scratch space (0x00-0x3f).
     */
    function _efficientHash(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        assembly ("memory-safe") {
            // Uses scratch space (0x00-0x3f) -- safe in pure functions
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }
}
