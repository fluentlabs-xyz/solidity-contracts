// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

library Heap {
    error HeapEmpty();
    error HeapAlreadyExists(bytes32 value);

    struct HeapStorage {
        mapping(uint256 => bytes32) data; // index => commitmentHash
        uint256 size;
    }

    function push(
        HeapStorage storage self,
        mapping(bytes32 => uint256) storage challengeDeadline,
        mapping(bytes32 => uint256) storage commitmentQueueIndex,
        bytes32 commitmentHash
    ) internal {
        if (commitmentQueueIndex[commitmentHash] != 0) {
            revert HeapAlreadyExists(commitmentHash);
        }

        uint256 i = self.size;
        self.data[i] = commitmentHash;
        self.size = i + 1;
        commitmentQueueIndex[commitmentHash] = i + 1; // 1-based
        _siftUp(self, challengeDeadline, commitmentQueueIndex, i);
    }

    function pop(
        HeapStorage storage self,
        mapping(bytes32 => uint256) storage challengeDeadline,
        mapping(bytes32 => uint256) storage commitmentQueueIndex
    ) internal returns (bytes32 top) {
        if (self.size == 0) revert HeapEmpty();
        top = self.data[0];
        _removeAt(self, challengeDeadline, commitmentQueueIndex, 0);
    }

    function remove(
        HeapStorage storage self,
        mapping(bytes32 => uint256) storage challengeDeadline,
        mapping(bytes32 => uint256) storage commitmentQueueIndex,
        bytes32 commitmentHash
    ) internal returns (bool) {
        uint256 indexPlusOne = commitmentQueueIndex[commitmentHash];
        if (indexPlusOne == 0) {
            return false;
        }

        _removeAt(self, challengeDeadline, commitmentQueueIndex, indexPlusOne - 1);
        return true;
    }

    function peek(HeapStorage storage self) internal view returns (bytes32) {
        if (self.size == 0) revert HeapEmpty();
        return self.data[0];
    }

    function isEmpty(HeapStorage storage self) internal view returns (bool) {
        return self.size == 0;
    }

    function length(HeapStorage storage self) internal view returns (uint256) {
        return self.size;
    }

    function at(HeapStorage storage self, uint256 index) internal view returns (bytes32) {
        return self.data[index];
    }

    function _removeAt(
        HeapStorage storage self,
        mapping(bytes32 => uint256) storage challengeDeadline,
        mapping(bytes32 => uint256) storage commitmentQueueIndex,
        uint256 i
    ) private {
        uint256 last = self.size - 1;
        bytes32 removedHash = self.data[i];
        delete commitmentQueueIndex[removedHash];

        if (i == last) {
            delete self.data[last];
            self.size = last;
            return;
        }

        bytes32 lastHash = self.data[last];
        delete self.data[last];
        self.data[i] = lastHash;
        commitmentQueueIndex[lastHash] = i + 1; // 1-based
        self.size = last;

        _siftDown(self, challengeDeadline, commitmentQueueIndex, i);
        _siftUp(self, challengeDeadline, commitmentQueueIndex, i);
    }

    function _siftDown(
        HeapStorage storage self,
        mapping(bytes32 => uint256) storage challengeDeadline,
        mapping(bytes32 => uint256) storage commitmentQueueIndex,
        uint256 i
    ) private {
        uint256 size = self.size;
        while (true) {
            uint256 smallest = i;
            uint256 left = 2 * i + 1;
            uint256 right = left + 1;

            if (left < size && challengeDeadline[self.data[left]] < challengeDeadline[self.data[smallest]]) {
                smallest = left;
            }
            if (right < size && challengeDeadline[self.data[right]] < challengeDeadline[self.data[smallest]]) {
                smallest = right;
            }
            if (smallest == i) break;

            _swap(self, commitmentQueueIndex, smallest, i);
            i = smallest;
        }
    }

    function _siftUp(
        HeapStorage storage self,
        mapping(bytes32 => uint256) storage challengeDeadline,
        mapping(bytes32 => uint256) storage commitmentQueueIndex,
        uint256 i
    ) private {
        while (i > 0) {
            uint256 parent = (i - 1) / 2;
            if (challengeDeadline[self.data[parent]] <= challengeDeadline[self.data[i]]) break;

            _swap(self, commitmentQueueIndex, parent, i);
            i = parent;
        }
    }

    function _swap(HeapStorage storage self, mapping(bytes32 => uint256) storage commitmentQueueIndex, uint256 a, uint256 b) private {
        bytes32 tmp = self.data[a];
        self.data[a] = self.data[b];
        self.data[b] = tmp;

        commitmentQueueIndex[self.data[a]] = a + 1; // 1-based
        commitmentQueueIndex[self.data[b]] = b + 1; // 1-based
    }
}
