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
    // ============ Types ============

    /**
     * @dev Token deployment information.
     */
    struct TokenInfo {
        /// @dev Address of the original token on the origin chain.
        address originToken;
        /// @dev Chain ID where the original token lives.
        uint256 chainId;
        /// @dev True once the pegged token has been deployed.
        bool deployed;
    }

    // ============ Storage ============
    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.GenericTokenFactoryStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GENERIC_TOKEN_FACTORY_STORAGE_LOCATION = 0x2e7141bc12ac0a34646003e28ce36e2b4a5ec6dcb16986fae278c46570192200;

    /// @custom:storage-location erc7201:fluent.storage.GenericTokenFactoryStorage
    struct GenericTokenFactoryStorage {
        /// @dev Beacon contract backing all pegged token proxies.
        address _beacon;
        /// @dev Gateway authorized to deploy tokens via {deployToken}.
        address _paymentGateway;
        /// @dev Origin token address to locally deployed pegged token address.
        mapping(address => address) _bridgedTokens;
        /// @dev Pegged token address to its deployment metadata.
        mapping(address => TokenInfo) _tokenInfo;
        /// @dev Reserved for future storage fields.
        uint256[50] __gap;
    }

    /// @dev Returns the storage pointer for the GenericTokenFactoryStorage struct.
    function _getGenericTokenFactoryStorage() internal pure returns (GenericTokenFactoryStorage storage $) {
        // load the ERC-7201 diamond storage slot via inline assembly
        assembly ("memory-safe") {
            $.slot := GENERIC_TOKEN_FACTORY_STORAGE_LOCATION
        }
    }

    /**
     * @dev Restricts to the configured payment gateway or contract owner.
     */
    modifier onlyPaymentGateway() {
        // owner bypass allows manual token deployment during bootstrap or emergencies
        require(msg.sender == _getGenericTokenFactoryStorage()._paymentGateway || msg.sender == owner(), OnlyPaymentGatewayOrOwner());
        _;
    }

    /// @dev Initializes the upgradeable base (call from subclass initialize).
    function __GenericTokenFactory_init(address initialOwner) internal onlyInitializing {
        // two-step ownership prevents accidental transfers to wrong addresses
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        // enable UUPS proxy upgrade mechanism for the factory itself
        __UUPSUpgradeable_init();
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ============ Public write functions ============

    /// @inheritdoc IGenericTokenFactory
    function deployToken(address gateway, address originToken, bytes calldata deployArgs) external virtual override returns (address);

    /** @dev Hook for subclasses to implement chain-specific token deployment logic. */
    function _deployToken(address gateway, address originToken, bytes calldata deployArgs) internal virtual returns (address);

    /** @dev Records the bridged token mapping and deployment metadata after a successful deploy. */
    function _afterDeployToken(address tokenAddress, address originToken) internal virtual {
        // bidirectional mapping: origin->pegged for lookups, pegged->info for metadata
        _setBridgedToken(originToken, tokenAddress);
        _setTokenInfo(tokenAddress, TokenInfo({originToken: originToken, chainId: block.chainid, deployed: true}));
    }

    // ============ Public view functions ============

    /**
     * @notice Returns the payment gateway address.
     */
    function paymentGateway() public view virtual returns (address) {
        // read from ERC-7201 namespaced storage to avoid slot collisions
        return _getGenericTokenFactoryStorage()._paymentGateway;
    }

    // ============ Beacon functions ============

    /**
     * @notice Current implementation address (from beacon).
     */
    function implementation() public view returns (address) {
        // forwards to the beacon's implementation getter for transparency
        return IBeacon(_getGenericTokenFactoryStorage()._beacon).implementation();
    }

    /**
     * @notice Upgrades all pegged tokens to a new implementation (via beacon).
     */
    function upgradeTo(address newImplementation) external onlyOwner {
        // single beacon upgrade atomically updates every BeaconProxy token
        UpgradeableBeacon(_getGenericTokenFactoryStorage()._beacon).upgradeTo(newImplementation);
    }

    /** @dev Returns the creation bytecode for a BeaconProxy pointing at the stored beacon. */
    function _beaconProxyBytecode(address beaconAddr) internal pure returns (bytes memory) {
        // encode beacon address + empty init data into constructor args for CREATE2
        return abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beaconAddr, ""));
    }

    /// @inheritdoc IGenericTokenFactory
    function beacon() public view returns (address) {
        // exposes the UpgradeableBeacon address backing all pegged token proxies
        return _getGenericTokenFactoryStorage()._beacon;
    }

    /// @inheritdoc IGenericTokenFactory
    function getDeployArgs(string memory tokenName, string memory tokenSymbol, uint8 decimals) external view virtual returns (bytes memory);

    /**
     * @notice Mapping from origin token address to pegged token address (forwarder for ERC-7201 storage).
     */
    function bridgedTokens(address key) public view virtual returns (address) {
        // returns address(0) when no pegged token has been deployed for this origin
        return _getGenericTokenFactoryStorage()._bridgedTokens[key];
    }

    /**
     * @notice Mapping from token address to deployment info (forwarder for ERC-7201 storage).
     */
    function tokenInfo(address key) public view virtual returns (TokenInfo memory) {
        // returns a zero-initialized struct when no info exists for the given token
        return _getGenericTokenFactoryStorage()._tokenInfo[key];
    }

    /// @inheritdoc IGenericTokenFactory
    function computeTokenAddress(
        address gateway,
        address originToken,
        bytes calldata deployArgs
    ) external view virtual override returns (address) {
        // delegates to internal helper so subclasses can override the address derivation
        // result matches the CREATE2 address that deployToken would produce
        return _computeTokenAddress(gateway, originToken, deployArgs);
    }

    /// @inheritdoc IGenericTokenFactory
    function computeOtherSidePeggedTokenAddress(
        address gateway,
        address originToken,
        bytes calldata deployArgs
    ) external view virtual override returns (address) {
        // default: same logic as local prediction; subclasses may use a remote factory address
        // allows callers to predict the pegged token address on the remote chain
        return _computeTokenAddress(gateway, originToken, deployArgs);
    }

    /// @dev Subclasses implement: decode keyData/deployArgs and return predicted token address.
    function _computeTokenAddress(address gateway, address originToken, bytes calldata deployArgs) internal view virtual returns (address);

    // ============ Storage functions ============

    /**
     * @notice Sets the payment gateway allowed to call deployToken. Only callable by owner.
     * @param newPaymentGateway Address of the PaymentGateway contract.
     */
    function setPaymentGateway(address newPaymentGateway) external onlyOwner {
        // delegate to internal setter which performs zero-address validation
        _setPaymentGateway(newPaymentGateway);
    }

    /** @dev Validates and stores the payment gateway address. Reverts on zero address. */
    function _setPaymentGateway(address newPaymentGateway) internal {
        require(newPaymentGateway != address(0), ZeroAddressNotAllowed("PaymentGateway"));
        // emit old -> new for off-chain indexers before writing storage
        emit PaymentGatewaySet(paymentGateway(), newPaymentGateway);
        _getGenericTokenFactoryStorage()._paymentGateway = newPaymentGateway;
    }

    /**
     * @notice Sets the beacon address once the UpgradeableBeacon is deployed.
     * @param newBeacon Address of the Beacon contract.
     */
    function setBeacon(address newBeacon) external onlyOwner {
        // delegate to internal setter which performs zero-address validation
        _setBeacon(newBeacon);
    }

    /** @dev Validates and stores the beacon address. Reverts on zero address. */
    function _setBeacon(address newBeacon) internal {
        require(newBeacon != address(0), ZeroAddressNotAllowed("Beacon"));
        // emit old -> new for off-chain indexers before writing storage
        emit BeaconSet(beacon(), newBeacon);
        _getGenericTokenFactoryStorage()._beacon = newBeacon;
    }

    /// @dev Subclasses use this to update bridged token storage (ERC-7201).
    function _setBridgedToken(address originToken, address peggedToken) internal {
        // maps origin chain token to the locally deployed pegged token
        _getGenericTokenFactoryStorage()._bridgedTokens[originToken] = peggedToken;
    }

    /// @dev Subclasses use this to update token info storage (ERC-7201).
    function _setTokenInfo(address tokenAddress, TokenInfo memory info) internal {
        // stores reverse lookup: pegged address -> origin metadata
        _getGenericTokenFactoryStorage()._tokenInfo[tokenAddress] = info;
    }

    /// @dev Salt for CREATE2 — matches {ERC20TokenFactory._calculateSalt}.
    function _calculateSalt(address gateway, address originToken) internal pure returns (bytes32) {
        // deterministic salt from gateway+origin ensures one pegged token per origin per gateway
        return keccak256(abi.encodePacked(gateway, originToken));
    }
}
