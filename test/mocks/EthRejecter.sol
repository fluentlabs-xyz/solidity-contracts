// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @dev Mock contract that rejects all incoming ETH transfers.
contract EthRejecter {
    receive() external payable {
        revert("rejected");
    }
}
