// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {IERC20}     from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}  from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable}    from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Airdrop
/// @notice Push-distributes one ERC20 token and a fixed ETH amount to an
///         immutable list of recipients. Idempotent: failed entries can be
///         retried by calling `distribute()` again after fixing the
///         underlying issue.
contract Airdrop is Ownable {
    using SafeERC20 for IERC20;

    struct Entry {
        address recipient;
        uint96  tokenAmount;
    }

    IERC20  public immutable token;
    uint256 public immutable ethPerRecipient;

    Entry[] public entries;

    /// @dev Packed bitmap; bit `i` set means index `i` was distributed.
    mapping(uint256 => uint256) private _distributedBitmap;

    error LengthMismatch();
    error EmptyEntries();
    error ZeroAddress(uint256 index);
    error ZeroAmount(uint256 index);
    error InsufficientTokenBalance(uint256 have, uint256 need);
    error InsufficientEthBalance(uint256 have, uint256 need);
    error NotSelf();
    error RangeInvalid();
    error EthTransferFailed();

    event Airdropped(
        uint256 indexed index,
        address indexed recipient,
        uint256 tokenAmount,
        uint256 ethAmount
    );
    event AirdropFailed(uint256 indexed index, address indexed recipient);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    constructor(
        IERC20 _token,
        uint256 _ethPerRecipient,
        address[] memory recipients,
        uint96[] memory tokenAmounts
    ) Ownable(msg.sender) {
        if (recipients.length != tokenAmounts.length) revert LengthMismatch();
        if (recipients.length == 0) revert EmptyEntries();

        token = _token;
        ethPerRecipient = _ethPerRecipient;

        for (uint256 i = 0; i < recipients.length;) {
            if (recipients[i] == address(0)) revert ZeroAddress(i);
            if (tokenAmounts[i] == 0) revert ZeroAmount(i);
            entries.push(Entry({recipient: recipients[i], tokenAmount: tokenAmounts[i]}));
            unchecked { ++i; }
        }
    }

    receive() external payable {}

    /// @notice Owner runs the full batch; failed entries stay unset for retry.
    function distribute() external onlyOwner {
        _distributeRange(0, entries.length);
    }

    /// @notice Owner runs a bounded subrange — hedge against gas-limit edges.
    /// @param start Inclusive start index.
    /// @param end   Exclusive end index.
    function distributeRange(uint256 start, uint256 end) external onlyOwner {
        if (start >= end || end > entries.length) revert RangeInvalid();
        _distributeRange(start, end);
    }

    /// @notice Called only by the contract itself inside try/catch.
    function _send(address to, uint256 tokenAmt, uint256 ethAmt) external {
        if (msg.sender != address(this)) revert NotSelf();
        token.safeTransfer(to, tokenAmt);
        (bool ok,) = to.call{value: ethAmt}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @notice Owner sweeps leftover ETH (`_token == address(0)`) or tokens.
    function rescue(address _token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress(0);
        uint256 amount;
        if (_token == address(0)) {
            amount = address(this).balance;
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            amount = IERC20(_token).balanceOf(address(this));
            IERC20(_token).safeTransfer(to, amount);
        }
        emit Rescued(_token, to, amount);
    }

    function entriesLength() external view returns (uint256) {
        return entries.length;
    }

    function isDistributed(uint256 index) public view returns (bool) {
        return _distributedBitmap[index >> 8] & (1 << (index & 0xff)) != 0;
    }

    function totalTokensRequired() external view returns (uint256 total) {
        uint256 n = entries.length;
        for (uint256 i = 0; i < n;) {
            if (!isDistributed(i)) total += entries[i].tokenAmount;
            unchecked { ++i; }
        }
    }

    function totalEthRequired() external view returns (uint256) {
        uint256 n = entries.length;
        uint256 pending;
        for (uint256 i = 0; i < n;) {
            if (!isDistributed(i)) {
                unchecked { ++pending; }
            }
            unchecked { ++i; }
        }
        return pending * ethPerRecipient;
    }

    function _distributeRange(uint256 start, uint256 end) internal {
        uint256 needTokens;
        uint256 pendingCount;
        for (uint256 i = start; i < end;) {
            if (!isDistributed(i)) {
                needTokens += entries[i].tokenAmount;
                unchecked { ++pendingCount; }
            }
            unchecked { ++i; }
        }
        uint256 needEth = pendingCount * ethPerRecipient;

        uint256 haveTokens = token.balanceOf(address(this));
        if (haveTokens < needTokens) revert InsufficientTokenBalance(haveTokens, needTokens);
        uint256 haveEth = address(this).balance;
        if (haveEth < needEth) revert InsufficientEthBalance(haveEth, needEth);

        uint256 ethPer = ethPerRecipient;
        for (uint256 i = start; i < end;) {
            if (!isDistributed(i)) {
                Entry memory e = entries[i];
                try this._send(e.recipient, e.tokenAmount, ethPer) {
                    _setDistributed(i);
                    emit Airdropped(i, e.recipient, e.tokenAmount, ethPer);
                } catch {
                    emit AirdropFailed(i, e.recipient);
                }
            }
            unchecked { ++i; }
        }
    }

    function _setDistributed(uint256 index) internal {
        _distributedBitmap[index >> 8] |= (1 << (index & 0xff));
    }
}
