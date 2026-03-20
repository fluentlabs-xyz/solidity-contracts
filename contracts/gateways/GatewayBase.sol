// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IGateway} from "../interfaces/gateways/IGateway.sol";

/**
 * @title GatewayBase
 * @author Fluent Lab
 *
 * @notice Shared gateway foundation for cross-chain token gateways.
 * @dev UUPS-upgradeable base that centralizes:
 *      - common access control (`onlyOwner`, bridge-caller checks),
 *      - shared bridge routing config (`_bridgeContract`, `_otherSide`, `_otherSideChainId`),
 *      - common admin setters for bridge and remote gateway addresses.
 * @dev Storage is namespaced under ERC-7201 (`GatewayBaseStorage`) and consumed by derived gateways
 *      such as `NativeGateway` and `ERC20Gateway`.
 * @dev `onlyFluentBridge` enforces that receive entrypoints are callable only by the configured local
 *      `FluentBridge` instance.
 */
abstract contract GatewayBase is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable, IGateway {
    /// @custom:storage-location erc7201:fluent.storage.GatewayBaseStorage
    struct GatewayBaseStorage {
        address _bridgeContract;
        address _otherSideGateway;
        uint256 _otherSideChainId;
        uint256[50] __gap;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.GatewayBaseStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GATEWAY_BASE_STORAGE_LOCATION = 0x76174ff789203cf2db8238f11acb33783dc695662454a2feabb4fb5ea262c400;

    /// @dev returns the storage pointer for the GatewayBaseStorage struct.
    function _getGatewayBaseStorage() internal pure returns (GatewayBaseStorage storage $) {
        assembly {
            $.slot := GATEWAY_BASE_STORAGE_LOCATION
        }
    }

    modifier onlyFluentBridge() {
        require(msg.sender == _getGatewayBaseStorage()._bridgeContract, OnlyFluentBridge());
        _;
    }

    function __GatewayBase_init(address initialOwner, address bridgeContract) internal onlyInitializing {
        require(initialOwner != address(0) && bridgeContract != address(0), ZeroAddressNotAllowed("initialOwner or bridgeContract"));

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

    function getOtherSideGateway() public view returns (address) {
        return _getGatewayBaseStorage()._otherSideGateway;
    }

    function getOtherSideChainId() public view returns (uint256) {
        return _getGatewayBaseStorage()._otherSideChainId;
    }

    // ============ Admin functions ============

    /// @inheritdoc IGateway
    function setBridgeContract(address newBridgeContract) external onlyOwner {
        _setBridgeContract(newBridgeContract);
    }

    function _setBridgeContract(address newBridgeContract) internal {
        require(newBridgeContract != address(0), ZeroAddressNotAllowed("newBridgeContract"));
        GatewayBaseStorage storage $ = _getGatewayBaseStorage();
        emit BridgeContractUpdated($._bridgeContract, newBridgeContract);
        $._bridgeContract = newBridgeContract;
    }

    /// @inheritdoc IGateway
    function setOtherSideGateway(address newOtherSideGateway) external onlyOwner {
        _setOtherSideGateway(newOtherSideGateway);
    }

    function _setOtherSideGateway(address newOtherSideGateway) internal {
        require(newOtherSideGateway != address(0), ZeroAddressNotAllowed("newOtherSideGateway"));
        GatewayBaseStorage storage $ = _getGatewayBaseStorage();
        emit OtherSideGatewayUpdated($._otherSideGateway, newOtherSideGateway);
        $._otherSideGateway = newOtherSideGateway;
    }

    /// @inheritdoc IGateway
    function setOtherSideChainId(uint256 newOtherSideChainId) external onlyOwner {
        _setOtherSideChainId(newOtherSideChainId);
    }

    function _setOtherSideChainId(uint256 newOtherSideChainId) internal {
        GatewayBaseStorage storage $ = _getGatewayBaseStorage();
        emit OtherSideChainIdUpdated($._otherSideChainId, newOtherSideChainId);
        $._otherSideChainId = newOtherSideChainId;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
