// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @dev ERC20 that burns a fixed percentage on every transfer/transferFrom.
 *      Used to test that the gateway correctly handles fee-on-transfer tokens.
 */
contract MockFeeOnTransferERC20 is ERC20 {
    /// @dev Fee in basis points (e.g. 200 = 2%).
    uint256 public immutable feeBps;

    constructor(string memory name, string memory symbol, uint256 initialSupply, address supplyTarget, uint256 feeBps_) ERC20(name, symbol) {
        feeBps = feeBps_;
        _mint(supplyTarget, initialSupply);
    }

    function _update(address from, address to, uint256 value) internal override {
        // Mint and burn paths (from == 0 or to == 0) are fee-exempt.
        if (from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = (value * feeBps) / 10_000;
            // Burn the fee portion before transferring the remainder.
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}
