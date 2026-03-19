// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GatewayBase} from "./GatewayBase.sol";
import {FluentBridge} from "../bridge/FluentBridge.sol";

import {INativeGateway} from "../interfaces/gateways/INativeGateway.sol";

/**
 * @title NativeGateway
 * @author Fluent Lab
 *
 * @notice Gateway for bridging native (ETH) tokens between two chains via FluentBridge.
 * @dev Upgradeable via UUPS proxy (ERC1967Proxy); upgrade authorized by owner. State in NativeGatewayStorage (ERC-7201). Only the configured bridge
 *      may call receive* entrypoints; native receive requires msg.value == amount (bridge forwards value from its receive caller).
 * @notice Workflows:
 * 1. Send native tokens (this chain -> other chain):
 *    - User calls sendNativeTokens(to, amount) with msg.value == amount.
 *    - Gateway forwards value to FluentBridge.sendMessage{value: amount}(otherSide, receiveNativeTokens(sender, to, amount)).
 *    - Native is locked in the bridge on this chain; relayer must supply same amount when executing receive on the other chain.
 * 2. Receive native tokens (other chain -> this chain):
 *    - Only callable by bridge; bridge must call with msg.value == amount. Gateway forwards amount to recipient via call with gasLimit().
 * Admin: setGasLimit, rescueNative (recover stuck ETH).
 */
contract NativeGateway is GatewayBase, INativeGateway {
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public constant DEFAULT_GAS_LIMIT = 50_000;

    uint256 internal _gasLimit;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the upgradeable gateway (replaces constructor when used behind a proxy).
    function initialize(address initialOwner, address bridgeContract) public initializer {
        require(initialOwner != address(0) && bridgeContract != address(0), ZeroAddress());

        __GatewayBase_init(initialOwner, bridgeContract);

        // ============ Storage ============
        _setGasLimit(DEFAULT_GAS_LIMIT);
    }

    /// @inheritdoc INativeGateway
    function sendNativeTokens(address _to, uint256 _amount) external payable nonReentrant {
        require(_to != address(0), InvalidRecipient());
        require(msg.value == _amount, InvalidNativeAmount());

        FluentBridge(getBridgeContract()).sendMessage{value: _amount}(
            getOtherSide(),
            abi.encodeCall(NativeGateway.receiveNativeTokens, (msg.sender, _to, _amount))
        );
    }

    /// @inheritdoc INativeGateway
    function receiveNativeTokens(address _from, address _to, uint256 _amount) external payable onlyBridgeSender nonReentrant {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSide(), MessageFromWrongGateway());
        require(msg.value == _amount, InvalidNativeAmount());
        require(_to != address(0), InvalidRecipient());

        (bool success, ) = payable(_to).call{gas: getGasLimit(), value: _amount}("");
        require(success, NativeTransferFailed());

        emit ReceivedTokens(_from, _to, _amount);
    }

    /**
     * @notice Recovers ETH accidentally sent or force-sent to this contract.
     * @param to The address to send the ETH to.
     * @param amount The amount of ETH to send.
     */
    function rescueNative(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), InvalidRecipient());
        (bool success, ) = to.call{value: amount}("");
        require(success, NativeTransferFailed());
    }

    // ============ Public getters ============

    function getGasLimit() public view returns (uint256) {
        return _gasLimit;
    }

    /**
     * @notice Sets the gas limit for the bridge.
     * @param newGasLimit The new gas limit.
     */
    function setGasLimit(uint256 newGasLimit) external onlyOwner {
        _setGasLimit(newGasLimit);
    }

    function _setGasLimit(uint256 newGasLimit) internal {
        require(newGasLimit > 0, InvalidGasLimit());
        emit GasLimitUpdated(_gasLimit, newGasLimit);
        _gasLimit = newGasLimit;
    }

    /// @notice Receives ETH (e.g. forced transfers). Prefer bridge entrypoints for normal flow.
    receive() external payable {}
}
