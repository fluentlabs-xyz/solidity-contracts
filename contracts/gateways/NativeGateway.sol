// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GatewayBase} from "./GatewayBase.sol";
import {FluentBridge} from "../bridge/FluentBridge.sol";

import {INativeGateway} from "../interfaces/gateways/INativeGateway.sol";

/**
 * @title NativeGateway
 * @author Fluent Lab
 *
 * @notice Gateway for bridging native ETH between chains through `FluentBridge`.
 * @dev UUPS-upgradeable gateway. Bridge routing state is inherited from `GatewayBase` (ERC-7201 namespace),
 *      while this contract stores only `_gasLimit` for outbound native transfer execution.
 * @dev Security model:
 *      - `sendNativeTokens` requires `msg.value == amount`.
 *      - `receiveNativeTokens` is restricted to the configured bridge and verifies the remote gateway sender.
 *      - Incoming bridge calls must provide `msg.value == amount`, then ETH is forwarded to the recipient.
 * @dev Flows:
 *      1) Source chain: user calls `sendNativeTokens(to, amount)` and ETH is forwarded into
 *         `FluentBridge.sendMessage{value: amount}(otherSide, payload)`.
 *      2) Destination chain: relayer executes bridge delivery; gateway validates origin and transfers ETH to `to`
 *         using `call{gas: getGasLimit(), value: amount}`.
 * @dev Admin functions: `setGasLimit` and `rescueNative`.
 */
contract NativeGateway is GatewayBase, INativeGateway {
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public constant DEFAULT_GAS_LIMIT = 100_000;

    uint256 internal _gasLimit;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the upgradeable gateway (replaces constructor when used behind a proxy).
    function initialize(address initialOwner, address bridgeContract) public initializer {
        __GatewayBase_init(initialOwner, bridgeContract);

        // ============ Storage ============
        _setGasLimit(DEFAULT_GAS_LIMIT);
    }

    /// @inheritdoc INativeGateway
    function sendNativeTokens(address to) external payable nonReentrant {
        uint256 amount = msg.value;
        require(to != address(0), InvalidRecipient());
        require(amount > 0, InvalidNativeAmount());

        FluentBridge(getBridgeContract()).sendMessage{value: amount}(
            getOtherSideGateway(),
            abi.encodeCall(NativeGateway.receiveNativeTokens, (msg.sender, to, amount))
        );
    }

    /// @inheritdoc INativeGateway
    function receiveNativeTokens(address from, address to, uint256 amount) external payable onlyFluentBridge nonReentrant {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(msg.value == amount, InvalidNativeAmount());
        require(to != address(0), InvalidRecipient());

        (bool success, ) = payable(to).call{gas: getGasLimit(), value: amount}("");
        require(success, NativeTransferFailed());

        emit ReceivedTokens(from, to, amount);
    }

    /// @inheritdoc INativeGateway
    function rescueNative(address payable to, uint256 amount) external nonReentrant onlyOwner {
        require(to != address(0), InvalidRecipient());
        (bool success, ) = to.call{value: amount}("");
        require(success, NativeTransferFailed());
    }

    // ============ Public getters ============

    /// @inheritdoc INativeGateway
    function getGasLimit() public view returns (uint256) {
        return _gasLimit;
    }

    // ============ Admin functions ============

    /// @inheritdoc INativeGateway
    function setGasLimit(uint256 newGasLimit) external onlyOwner {
        _setGasLimit(newGasLimit);
    }

    function _setGasLimit(uint256 newGasLimit) internal {
        require(newGasLimit > 0, InvalidGasLimit());
        emit GasLimitUpdated(_gasLimit, newGasLimit);
        _gasLimit = newGasLimit;
    }

    receive() external payable {}
}
