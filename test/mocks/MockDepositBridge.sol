// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @dev Simulates the sent-message surface of {L1FluentBridge} —
///      {consumeNextSentMessage}, {getMessageAt}, {advanceSentMessageCursor},
///      {rewindSentMessageCursor}, and the associated views — for testing deposit
///      processing in {Rollup._checkDeposits} and the cursor-rewind path in
///      {Rollup.forceRevertBatch}.
contract MockDepositBridge {
    mapping(uint256 => bytes32) internal _hashes;
    uint256 internal _front;
    uint256 internal _back;

    function enqueue(bytes32 hash) external {
        _hashes[_back] = hash;
        unchecked {
            ++_back;
        }
    }

    function consumeNextSentMessage() external returns (bytes32) {
        require(_front < _back, "queue empty");
        bytes32 h = _hashes[_front];
        unchecked {
            ++_front;
        }
        return h;
    }

    function getMessageAt(uint256 index) external view returns (bytes32) {
        return _hashes[index];
    }

    function advanceSentMessageCursor(uint256 count) external {
        require(_front + count <= _back, "insufficient messages");
        unchecked {
            _front += count;
        }
    }

    function rewindSentMessageCursor(uint256 newFront) external {
        require(newFront <= _front, "invalid rewind");
        _front = newFront;
    }

    function getSentMessageCursor() external view returns (uint256) {
        return _front;
    }

    function getSentMessageQueueSize() external view returns (uint256) {
        return _back - _front;
    }

    /// @dev Test helper used by {DepositsTest} to assert "all deposits consumed".
    function poppedCount() external view returns (uint256) {
        return _front;
    }
}
