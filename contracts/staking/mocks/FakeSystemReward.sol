// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "../SystemReward.sol";

/// @title Test system reward implementation
/// @notice Exposes reward distribution updates without governance restrictions for tests.
contract FakeSystemReward is SystemReward {
    function updateDistributionShare(address[] calldata accounts, uint16[] calldata shares) external virtual override {
        _updateDistributionShare(accounts, shares);
    }
}
