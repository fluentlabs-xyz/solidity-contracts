// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

/**
 * @notice Test helper: `withdrawalRoot` is the Merkle root of message hashes committed for an L2 block.
 * @dev Each leaf should be the real `messageHash` from `SentMessage` (L2→L1) or from the L2 timeout
 *      path that emits `RollbackMessage` — i.e. `keccak256(_encodeMessage(...))` matching the bridge.
 *      Use {leavesSingleton} when the block has one withdrawal/rollback; pass a 2+ element array (in L2
 *      block order) when tests produce multiple real messages in the same block.
 */
library WithdrawalMerkle {
    /// @dev One message in the block: `withdrawalRoot == messageHash`, empty Merkle proof.
    function leavesSingleton(bytes32 messageHash) internal pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](1);
        leaves[0] = messageHash;
    }

    function withdrawalRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        uint256 n = leaves.length;
        if (n == 1) {
            return leaves[0];
        }
        if (n == 2) {
            return MerkleTree.calculateMerkleRoot(abi.encodePacked(leaves[0], leaves[1]));
        }
        revert("WithdrawalMerkle: use 1 or 2 leaves in tests");
    }

    /// @dev Merkle proof compatible with {MerkleTree.verifyMerkleProof} for 1–2 leaves only.
    function proofForLeaf(bytes32[] memory leaves, uint256 leafIndex) internal pure returns (MerkleTree.MerkleProof memory) {
        require(leafIndex < leaves.length, "WithdrawalMerkle: leaf index");
        uint256 n = leaves.length;
        if (n == 1) {
            return MerkleTree.MerkleProof({nonce: 0, proof: ""});
        }
        if (n == 2) {
            if (leafIndex == 0) {
                return MerkleTree.MerkleProof({nonce: 0, proof: abi.encodePacked(leaves[1])});
            }
            return MerkleTree.MerkleProof({nonce: 1, proof: abi.encodePacked(leaves[0])});
        }
        revert("WithdrawalMerkle: use 1 or 2 leaves in tests");
    }
}
