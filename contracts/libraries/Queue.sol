// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title Queue
 * @dev FIFO queue for sent bridge messages. Used by {L1FluentBridge} to buffer
 *      outbound message hashes until consumed by the rollup via {L1FluentBridge-popSentMessage}.
 *      Each item records the message hash and the absolute L1 block number by which the
 *      deposit must be accepted by the rollup.
 */
library Queue {
    /**
     * @notice Operation attempted on an empty queue.
     */
    error QueueEmpty();

    /**
     * @notice Index is outside the valid range [front, back).
     */
    error QueueOutOfBounds(uint256 index);

    /**
     * @notice pushFront attempted while the front cursor is at 0 (no room to decrement).
     */
    error QueueUnderflow();

    /**
     * @dev Single queued item: message hash and the absolute acceptance deadline snapshotted on L1.
     */
    struct QueueItem {
        /// @dev Keccak256 hash of the encoded cross-chain message.
        bytes32 value;
        /// @dev Absolute L1 block number by which the deposit must be accepted by the rollup.
        uint256 acceptByBlockNumber;
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
     * @dev Appends `value` to the back of the queue with a snapshotted absolute acceptance deadline.
     */
    function enqueue(QueueStorage storage self, bytes32 value, uint256 acceptByBlockNumber) internal {
        self.data[self.back] = QueueItem({value: value, acceptByBlockNumber: acceptByBlockNumber});
        self.back++;
    }

    /**
     * @dev Writes `value` at position `front - 1` and decrements `front`, using a caller-supplied
     *      absolute acceptance deadline. Used by the rollup to restore deposits that were popped
     *      by a now-reverted batch. Safe as long as only previously-popped items are pushed back:
     *      every {dequeue} increments `front`, so `front > 0` is guaranteed for any item
     *      that was previously dequeued.
     */
    function pushFront(QueueStorage storage self, bytes32 value, uint256 acceptByBlockNumber) internal {
        // Safety: the only legitimate caller restores previously-popped items, so `front`
        // has been incremented at least once per restore. Still guard against underflow
        // defensively — violating this would corrupt the queue cursor.
        require(self.front > 0, QueueUnderflow());
        self.front--;
        // The caller snapshots a fresh absolute acceptance deadline on restore so the depositor
        // is not penalized for rollup corruption.
        self.data[self.front] = QueueItem({value: value, acceptByBlockNumber: acceptByBlockNumber});
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
     * @dev Returns the item at `index` without removing it.
     *      Reverts with {QueueOutOfBounds} if `index` is outside [front, back).
     */
    function peekAt(QueueStorage storage self, uint256 index) internal view returns (QueueItem memory) {
        require(index >= self.front && index < self.back, QueueOutOfBounds(index));
        return self.data[index];
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
