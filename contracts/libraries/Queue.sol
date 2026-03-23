// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title Queue
 * @dev FIFO queue for sent bridge messages. Used by {L1FluentBridge} to buffer
 *      outbound message hashes until consumed by the rollup via {L1FluentBridge-popSentMessage}.
 *      Each item records the message hash and the L1 block number at enqueue time.
 */
library Queue {
    /**
     * @notice Operation attempted on an empty queue.
     */
    error QueueEmpty();

    /**
     * @dev Single queued item: message hash and the block it was enqueued in.
     */
    struct QueueItem {
        /// @dev Keccak256 hash of the encoded cross-chain message.
        bytes32 value;
        /// @dev L1 block number when the item was enqueued.
        uint256 blockNumber;
    }

    /**
     * @dev Mapping-backed FIFO with front/back cursors.
     */
    struct QueueStorage {
        /// @dev Index-to-item mapping backing the queue.
        mapping(uint256 => QueueItem) data;
        /// @dev Index of the next item to dequeue.
        uint256 front;
        /// @dev Index where the next enqueued item will be stored.
        uint256 back;
    }

    /**
     * @dev Resets queue cursors to zero. Called once during bridge initialization.
     */
    function initialize(QueueStorage storage self) internal {
        self.front = 0;
        self.back = 0;
    }

    /**
     * @dev Appends `value` to the back of the queue, recording the current block number.
     */
    function enqueue(QueueStorage storage self, bytes32 value) internal {
        self.data[self.back] = QueueItem(value, block.number);
        self.back++;
    }

    /**
     * @dev Removes and returns the front item. Reverts with {QueueEmpty} if empty.
     */
    function dequeue(QueueStorage storage self) internal returns (QueueItem memory) {
        require(!isEmpty(self), QueueEmpty());
        QueueItem memory item = self.data[self.front];
        delete self.data[self.front];
        self.front++;
        return item;
    }

    /**
     * @dev Returns the front item without removing it. Reverts with {QueueEmpty} if empty.
     */
    function peek(QueueStorage storage self) internal view returns (QueueItem memory) {
        require(!isEmpty(self), QueueEmpty());
        return self.data[self.front];
    }

    /**
     * @dev Returns true when the queue contains no elements.
     */
    function isEmpty(QueueStorage storage self) internal view returns (bool) {
        return self.back == self.front;
    }

    /**
     * @dev Returns the number of elements currently in the queue.
     */
    function size(QueueStorage storage self) internal view returns (uint256) {
        return self.back - self.front;
    }
}
