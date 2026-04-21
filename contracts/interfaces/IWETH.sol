// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IWETH
 * @author Fluent Labs
 *
 * @notice Minimal canonical WETH9 surface consumed by the WETH bridge gateway.
 * @dev Intentionally narrow: only the two conversion entrypoints in addition to the ERC20
 *      interface. The gateway never relies on WETH-specific features beyond `deposit` /
 *      `withdraw`, so any ERC20 that honours these two calls (and holds 1 wei of native
 *      value per 1 wei of token) is a drop-in replacement.
 */
interface IWETH is IERC20 {
    /**
     * @notice Wraps `msg.value` wei of native asset into an equal amount of WETH, minting
     *         the resulting balance to `msg.sender`.
     */
    function deposit() external payable;

    /**
     * @notice Unwraps `amount` WETH from `msg.sender`, burning the balance and forwarding
     *         the equivalent native value back to `msg.sender`.
     */
    function withdraw(uint256 amount) external;
}
