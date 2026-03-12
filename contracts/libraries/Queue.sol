// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

library Queue {
    struct QueueItem {
        bytes32 value;
        uint256 blockNumber;
    }

    struct QueueStorage {
        mapping(uint256 => QueueItem) data;
        uint256 front;
        uint256 back;
    }

    function initialize(QueueStorage storage self) internal {
        self.front = 0;
        self.back = 0;
    }

    function enqueue(QueueStorage storage self, bytes32 value) internal {
        self.data[self.back] = QueueItem(value, block.number);
        self.back++;
    }

    function dequeue(QueueStorage storage self) internal returns (QueueItem memory) {
        require(!isEmpty(self), "Queue is empty");
        QueueItem memory item = self.data[self.front];
        delete self.data[self.front];
        self.front++;
        return item;
    }

    function peek(QueueStorage storage self) internal view returns (QueueItem memory) {
        require(!isEmpty(self), "Queue is empty");
        return self.data[self.front];
    }

    function isEmpty(QueueStorage storage self) internal view returns (bool) {
        return self.back == self.front;
    }

    function size(QueueStorage storage self) internal view returns (uint256) {
        return self.back - self.front;
    }
}
