// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGenericTokenFactory} from "../interfaces/IGenericTokenFactory.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title GenericTokenFactory
 * @author Fluent Labs
 * @notice Base for bridge pegged-token factories (ERC20 and Universal); only PaymentGateway or owner may deploy.
 * @dev Storage in GenericTokenFactoryStorage (ERC-7201): beacon, PaymentGateway, bridgedTokens (origin => pegged), tokenInfo (token => TokenInfo).
 *      Subclasses define keyData/deployArgs format, salt logic, and deployment bytecode; base provides setPaymentGateway, upgradeTo(beacon),
 *      computePeggedTokenAddress(keyData, deployArgs), and computeOtherSidePeggedTokenAddress for cross-chain address prediction.
 * @notice Workflows:
 * 1. Gateway deploys a pegged token: deployToken(keyData, deployArgs) is callable only by paymentGateway or owner; emits TokenDeployed(origin, token).
 * 2. Address prediction (this chain): computePeggedTokenAddress(keyData, deployArgs) returns the address that would be computed for a deploy by this factory.
 * 3. Address prediction (other chain): computeOtherSidePeggedTokenAddress(keyData, deployArgs) — subclasses may use another factory address for remote prediction.
 * 4. Upgrade: owner calls upgradeTo(newImplementation) to upgrade all beacon-proxy tokens (ERC20 factory); Universal factory uses CREATE2, no beacon.
 */
abstract contract GenericTokenFactory is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, IGenericTokenFactory {
    /// @custom:storage-location erc7201:fluent.storage.GenericTokenFactoryStorage
    struct GenericTokenFactoryStorage {
        address beacon;
        address PaymentGateway;
        mapping(address => address) bridgedTokens;
        mapping(address => TokenInfo) tokenInfo;
        uint256[50] __gap;
    }

    /// @notice Token deployment information
    struct TokenInfo {
        address originToken;
        uint256 chainId;
        bool deployed;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.GenericTokenFactoryStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GENERIC_TOKEN_FACTORY_STORAGE_LOCATION = 0x2e7141bc12ac0a34646003e28ce36e2b4a5ec6dcb16986fae278c46570192200;
    /// @dev returns the storage pointer for the GenericTokenFactoryStorage struct.
    function _getGenericTokenFactoryStorage() internal pure returns (GenericTokenFactoryStorage storage $) {
        assembly {
            $.slot := GENERIC_TOKEN_FACTORY_STORAGE_LOCATION
        }
    }

    modifier onlyPaymentGateway() {
        require(msg.sender == _getGenericTokenFactoryStorage().PaymentGateway || msg.sender == owner(), OnlyPaymentGatewayOrOwner());
        _;
    }

    /// @notice Initializes the upgradeable base (call from subclass initialize).
    function __GenericTokenFactory_init(address initialOwner) internal onlyInitializing {
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ========== Public write functions ==========

    /// @inheritdoc IGenericTokenFactory
    function deployToken(bytes calldata keyData, bytes calldata deployArgs) external virtual override returns (address);

    function _deployToken(bytes calldata keyData, bytes calldata deployArgs) internal virtual returns (address, address);

    function _afterDeployToken(address _tokenAddress, address _originToken) internal virtual {
        _setBridgedToken(_originToken, _tokenAddress);
        _setTokenInfo(_tokenAddress, TokenInfo({originToken: _originToken, chainId: block.chainid, deployed: true}));
    }

    // ========== Public view functions ==========

    /// @notice Returns the payment gateway address.
    function paymentGateway() public view virtual returns (address) {
        return _getGenericTokenFactoryStorage().PaymentGateway;
    }

    /// @inheritdoc IGenericTokenFactory

    // ========== Beacon functions ==========

    /// @notice Current implementation address (from beacon).
    function implementation() public view returns (address) {
        return IBeacon(_getGenericTokenFactoryStorage().beacon).implementation();
    }

    /// @notice Upgrades all pegged tokens to a new implementation (via beacon).
    function upgradeTo(address newImplementation) external onlyOwner {
        UpgradeableBeacon(_getGenericTokenFactoryStorage().beacon).upgradeTo(newImplementation);
    }

    function _beaconProxyBytecode(address _beacon) internal pure returns (bytes memory) {
        return abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(_beacon, ""));
    }

    function beacon() public view returns (address) {
        return _getGenericTokenFactoryStorage().beacon;
    }

    /// @inheritdoc IGenericTokenFactory
    function getDeployArgs(string memory tokenName, string memory tokenSymbol, uint8 decimals) external view virtual returns (bytes memory);

    /// @notice Mapping from L1 token address to L2 token address (forwarder for ERC-7201 storage)
    function bridgedTokens(address key) public view virtual returns (address) {
        return _getGenericTokenFactoryStorage().bridgedTokens[key];
    }

    /// @notice Mapping from token address to deployment info (forwarder for ERC-7201 storage)
    function tokenInfo(address key) public view virtual returns (TokenInfo memory) {
        return _getGenericTokenFactoryStorage().tokenInfo[key];
    }

    /// @inheritdoc IGenericTokenFactory
    function computePeggedTokenAddress(bytes calldata keyData, bytes calldata deployArgs) external view virtual override returns (address) {
        return _computeTokenAddress(keyData, deployArgs);
    }

    /// @inheritdoc IGenericTokenFactory
    function computeOtherSidePeggedTokenAddress(
        bytes calldata keyData,
        bytes calldata deployArgs
    ) external view virtual override returns (address) {
        return _computeTokenAddress(keyData, deployArgs);
    }

    /// @dev Subclasses implement: decode keyData/deployArgs and return predicted token address.
    function _computeTokenAddress(bytes calldata keyData, bytes calldata deployArgs) internal view virtual returns (address);

    // ======== Storage functions ========

    /**
     * @notice Sets the payment gateway allowed to call deployToken. Only callable by owner.
     * @param newPaymentGateway Address of the PaymentGateway contract.
     */
    function setPaymentGateway(address newPaymentGateway) external onlyOwner {
        _setPaymentGateway(newPaymentGateway);
    }

    function _setPaymentGateway(address _paymentGateway) internal {
        require(_paymentGateway != address(0), ZeroAddressNotAllowed("PaymentGateway"));
        emit PaymentGatewaySet(paymentGateway(), _paymentGateway);
        _getGenericTokenFactoryStorage().PaymentGateway = _paymentGateway;
    }

    /**
     * @notice Sets the beacon address once the UpgradeableBeacon is deployed.
     * @param newBeacon Address of the Beacon contract.
     */
    function setBeacon(address newBeacon) external onlyOwner {
        _setBeacon(newBeacon);
    }

    function _setBeacon(address _beacon) internal {
        require(_beacon != address(0), ZeroAddressNotAllowed("Beacon"));
        emit BeaconSet(beacon(), _beacon);
        _getGenericTokenFactoryStorage().beacon = _beacon;
    }

    /// @dev Subclasses use this to update bridged token storage (ERC-7201).
    function _setBridgedToken(address _originToken, address _peggedToken) internal {
        _getGenericTokenFactoryStorage().bridgedTokens[_originToken] = _peggedToken;
    }

    /// @dev Subclasses use this to update token info storage (ERC-7201).
    function _setTokenInfo(address _tokenAddress, TokenInfo memory _info) internal {
        _getGenericTokenFactoryStorage().tokenInfo[_tokenAddress] = _info;
    }

    /// @dev Salt for CREATE2 — matches {ERC20TokenFactory._calculateSalt}.
    function _calculateSalt(address gateway, address originToken) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(gateway, originToken));
    }
}
