// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {GenericTokenFactory} from "../factories/GenericTokenFactory.sol";

/**
 * @title ERC721TokenFactory
 * @author Fluent Labs
 * @notice Deploys ERC721 pegged collections as BeaconProxy instances; salt and layout match {ERC20TokenFactory} for cross-chain parity.
 */
contract ERC721TokenFactory is GenericTokenFactory {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address implementation) external initializer {
        __GenericTokenFactory_init(initialOwner);
        require(implementation != address(0), ZeroAddressNotAllowed("Implementation"));
        address beacon = address(new UpgradeableBeacon(implementation, address(this)));
        _setBeacon(beacon);
    }

    /// @inheritdoc GenericTokenFactory
    function deployToken(address gateway, address originToken, bytes calldata deployArgs) external override onlyPaymentGateway returns (address) {
        address tokenAddress = _deployToken(gateway, originToken, deployArgs);
        _afterDeployToken(tokenAddress, originToken);
        emit TokenDeployed(originToken, tokenAddress);
        return tokenAddress;
    }

    function _deployToken(address gateway, address originToken, bytes calldata /*deployArgs*/) internal override returns (address) {
        require(gateway != address(0), ZeroAddressNotAllowed("Gateway"));
        require(originToken != address(0), ZeroAddressNotAllowed("OriginToken"));
        bytes32 salt = _calculateSalt(gateway, originToken);
        bytes memory bytecode = _beaconProxyBytecode(beacon());
        return Create2.deploy(0, salt, bytecode);
    }

    function getDeployArgs(
        string memory /*tokenName*/,
        string memory /*tokenSymbol*/,
        uint8 /*decimals*/
    ) external pure override returns (bytes memory) {
        return bytes("");
    }

    /// @inheritdoc GenericTokenFactory
    function _computeTokenAddress(address gateway, address originToken, bytes calldata /*deployArgs*/) internal view override returns (address) {
        bytes32 salt = _calculateSalt(gateway, originToken);
        bytes memory bytecode = _beaconProxyBytecode(beacon());
        return Create2.computeAddress(salt, keccak256(bytecode));
    }
}
