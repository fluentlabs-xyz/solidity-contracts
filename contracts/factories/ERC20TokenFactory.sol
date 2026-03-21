// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {GenericTokenFactory} from "./GenericTokenFactory.sol";

/**
 * @title ERC20TokenFactory
 * @author Fluent Labs
 * @notice Deploys ERC20 pegged tokens as BeaconProxy instances for the bridge; one UpgradeableBeacon per factory.
 * @dev Only callable by PaymentGateway or owner. keyData = abi.encode(gateway, originToken); deployArgs = "" (metadata comes from origin on first receive).
 *      Salt = keccak256(gateway, originToken). Owner can upgrade all pegged tokens at once via upgradeTo(newImplementation) on the beacon.
 * @notice Workflows:
 * 1. First receive of an origin token on this chain: gateway calls deployToken(keyData, deployArgs); factory deploys BeaconProxy with CREATE2 and registers origin -> pegged.
 * 2. Address prediction: computePeggedTokenAddress(keyData, "") and computeOtherSidePeggedTokenAddress(keyData, "") use same salt and beacon proxy bytecode for L1/L2 parity.
 * 3. getDeployArgs: returns empty bytes (ERC20 pegged tokens take name/symbol/decimals from origin token at receive time).
 */
contract ERC20TokenFactory is GenericTokenFactory {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the upgradeable factory (replaces constructor when used behind a proxy).
     * @param _initialOwner Owner of the factory (e.g. gateway or deployer).
     * @param _implementation Initial token implementation for the beacon.
     */
    function initialize(address _initialOwner, address _implementation) external initializer {
        __GenericTokenFactory_init(_initialOwner);
        require(_implementation != address(0), ZeroAddressNotAllowed("Implementation"));
        /// @dev this is a dedicated beacon for ERC20 tokens deployment, so we don't need to use this contract as a beacon
        address _beacon = address(new UpgradeableBeacon(_implementation, address(this)));

        _setBeacon(_beacon);
    }

    // ========== Deploy functions ==========

    /// @inheritdoc GenericTokenFactory
    function deployToken(bytes calldata keyData, bytes calldata deployArgs) external override onlyPaymentGateway returns (address) {
        (address tokenAddress, address originToken) = _deployToken(keyData, deployArgs);
        _afterDeployToken(tokenAddress, originToken);

        emit TokenDeployed(originToken, tokenAddress);

        return tokenAddress;
    }

    function _deployToken(bytes calldata keyData, bytes calldata) internal override returns (address, address) {
        (address gateway, address originToken) = _decodeKeyData(keyData);

        require(gateway != address(0), ZeroAddressNotAllowed("Gateway"));
        require(originToken != address(0), ZeroAddressNotAllowed("OriginToken"));

        bytes32 salt = _calculateSalt(gateway, originToken);
        bytes memory bytecode = _beaconProxyBytecode(beacon());

        return (Create2.deploy(0, salt, bytecode), originToken);
    }

    // ========== Public view functions ==========

    /**
     * @dev The deploy args are empty for ERC20 tokens as the token metadata is not needed.
     */
    function getDeployArgs(
        string memory /*tokenName*/,
        string memory /*tokenSymbol*/,
        uint8 /*decimals*/
    ) external pure override returns (bytes memory) {
        return bytes("");
    }

    /// @dev Single implementation for both this chain and other chain (same salt + beacon proxy).
    /// @inheritdoc GenericTokenFactory
    function _computeTokenAddress(bytes calldata keyData, bytes calldata) internal view override returns (address) {
        (address _gateway, address _originToken) = _decodeKeyData(keyData);
        bytes32 _salt = _calculateSalt(_gateway, _originToken);
        bytes memory bytecode = _beaconProxyBytecode(beacon());
        return Create2.computeAddress(_salt, keccak256(bytecode));
    }

    // ========== Internal functions ==========

    function _decodeKeyData(bytes calldata keyData) internal pure returns (address _gateway, address _originToken) {
        return abi.decode(keyData, (address, address));
    }
}
