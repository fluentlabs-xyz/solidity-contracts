// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FluentBridge} from "../FluentBridge.sol";

import {IFluentBridge} from "../../interfaces/bridge/IFluentBridge.sol";
import {IL1BlockOracle} from "../../interfaces/oracles/IL1BlockOracle.sol";
import {IL2FluentBridge} from "../../interfaces/bridge/IL2FluentBridge.sol";
import {IL1GasOracle} from "../../interfaces/oracles/IL1GasOracle.sol";

/**
 * @title L2FluentBridge
 * @author Fluent Labs
 * @dev L2 bridge contract lives on Fluent chain.
 */
contract L2FluentBridge is FluentBridge, IL2FluentBridge {
    // TODO: recalculate this
    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.L2FluentBridgeStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant L2_FLUENT_BRIDGE_STORAGE_LOCATION = 0x48432b5738e38939c89691519357184232440d69c0560714148646564b437700;

    struct GasPriceConfig {
        uint256 _overheadGasPrice;
        uint256 _scalarGasPrice;
    }

    struct L2FluentBridgeStorage {
        uint256 _receiveMessageDeadline;
        address _l1BlockOracle;
        address _l1GasPriceOracle;
        GasPriceConfig _gasPriceConfig;
        uint256[50] __gap;
    }

    function _getL2FluentBridgeStorage() private pure returns (L2FluentBridgeStorage storage $) {
        assembly {
            $.slot := L2_FLUENT_BRIDGE_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(bytes calldata data, uint256 receiveMessageDeadline, address l1BlockOracle) external initializer {
        __FluentBridgeStorage_init(data);

        _setReceiveMessageDeadline(receiveMessageDeadline);
        _setL1BlockOracle(l1BlockOracle);
    }

    function _afterSendMessage(bytes32 /* messageHash */) internal override {
        uint256 messageFee = calculateGasCost();
        require(msg.value >= messageFee, InsufficientMsgValue());
        (bool _success, ) = getFeeTreasury().call{value: messageFee}("");
        require(_success, FailedToDeductFee());
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

        uint256 l1BlockNumber = IL1BlockOracle(getL1BlockOracle()).getL1BlockNumber();

        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        if (l1BlockNumber >= blockNumber && l1BlockNumber - blockNumber >= getReceiveMessageDeadline()) {
            _getFluentBridgeStorage()._receivedMessage[messageHash] = IFluentBridge.MessageStatus.Failed;
            emit RollbackMessage(messageHash, block.number); // -> L2BlockHeader.withdrawalRoot
            emit ReceivedMessage(messageHash, false, "");
            return false;
        }
        return true;
    }

    function getL1BlockOracle() public view returns (address) {
        return _getL2FluentBridgeStorage()._l1BlockOracle;
    }

    function getL1GasPriceOracle() public view returns (address) {
        return _getL2FluentBridgeStorage()._l1GasPriceOracle;
    }

    /// @inheritdoc IL2FluentBridge
    function getReceiveMessageDeadline() public view returns (uint256) {
        return _getL2FluentBridgeStorage()._receiveMessageDeadline;
    }

    function getGasPriceConfig() public view returns (GasPriceConfig memory) {
        return _getL2FluentBridgeStorage()._gasPriceConfig;
    }

    function calculateGasCost() public view returns (uint256) {
        GasPriceConfig memory gasPriceConfig = getGasPriceConfig();
        uint256 l1GasPrice = IL1GasOracle(getL1GasPriceOracle()).getL1GasPrice();
        return gasPriceConfig._scalarGasPrice * (l1GasPrice * getExecuteGasLimit()) + gasPriceConfig._overheadGasPrice;
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
        emit L1BlockOracleUpdated(getL1BlockOracle(), l1BlockOracle);
        _getL2FluentBridgeStorage()._l1BlockOracle = l1BlockOracle;
    }

    function setReceiveMessageDeadline(uint256 receiveMessageDeadline) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setReceiveMessageDeadline(receiveMessageDeadline);
    }

    function _setReceiveMessageDeadline(uint256 receiveMessageDeadline) internal {
        require(receiveMessageDeadline > 0, InvalidWindowConfig("receiveMessageDeadline must be greater than 0"));
        emit ReceiveMessageDeadlineUpdated(getReceiveMessageDeadline(), receiveMessageDeadline);
        _getL2FluentBridgeStorage()._receiveMessageDeadline = receiveMessageDeadline;
    }
}
