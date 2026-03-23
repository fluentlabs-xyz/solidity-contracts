// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Heap} from "../../contracts/libraries/Heap.sol";

contract HeapHarness {
    using Heap for Heap.HeapStorage;

    Heap.HeapStorage internal heap;
    mapping(bytes32 => uint256) internal challengeDeadline;
    mapping(bytes32 => uint256) internal commitmentQueueIndex;

    function push(bytes32 value, uint256 priority) external {
        challengeDeadline[value] = priority;
        heap.push(challengeDeadline, commitmentQueueIndex, value);
    }

    function pop() external returns (bytes32 value, uint256 priority) {
        value = heap.pop(challengeDeadline, commitmentQueueIndex);
        priority = challengeDeadline[value];
    }

    function peek() external view returns (bytes32 value, uint256 priority) {
        value = heap.peek();
        priority = challengeDeadline[value];
    }

    function remove(bytes32 value) external returns (bool removed) {
        return heap.remove(challengeDeadline, commitmentQueueIndex, value);
    }

    function contains(bytes32 value) external view returns (bool) {
        return commitmentQueueIndex[value] != 0;
    }

    function indexOf(bytes32 value) external view returns (uint256) {
        return commitmentQueueIndex[value];
    }

    function at(uint256 index) external view returns (bytes32 value, uint256 priority) {
        value = heap.at(index);
        priority = challengeDeadline[value];
    }

    function length() external view returns (uint256) {
        return heap.length();
    }

    function isEmpty() external view returns (bool) {
        return heap.isEmpty();
    }
}

contract HeapTest is Test {
    HeapHarness internal harness;

    bytes32 internal constant A = keccak256("A");
    bytes32 internal constant B = keccak256("B");
    bytes32 internal constant C = keccak256("C");
    bytes32 internal constant D = keccak256("D");

    function setUp() public {
        harness = new HeapHarness();
    }

    function test_pushAndPeekReturnsMinPriority() public {
        harness.push(A, 30);
        harness.push(B, 10);
        harness.push(C, 20);

        (bytes32 value, uint256 priority) = harness.peek();
        assertEq(value, B);
        assertEq(priority, 10);
        assertEq(harness.length(), 3);
    }

    function test_popReturnsAscendingPriorities() public {
        harness.push(A, 30);
        harness.push(B, 10);
        harness.push(C, 20);
        harness.push(D, 5);

        (bytes32 v0, uint256 p0) = harness.pop();
        (bytes32 v1, uint256 p1) = harness.pop();
        (bytes32 v2, uint256 p2) = harness.pop();
        (bytes32 v3, uint256 p3) = harness.pop();

        assertEq(v0, D);
        assertEq(p0, 5);
        assertEq(v1, B);
        assertEq(p1, 10);
        assertEq(v2, C);
        assertEq(p2, 20);
        assertEq(v3, A);
        assertEq(p3, 30);
        assertTrue(harness.isEmpty());
    }

    function test_removeByValueKeepsHeapValid() public {
        harness.push(A, 30);
        harness.push(B, 10);
        harness.push(C, 20);
        harness.push(D, 5);

        bool removed = harness.remove(B);
        assertTrue(removed);
        assertFalse(harness.contains(B));
        assertEq(harness.length(), 3);

        (bytes32 v0, uint256 p0) = harness.pop();
        (bytes32 v1, uint256 p1) = harness.pop();
        (bytes32 v2, uint256 p2) = harness.pop();

        assertEq(v0, D);
        assertEq(p0, 5);
        assertEq(v1, C);
        assertEq(p1, 20);
        assertEq(v2, A);
        assertEq(p2, 30);
    }

    function test_removeMissingReturnsFalse() public {
        harness.push(A, 1);
        assertFalse(harness.remove(B));
        assertEq(harness.length(), 1);
    }

    function test_pushDuplicateValueReverts() public {
        harness.push(A, 100);
        vm.expectRevert(abi.encodeWithSelector(Heap.HeapAlreadyExists.selector, A));
        harness.push(A, 200);
    }

    function test_popEmptyReverts() public {
        vm.expectRevert(Heap.HeapEmpty.selector);
        harness.pop();
    }

    function test_peekEmptyReverts() public {
        vm.expectRevert(Heap.HeapEmpty.selector);
        harness.peek();
    }

    function test_corruptionCheckUsesSmallestBatchIdFromRoot() public {
        bytes32 c2 = keccak256("batch-2");
        bytes32 c4 = keccak256("batch-4");
        bytes32 c10 = keccak256("batch-10");
        bytes32 c1 = keccak256("batch-1");

        // Insert in order: [2, 4, 10, 1]
        harness.push(c2, 2);
        harness.push(c4, 4);
        harness.push(c10, 10);
        harness.push(c1, 1);

        // heap[0] (peek) must point to the earliest batch id => 1
        (bytes32 rootCommitment, uint256 rootBatchId) = harness.peek();
        assertEq(rootCommitment, c1);
        assertEq(rootBatchId, 1);
    }
}
