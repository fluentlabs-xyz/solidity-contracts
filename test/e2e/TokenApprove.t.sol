// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20Token} from "../../contracts/mocks/MockERC20.sol";

contract TokenApproveTest is Test {
    MockERC20Token internal token;
    address internal owner = address(0xA11CE);
    address internal spender = address(0xB0B);

    function setUp() public {
        // Give owner some ETH for possible future extensions
        vm.deal(owner, 10 ether);

        // Deploy mock ERC20 with initial supply to owner
        token = new MockERC20Token("Mock Token", "TKN", 1_000_000 ether, owner);
    }

    function testApproveUpdatesAllowance() public {
        // Initial allowance should be zero
        uint256 initialAllowance = token.allowance(owner, spender);
        assertEq(initialAllowance, 0, "initial allowance must be zero");

        // Approve 100 units from owner to spender
        vm.prank(owner);
        token.approve(spender, 100);

        uint256 finalAllowance = token.allowance(owner, spender);
        assertEq(finalAllowance, 100, "allowance after approve must be 100");
    }
}

