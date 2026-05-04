// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IncrementalMerkleTree
 * @author Fluent Labs
 * @dev Streaming binary Merkle tree that produces the same root as
 *      {MerkleTree-calculateMerkleRoot} for the same leaf sequence. Maintains
 *      a stack of per-level peaks (Merkle Mountain Range style) so a tree of
 *      N leaves can be assembled across many transactions.
 *
 *      Targets the duplicate-orphan layering used by
 *      {MerkleTree-calculateMerkleRoot}: at each layer with an odd count > 1
 *      the lone last node self-hashes to form its parent. The drain step
 *      reproduces this by promoting the lower-level peaks via self-hash up to
 *      the next-higher peak's level before merging.
 */
library IncrementalMerkleTree {
    /**
     * @notice Tree depth would exceed the static peaks array.
     */
    error LevelsExceeded(uint256 level);

    /**
     * @notice Drain called on an empty tree.
     */
    error NoLeaves();

    /**
     * @dev Maximum levels supported. Covers 2^24 = ~16M leaves — well above the
     *      ~100k worst-case practical maximum.
     */
    uint256 internal constant MAX_LEVELS = 24;

    /**
     * @dev Streaming Merkle tree state.
     */
    struct Tree {
        /// @dev Bitmap of populated levels (LSB = level 0).
        uint32 peakLevelsBitmap;
        /// @dev Peaks stored at their level. Slots above the active levels stay zero.
        bytes32[MAX_LEVELS] peakAtLevel;
    }

    /**
     * @dev Append a leaf. Carries up while same-level peaks already exist —
     *      each carry merges two same-level subtrees into a parent at level+1.
     */
    function append(Tree storage tree, bytes32 leaf) public {
        uint256 bitmap = uint256(tree.peakLevelsBitmap);
        bytes32 carry = leaf;
        uint256 level = 0;
        while ((bitmap >> level) & 1 == 1) {
            carry = _hash(tree.peakAtLevel[level], carry);
            bitmap ^= (1 << level);
            unchecked {
                level++;
            }
        }
        require(level < MAX_LEVELS, LevelsExceeded(level));
        tree.peakAtLevel[level] = carry;
        tree.peakLevelsBitmap = uint32(bitmap | (1 << level));
    }

    /**
     * @dev Compute the final root from the current peaks. Walks set bits from
     *      lowest to highest, promoting the running accumulator via self-hash
     *      until its level matches the next peak, then merging.
     *      Read-only — caller is responsible for `delete`-ing the tree afterward.
     */
    function drain(Tree storage tree) public view returns (bytes32) {
        uint256 bitmap = uint256(tree.peakLevelsBitmap);
        require(bitmap != 0, NoLeaves());

        bytes32 acc;
        uint256 accLevel;
        bool initialized = false;

        for (uint256 level = 0; level < MAX_LEVELS; ++level) {
            if ((bitmap >> level) & 1 == 0) continue;
            if (!initialized) {
                acc = tree.peakAtLevel[level];
                accLevel = level;
                initialized = true;
            } else {
                while (accLevel < level) {
                    acc = _hash(acc, acc);
                    unchecked {
                        accLevel++;
                    }
                }
                acc = _hash(tree.peakAtLevel[level], acc);
                accLevel = level + 1;
            }
        }
        return acc;
    }

    /**
     * @dev Gas-efficient keccak256(a || b) using Solidity scratch space (0x00-0x3f).
     */
    function _hash(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }
}
