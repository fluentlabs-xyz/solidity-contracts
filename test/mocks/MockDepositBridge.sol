// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @dev Simulates L1FluentBridge.popSentMessage() / pushSentMessage() for testing
///      deposit processing in Rollup._checkDeposits() and deposit restoration in
///      Rollup._cleanupForceRevertBatch(). Uses a mapping-backed FIFO with front/back
///      cursors to mirror the real Queue library semantics (including safe pushFront
///      into slots previously cleared by pop).
contract MockDepositBridge {
    struct Deposit {
        bytes32 id;
        uint256 blockNumber;
    }

    mapping(uint256 => Deposit) internal _q;
    uint256 internal _front;
    uint256 internal _back;

    function enqueue(bytes32 id, uint256 blockNumber) external {
        _q[_back] = Deposit(id, blockNumber);
        _back++;
    }

    function popSentMessage() external returns (bytes32, uint256) {
        require(_front < _back, "queue empty");
        Deposit memory d = _q[_front];
        delete _q[_front];
        _front++;
        return (d.id, d.blockNumber);
    }

    /// @dev Restores `messageHash` at the front of the queue with the current block
    ///      number, mirroring Queue.pushFront semantics. Safe only when called for
    ///      previously popped items (so _front > 0).
    function pushSentMessage(bytes32 messageHash) external {
        require(_front > 0, "queue front underflow");
        _front--;
        _q[_front] = Deposit(messageHash, block.number);
    }

    function queueSize() external view returns (uint256) {
        return _back - _front;
    }

    function poppedCount() external view returns (uint256) {
        return _front;
    }
}
