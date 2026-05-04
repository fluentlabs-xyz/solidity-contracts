// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IncrementalMerkleTree} from "../../contracts/libraries/IncrementalMerkleTree.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

contract IncrementalMerkleTreeHarness {
    using IncrementalMerkleTree for IncrementalMerkleTree.Tree;
    IncrementalMerkleTree.Tree internal tree;

    function append(bytes32 leaf) external {
        tree.append(leaf);
    }

    function drain() external view returns (bytes32) {
        return tree.drain();
    }
}

contract IncrementalMerkleTreeTest is Test {
    IncrementalMerkleTreeHarness internal harness;

    function setUp() public {
        harness = new IncrementalMerkleTreeHarness();
    }

    // ============ Helpers ============

    function _reference(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes memory packed = new bytes(leaves.length * 32);
        for (uint256 i = 0; i < leaves.length; ++i) {
            bytes32 h = leaves[i];
            assembly {
                mstore(add(add(packed, 32), mul(i, 32)), h)
            }
        }
        return MerkleTree.calculateMerkleRoot(packed);
    }

    function _streamAndDrain(bytes32[] memory leaves) internal returns (bytes32) {
        for (uint256 i = 0; i < leaves.length; ++i) {
            harness.append(leaves[i]);
        }
        return harness.drain();
    }

    function _makeLeaves(uint256 n) internal pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            leaves[i] = keccak256(abi.encode("leaf", i));
        }
    }

    // ============ Fixed-N equivalence tests ============

    function test_drain_matchesReference_singleLeaf() public {
        bytes32[] memory leaves = _makeLeaves(1);
        assertEq(_streamAndDrain(leaves), _reference(leaves), "N=1 root mismatch");
    }

    function test_drain_matchesReference_twoLeaves() public {
        bytes32[] memory leaves = _makeLeaves(2);
        assertEq(_streamAndDrain(leaves), _reference(leaves), "N=2 root mismatch");
    }

    function test_drain_matchesReference_threeLeaves() public {
        bytes32[] memory leaves = _makeLeaves(3);
        assertEq(_streamAndDrain(leaves), _reference(leaves), "N=3 root mismatch");
    }

    function test_drain_matchesReference_fiveLeaves() public {
        bytes32[] memory leaves = _makeLeaves(5);
        assertEq(_streamAndDrain(leaves), _reference(leaves), "N=5 root mismatch");
    }

    function test_drain_matchesReference_sevenLeaves() public {
        bytes32[] memory leaves = _makeLeaves(7);
        assertEq(_streamAndDrain(leaves), _reference(leaves), "N=7 root mismatch");
    }

    function test_drain_matchesReference_eightLeaves() public {
        bytes32[] memory leaves = _makeLeaves(8);
        assertEq(_streamAndDrain(leaves), _reference(leaves), "N=8 root mismatch");
    }

    function test_drain_matchesReference_seventeenLeaves() public {
        bytes32[] memory leaves = _makeLeaves(17);
        assertEq(_streamAndDrain(leaves), _reference(leaves), "N=17 root mismatch");
    }

    function test_drain_matchesReference_oneThousandTwentyThreeLeaves() public {
        bytes32[] memory leaves = _makeLeaves(1023);
        assertEq(_streamAndDrain(leaves), _reference(leaves), "N=1023 root mismatch");
    }

    function test_drain_matchesReference_oneThousandTwentyFourLeaves() public {
        bytes32[] memory leaves = _makeLeaves(1024);
        assertEq(_streamAndDrain(leaves), _reference(leaves), "N=1024 root mismatch");
    }

    function test_drain_matchesReference_oneThousandTwentyFiveLeaves() public {
        bytes32[] memory leaves = _makeLeaves(1025);
        assertEq(_streamAndDrain(leaves), _reference(leaves), "N=1025 root mismatch");
    }

    // ============ Fuzz equivalence ============

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_drain_matchesReference(uint16 nRaw, uint256 seed) public {
        uint256 n = bound(uint256(nRaw), 1, 2048);
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            leaves[i] = keccak256(abi.encode(seed, i));
        }
        assertEq(_streamAndDrain(leaves), _reference(leaves), "fuzz root mismatch");
    }

    // ============ Reverts ============

    function test_RevertIf_drain_emptyTree() public {
        vm.expectRevert(IncrementalMerkleTree.NoLeaves.selector);
        harness.drain();
    }
}
