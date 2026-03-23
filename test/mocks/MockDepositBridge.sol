// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @dev Simulates L1FluentBridge.popSentMessage() for testing deposit
///      processing in Rollup._checkDeposits(). Supports dynamic enqueue
///      with per-deposit block numbers.
contract MockDepositBridge {
    struct Deposit {
        bytes32 id;
        uint256 blockNumber;
    }

    Deposit[] internal _q;
    uint256 internal _front;

    function enqueue(bytes32 id, uint256 blockNumber) external {
        _q.push(Deposit(id, blockNumber));
    }

    function popSentMessage() external returns (bytes32, uint256) {
        require(_front < _q.length, "queue empty");
        Deposit memory d = _q[_front++];
        return (d.id, d.blockNumber);
    }

    function queueSize() external view returns (uint256) {
        return _q.length - _front;
    }

    function poppedCount() external view returns (uint256) {
        return _front;
    }
}
