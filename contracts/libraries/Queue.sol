// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

library Queue {
    struct QueueStorage {
        mapping(uint256 => bytes32) data;
        uint256 front;
        uint256 back;
    }

    function initialize(QueueStorage storage self) internal {
        self.front = 0;
        self.back = 0;
    }

    function enqueue(QueueStorage storage self, bytes32 value) internal {
        self.data[self.back] = value;
        self.back++;
    }

    function dequeue(QueueStorage storage self) internal returns (bytes32) {
        require(!isEmpty(self), "Queue is empty");
        bytes32 value = self.data[self.front];
        delete self.data[self.front];
        self.front++;
        return value;
    }

    function peek(QueueStorage storage self) internal view returns (bytes32) {
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
