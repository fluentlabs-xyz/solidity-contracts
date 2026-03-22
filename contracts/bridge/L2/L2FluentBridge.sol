// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FluentBridge} from "../FluentBridge.sol";

import {IFluentBridge} from "../../interfaces/bridge/IFluentBridge.sol";
import {IL1BlockOracle} from "../../interfaces/IL1BlockOracle.sol";
import {IL2FluentBridge} from "../../interfaces/bridge/IL2FluentBridge.sol";

/**
 * @title L2FluentBridge
 * @author Fluent Labs
 * @dev L2 bridge contract lives on Fluent chain.
 */
contract L2FluentBridge is FluentBridge, IL2FluentBridge {
    /**
     * @notice Number of blocks after which a message becomes eligible for rollback.
     */
    uint256 internal _receiveMessageDeadline;

    /**
     * @notice Address of the L1 block oracle used for rollback deadline checks.
     */
    IL1BlockOracle internal _l1BlockOracle;

    /**
     * @dev
     */
    uint256 internal _sendMessageFee;

    /**
     * @notice Gap for future storage.
     */
    uint256[50] __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(bytes calldata data, uint256 receiveMessageDeadline, address l1BlockOracle) external initializer {
        __FluentBridgeStorage_init(data);

        _setReceiveMessageDeadline(receiveMessageDeadline);
        _setL1BlockOracle(l1BlockOracle);
    }

    /// L1 -> L2 rollback
    function _beforeReceiveMessage(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 messageNonce,
        bytes calldata message
    ) internal override returns (bool) {
        require(blockNumber > 0, ZeroValueNotAllowed("blockNumber"));

        uint256 l1BlockNumber = _l1BlockOracle.getL1BlockNumber();

        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        if (l1BlockNumber >= blockNumber && l1BlockNumber - blockNumber >= _receiveMessageDeadline) {
            _getFluentBridgeStorage()._receivedMessage[messageHash] = IFluentBridge.MessageStatus.Failed;
            emit RollbackMessage(messageHash, block.number); // -> L2BlockHeader.withdrawalRoot
            emit ReceivedMessage(messageHash, false, "");
            return false;
        }
        return true;
    }

    function getL1BlockOracle() external view returns (address) {
        return address(_l1BlockOracle);
    }

    /// @inheritdoc IL2FluentBridge
    function getReceiveMessageDeadline() public view returns (uint256) {
        return _receiveMessageDeadline;
    }

    /**
     * @notice Update the address of the L1 block oracle used for rollback deadline checks.
     * @param l1BlockOracle The address of the L1 block oracle.
     */
    function setL1BlockOracle(address l1BlockOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setL1BlockOracle(l1BlockOracle);
    }

    function _setL1BlockOracle(address l1BlockOracle) internal {
        if (getReceiveMessageDeadline() != 0) require(l1BlockOracle != address(0), ZeroAddressNotAllowed("l1BlockOracle"));
        emit L1BlockOracleUpdated(address(_l1BlockOracle), l1BlockOracle);
        _l1BlockOracle = IL1BlockOracle(l1BlockOracle);
    }

    function setReceiveMessageDeadline(uint256 receiveMessageDeadline) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setReceiveMessageDeadline(receiveMessageDeadline);
    }

    function _setReceiveMessageDeadline(uint256 receiveMessageDeadline) internal {
        require(receiveMessageDeadline > 0, InvalidWindowConfig("receiveMessageDeadline must be greater than 0"));
        emit ReceiveMessageDeadlineUpdated(getReceiveMessageDeadline(), receiveMessageDeadline);
        _receiveMessageDeadline = receiveMessageDeadline;
    }
}
