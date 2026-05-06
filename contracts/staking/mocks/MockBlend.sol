// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockBlend is ERC20 {
    constructor() ERC20("Mock Blend", "BLEND") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}
