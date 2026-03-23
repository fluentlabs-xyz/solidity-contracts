// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title Heap
 * @dev Min-heap ordered by external challenge deadline. Used by {Rollup} to track
 *      the challenge queue so the oldest-deadline challenge is checkable in O(1).
 *      Elements are commitment hashes; ordering determined by the caller-supplied
 *      `challengeDeadline` mapping. Uses 1-based indexing in `commitmentQueueIndex`
 *      so that 0 denotes "not in heap."
 */
library Heap {
    /**
     * @notice Attempted operation on an empty heap.
     */
    error HeapEmpty();

    /**
     * @notice Commitment hash is already present in the heap.
     */
    error HeapAlreadyExists(bytes32 value);

    /**
     * @dev Binary min-heap backed by a mapping and a size counter.
     */
    struct HeapStorage {
        /// @dev Position index (0-based) to commitment hash.
        mapping(uint256 => bytes32) data;
        /// @dev Current number of elements in the heap.
        uint256 size;
    }

    /**
     * @dev Inserts `commitmentHash` and restores heap order.
     *      Reverts with {HeapAlreadyExists} if already present.
     */
    function push(
        HeapStorage storage self,
        mapping(bytes32 => uint256) storage challengeDeadline,
        mapping(bytes32 => uint256) storage commitmentQueueIndex,
        bytes32 commitmentHash
    ) internal {
        // 1-based index: a non-zero value means the element is already in the heap
        if (commitmentQueueIndex[commitmentHash] != 0) {
            revert HeapAlreadyExists(commitmentHash);
        }

        // Place the new element at the end of the array (next available slot)
        // Appending preserves existing heap structure — only siftUp is needed after
        uint256 i = self.size;
        self.data[i] = commitmentHash;
        self.size = i + 1;
        // Store 1-based position so 0 can serve as the "absent" sentinel
        commitmentQueueIndex[commitmentHash] = i + 1;
        // Bubble up to restore the min-heap ordering by challenge deadline
        _siftUp(self, challengeDeadline, commitmentQueueIndex, i);
    }

    /**
     * @dev Removes and returns the root element (smallest deadline).
     *      Reverts with {HeapEmpty} if the heap has no elements.
     */
    function pop(
        HeapStorage storage self,
        mapping(bytes32 => uint256) storage challengeDeadline,
        mapping(bytes32 => uint256) storage commitmentQueueIndex
    ) internal returns (bytes32 top) {
        // Empty heap means no challenges to resolve — revert to signal misuse
        require(self.size != 0, HeapEmpty());
        // The root (index 0) always holds the element with the smallest deadline
        top = self.data[0];
        // Remove root and re-heapify so the next-smallest deadline becomes root
        _removeAt(self, challengeDeadline, commitmentQueueIndex, 0);
    }

    /**
     * @dev Removes `commitmentHash` by its tracked index.
     *      Returns false if not found, true if successfully removed.
     */
    function remove(
        HeapStorage storage self,
        mapping(bytes32 => uint256) storage challengeDeadline,
        mapping(bytes32 => uint256) storage commitmentQueueIndex,
        bytes32 commitmentHash
    ) internal returns (bool) {
        // Look up the 1-based position; 0 means the element is not in the heap
        uint256 indexPlusOne = commitmentQueueIndex[commitmentHash];
        if (indexPlusOne == 0) {
            // Element not found — nothing to remove
            return false;
        }

        // Convert from 1-based tracking to 0-based array index and remove
        _removeAt(self, challengeDeadline, commitmentQueueIndex, indexPlusOne - 1);
        return true;
    }

    /**
     * @dev Returns the root element without removing it.
     *      Reverts with {HeapEmpty} if the heap has no elements.
     */
    function peek(HeapStorage storage self) internal view returns (bytes32) {
        require(self.size != 0, HeapEmpty());
        // Root is always at index 0 — the element with the smallest challenge deadline
        return self.data[0];
    }

    /**
     * @dev Returns true when the heap contains no elements.
     */
    function isEmpty(HeapStorage storage self) internal view returns (bool) {
        // Used by the rollup to skip corruption checks when no challenges exist
        return self.size == 0;
    }

    /**
     * @dev Returns the number of elements currently in the heap.
     */
    function length(HeapStorage storage self) internal view returns (uint256) {
        // Returns the count of active challenges in the heap
        return self.size;
    }

    /**
     * @dev Returns the element at position `index`.
     *      No bounds check -- caller must ensure `index < size`.
     */
    function at(HeapStorage storage self, uint256 index) internal view returns (bytes32) {
        // Direct access by 0-based position — caller is responsible for bounds checking
        return self.data[index];
    }

    /**
     * @dev Removes element at position `i`: swaps with the last element, shrinks,
     *      then re-heapifies with sift-down followed by sift-up.
     */
    function _removeAt(
        HeapStorage storage self,
        mapping(bytes32 => uint256) storage challengeDeadline,
        mapping(bytes32 => uint256) storage commitmentQueueIndex,
        uint256 i
    ) private {
        // last is the index of the final element; used for swap-and-shrink
        uint256 last = self.size - 1;
        bytes32 removedHash = self.data[i];
        // Clear the index so the removed element is no longer considered "in heap"
        delete commitmentQueueIndex[removedHash];

        // Special case: removing the tail requires no re-heapification
        // because no element changes position relative to its parent/children
        if (i == last) {
            delete self.data[last];
            self.size = last;
            return;
        }

        // Move the last element into the vacated slot, then shrink the array
        bytes32 lastHash = self.data[last];
        // Clean up the old last slot to reclaim gas (storage refund)
        delete self.data[last];
        // Place the former tail element into the gap left by the removed element
        self.data[i] = lastHash;
        // Update the moved element's tracked position (1-based)
        commitmentQueueIndex[lastHash] = i + 1;
        // Shrink the logical array size by one
        self.size = last;

        // The moved element may violate the heap invariant in either direction,
        // so we sift down first (cheaper path if replacing root), then sift up
        _siftDown(self, challengeDeadline, commitmentQueueIndex, i);
        _siftUp(self, challengeDeadline, commitmentQueueIndex, i);
    }

    /**
     * @dev Standard min-heap sift-down from position `i`.
     */
    function _siftDown(
        HeapStorage storage self,
        mapping(bytes32 => uint256) storage challengeDeadline,
        mapping(bytes32 => uint256) storage commitmentQueueIndex,
        uint256 i
    ) private {
        // Cache size to avoid repeated SLOAD in the loop
        uint256 size = self.size;
        while (true) {
            // Assume current position satisfies the invariant until proven otherwise
            uint256 smallest = i;
            // Binary heap child indices: left = 2i+1, right = 2i+2
            uint256 left = 2 * i + 1;
            uint256 right = left + 1;

            // Check if left child has a smaller deadline than the current smallest
            if (left < size && challengeDeadline[self.data[left]] < challengeDeadline[self.data[smallest]]) {
                smallest = left;
            }
            // Check right child against the current candidate
            if (right < size && challengeDeadline[self.data[right]] < challengeDeadline[self.data[smallest]]) {
                smallest = right;
            }
            // If neither child is smaller, the min-heap invariant is restored
            if (smallest == i) break;

            // Swap with the smaller child and continue down the tree
            _swap(self, commitmentQueueIndex, smallest, i);
            i = smallest;
        }
    }

    /**
     * @dev Standard min-heap sift-up from position `i`.
     */
    function _siftUp(
        HeapStorage storage self,
        mapping(bytes32 => uint256) storage challengeDeadline,
        mapping(bytes32 => uint256) storage commitmentQueueIndex,
        uint256 i
    ) private {
        // Walk up from position i toward the root, swapping with parents that
        // have a larger deadline to maintain the min-heap property
        while (i > 0) {
            // Parent of node i in a 0-based binary heap
            uint256 parent = (i - 1) / 2;
            // Stop when the parent's deadline is not greater — invariant satisfied
            if (challengeDeadline[self.data[parent]] <= challengeDeadline[self.data[i]]) break;

            // Parent has a later deadline — swap and continue upward
            _swap(self, commitmentQueueIndex, parent, i);
            i = parent;
        }
    }

    /**
     * @dev Swaps elements at positions `a` and `b`, updating their 1-based index tracking.
     */
    function _swap(HeapStorage storage self, mapping(bytes32 => uint256) storage commitmentQueueIndex, uint256 a, uint256 b) private {
        // Classic three-variable swap of the commitment hashes
        bytes32 tmp = self.data[a];
        self.data[a] = self.data[b];
        self.data[b] = tmp;

        // Keep the index mapping in sync so remove() can locate elements in O(1)
        commitmentQueueIndex[self.data[a]] = a + 1;
        commitmentQueueIndex[self.data[b]] = b + 1;
    }
}
