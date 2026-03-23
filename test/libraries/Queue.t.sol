// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Queue} from "../../contracts/libraries/Queue.sol";

contract QueueHarness {
    Queue.QueueStorage internal _q;

    constructor() {
        Queue.initialize(_q);
    }

    function enqueue(bytes32 value) external {
        Queue.enqueue(_q, value);
    }

    function dequeue() external returns (Queue.QueueItem memory) {
        return Queue.dequeue(_q);
    }

    function peek() external view returns (Queue.QueueItem memory) {
        return Queue.peek(_q);
    }

    function isEmpty() external view returns (bool) {
        return Queue.isEmpty(_q);
    }

    function size() external view returns (uint256) {
        return Queue.size(_q);
    }
}

contract QueueTest is Test {
    QueueHarness internal q;

    function setUp() public {
        q = new QueueHarness();
    }

    function test_peek_returnsFrontWithoutRemoving() public {
        q.enqueue(bytes32(uint256(1)));
        q.enqueue(bytes32(uint256(2)));

        Queue.QueueItem memory item = q.peek();
        assertEq(item.value, bytes32(uint256(1)), "peek should return front");
        assertEq(q.size(), 2, "peek should not remove");
    }

    function test_RevertIf_peek_emptyQueue() public {
        vm.expectRevert(Queue.QueueEmpty.selector);
        q.peek();
    }

    function test_RevertIf_dequeue_emptyQueue() public {
        vm.expectRevert(Queue.QueueEmpty.selector);
        q.dequeue();
    }
}
