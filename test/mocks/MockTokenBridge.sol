// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ITokenBridge} from "../../contracts/interfaces/external/hyperlane/ITokenBridge.sol";

/**
 * @notice Mock Hyperlane v10 warp route used by L1HypNativeGateway tests.
 * @dev Models the HypNative quote shape per `TokenRouter.quoteTransferRemote`:
 *      quotes[0] — dispatch gas payment (configurable via {setDispatchGas})
 *      quotes[1] — `_amount + internalFee` (configurable via {setInternalFee})
 *      quotes[2] — external bridging fee (configurable via {setExternalFee}, default 0)
 *      For HypNative every entry has `token == address(0)`, so the gateway must sum
 *      all three when computing the native value to forward.
 */
contract MockTokenBridge is ITokenBridge {
    uint256 public dispatchGas;
    uint256 public internalFee;
    uint256 public externalFee;

    bool public shouldRevertQuote;
    bool public shouldRevertTransfer;

    uint32 public lastDestination;
    bytes32 public lastRecipient;
    uint256 public lastAmount;
    uint256 public lastValue;

    function setDispatchGas(uint256 v) external {
        dispatchGas = v;
    }

    function setInternalFee(uint256 v) external {
        internalFee = v;
    }

    function setExternalFee(uint256 v) external {
        externalFee = v;
    }

    function setShouldRevertQuote(bool v) external {
        shouldRevertQuote = v;
    }

    function setShouldRevertTransfer(bool v) external {
        shouldRevertTransfer = v;
    }

    function transferRemote(uint32 _destination, bytes32 _recipient, uint256 _amount)
        external
        payable
        returns (bytes32 messageId)
    {
        if (shouldRevertTransfer) revert("mock-transfer-revert");
        // Mirror HypNative's check: caller must forward at least amount + internalFee + externalFee + dispatchGas.
        uint256 required = _amount + internalFee + externalFee + dispatchGas;
        require(msg.value >= required, "mock-insufficient-native");

        lastDestination = _destination;
        lastRecipient = _recipient;
        lastAmount = _amount;
        lastValue = msg.value;
        // Synthetic message id for off-chain correlation in tests.
        messageId = keccak256(abi.encode(_destination, _recipient, _amount, msg.value));
    }

    function quoteTransferRemote(uint32, bytes32, uint256 _amount)
        external
        view
        returns (Quote[] memory quotes)
    {
        if (shouldRevertQuote) revert("mock-quote-revert");
        quotes = new Quote[](3);
        quotes[0] = Quote({token: address(0), amount: dispatchGas});
        quotes[1] = Quote({token: address(0), amount: _amount + internalFee});
        quotes[2] = Quote({token: address(0), amount: externalFee});
    }
}
