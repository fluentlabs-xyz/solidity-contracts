// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

contract MerkleTreeHarness {
    function calculateMerkleRoot(bytes memory leaves) external pure returns (bytes32) {
        return MerkleTree.calculateMerkleRoot(leaves);
    }

    function verifyMerkleProof(bytes32 root, bytes32 hash, uint256 nonce, bytes memory proof) external pure returns (bool) {
        return MerkleTree.verifyMerkleProof(root, hash, nonce, proof);
    }
}

contract MerkleTreeTest is Test {
    MerkleTreeHarness internal harness;

    function setUp() public {
        harness = new MerkleTreeHarness();
    }

    function test_calculateMerkleRoot_singleLeaf() public view {
        bytes32 leaf = keccak256("leaf");
        bytes memory packed = abi.encodePacked(leaf);
        bytes32 root = harness.calculateMerkleRoot(packed);
        assertEq(root, leaf, "single leaf root should equal the leaf");
    }

    function test_calculateMerkleRoot_twoLeaves() public view {
        bytes32 a = keccak256("a");
        bytes32 b = keccak256("b");
        bytes memory packed = abi.encodePacked(a, b);
        bytes32 root = harness.calculateMerkleRoot(packed);
        bytes32 expected = keccak256(abi.encodePacked(a, b));
        assertEq(root, expected, "two-leaf root mismatch");
    }

    function test_calculateMerkleRoot_oddLeafCount() public view {
        bytes32 a = keccak256("a");
        bytes32 b = keccak256("b");
        bytes32 c = keccak256("c");
        bytes memory packed = abi.encodePacked(a, b, c);
        bytes32 root = harness.calculateMerkleRoot(packed);
        bytes32 ab = keccak256(abi.encodePacked(a, b));
        bytes32 cc = keccak256(abi.encodePacked(c, c));
        bytes32 expected = keccak256(abi.encodePacked(ab, cc));
        assertEq(root, expected, "odd leaf count root mismatch");
    }

    function test_RevertIf_calculateMerkleRoot_emptyInput() public {
        vm.expectRevert(MerkleTree.NoLeavesProvided.selector);
        harness.calculateMerkleRoot("");
    }

    function test_RevertIf_verifyMerkleProof_invalidProofLength() public {
        vm.expectRevert(MerkleTree.InvalidProof.selector);
        harness.verifyMerkleProof(bytes32(0), bytes32(0), 0, new bytes(31));
    }

    function test_verifyMerkleProof_validTwoLeafTree() public view {
        bytes32 a = keccak256("a");
        bytes32 b = keccak256("b");
        bytes32 root = keccak256(abi.encodePacked(a, b));
        assertTrue(harness.verifyMerkleProof(root, a, 0, abi.encodePacked(b)), "proof should be valid");
    }
}
