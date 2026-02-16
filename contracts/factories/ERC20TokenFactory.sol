// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ITokenFactory} from "../interfaces/ITokenFactory.sol";

/**
 * @title ERC20TokenFactory
 * @author Fluent Labs
 * @notice Factory contract for deploying ERC20 pegged tokens as beacon proxies.
 * @dev All deployed tokens share one UpgradeableBeacon; owner can upgrade implementation for all via upgradeTo().
 *      Upgradeable via transparent proxy.
 */
contract ERC20TokenFactory is Initializable, Ownable2StepUpgradeable, ITokenFactory {
    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.ERC20TokenFactoryStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC20_TOKEN_FACTORY_STORAGE_LOCATION = 0x7e7e246e4fb97ee905f8e7f5e1901f4b71035b0cadbe1c1120bbfd15bea2c800;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the upgradeable factory (replaces constructor when used behind a proxy).
    /// @param _initialOwner Owner of the factory (e.g. gateway or deployer).
    /// @param _implementation Initial token implementation for the beacon.
    function initialize(address _initialOwner, address _implementation) public initializer {
        __Ownable_init(_initialOwner);
        __Ownable2Step_init();
        require(_implementation != address(0), ZeroImplementationAddress());
        UpgradeableBeacon _beacon = new UpgradeableBeacon(_implementation, address(this));
        _getERC20TokenFactoryStorage().beacon = address(_beacon);
    }

    /// @notice Upgrades all pegged tokens to a new implementation (via beacon).
    function upgradeTo(address newImplementation) external onlyOwner {
        UpgradeableBeacon(_getERC20TokenFactoryStorage().beacon).upgradeTo(newImplementation);
    }

    function _beaconProxyBytecode(address _beacon) internal pure returns (bytes memory) {
        return abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(_beacon, ""));
    }

    function computeOtherSidePeggedTokenAddress(
        address _gateway,
        address _originToken,
        address _implementation,
        address _factory
    ) external pure override returns (address) {
        bytes32 _salt = _calculateSalt(_gateway, _originToken);
        bytes memory bytecode = _beaconProxyBytecode(_implementation);
        return Create2.computeAddress(_salt, keccak256(bytecode), _factory);
    }

    function computePeggedTokenAddress(address _gateway, address _originToken) external view override returns (address) {
        bytes32 _salt = _calculateSalt(_gateway, _originToken);
        bytes memory bytecode = _beaconProxyBytecode(_getERC20TokenFactoryStorage().beacon);
        return Create2.computeAddress(_salt, keccak256(bytecode));
    }

    function deployToken(address _gateway, address _originToken) external override onlyOwner returns (address) {
        bytes32 salt = _calculateSalt(_gateway, _originToken);
        bytes memory bytecode = _beaconProxyBytecode(_getERC20TokenFactoryStorage().beacon);
        address peggedToken = Create2.deploy(0, salt, bytecode);

        emit TokenDeployed(_originToken, peggedToken);

        return peggedToken;
    }

    function _calculateSalt(address _gateway, address _originToken) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_gateway, _originToken));
    }

    function _getERC20TokenFactoryStorage() private pure returns (ERC20TokenFactoryStorage storage $) {
        assembly {
            $.slot := ERC20_TOKEN_FACTORY_STORAGE_LOCATION
        }
    }

    /// @notice Current implementation address (from beacon).
    function implementation() public view returns (address) {
        return IBeacon(_getERC20TokenFactoryStorage().beacon).implementation();
    }

    /// @notice Beacon used by all pegged tokens deployed by this factory.
    function beacon() public view returns (address) {
        return _getERC20TokenFactoryStorage().beacon;
    }
}
