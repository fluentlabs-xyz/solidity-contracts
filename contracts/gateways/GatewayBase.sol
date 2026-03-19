// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IGateway} from "../interfaces/gateways/IGateway.sol";

/**
 * @title GatewayBase
 * @author Fluent Lab
 *
 * @notice Base contract for all gateway implementations.
 * @dev Implements IGateway interface and provides common functionality for all gateways.
 * @dev Storage in GatewayBaseStorage (ERC-7201): bridgeContract, otherSide, otherSideChainId.
 * @dev Only the configured bridge may call receive* entrypoints; native receive requires msg.value == amount (bridge forwards value from its receive caller).
 * @dev Admin: setBridgeContract, setOtherSideGateway.
 */
abstract contract GatewayBase is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable, IGateway {
    /// @custom:storage-location erc7201:fluent.storage.PaymentGateway
    struct GatewayBaseStorage {
        address _bridgeContract;
        address _otherSide;
        uint256 _otherSideChainId;
        uint256[50] __gap;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.PaymentGatewayStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GATEWAY_BASE_STORAGE_LOCATION = 0xcaa08bf2435fec1ef38988227447dbd9b56d025c40329ce35d36c83ed0b9cf00;

    /// @dev returns the storage pointer for the GatewayBaseStorage struct.
    function _getGatewayBaseStorage() internal pure returns (GatewayBaseStorage storage $) {
        assembly {
            $.slot := GATEWAY_BASE_STORAGE_LOCATION
        }
    }

    modifier onlyBridgeSender() {
        require(msg.sender == _getGatewayBaseStorage()._bridgeContract, OnlyBridgeSender());
        _;
    }

    function __GatewayBase_init(address initialOwner, address bridgeContract) internal onlyInitializing {
        require(initialOwner != address(0) && bridgeContract != address(0), ZeroAddress());

        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // ============ Storage ============
        _setBridgeContract(bridgeContract);
    }
    // ============ Public getters ============

    function getBridgeContract() public view returns (address) {
        return _getGatewayBaseStorage()._bridgeContract;
    }

    function getOtherSide() public view returns (address) {
        return _getGatewayBaseStorage()._otherSide;
    }

    function getOtherSideChainId() public view returns (uint256) {
        return _getGatewayBaseStorage()._otherSideChainId;
    }

    // ============ Admin functions ============

    /**
     * @notice Updates the bridge contract address used for sending and receiving messages.
     * @param newBridgeContract The address of the bridge contract.
     */
    function setBridgeContract(address newBridgeContract) external onlyOwner {
        _setBridgeContract(newBridgeContract);
    }

    function _setBridgeContract(address newBridgeContract) internal {
        require(newBridgeContract != address(0), ZeroAddress());
        GatewayBaseStorage storage $ = _getGatewayBaseStorage();
        emit BridgeContractUpdated($._bridgeContract, newBridgeContract);
        $._bridgeContract = newBridgeContract;
    }

    /**
     * @notice Updates the remote gateway address used as message destination.
     * @param newOtherSide The address of the other side gateway.
     */
    function setOtherSideGateway(address newOtherSide) external onlyOwner {
        _setOtherSideGateway(newOtherSide);
    }

    function _setOtherSideGateway(address newOtherSide) internal {
        require(newOtherSide != address(0), ZeroAddress());
        GatewayBaseStorage storage $ = _getGatewayBaseStorage();
        emit OtherSideGatewayUpdated($._otherSide, newOtherSide);
        $._otherSide = newOtherSide;
    }

    function _setOtherSideChainId(uint256 newOtherSideChainId) internal {
        _getGatewayBaseStorage()._otherSideChainId = newOtherSideChainId;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
