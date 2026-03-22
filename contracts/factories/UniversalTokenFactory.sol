// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {GenericTokenFactory} from "./GenericTokenFactory.sol";
import {IGenericTokenFactory} from "../interfaces/IGenericTokenFactory.sol";

/**
 * @title UniversalTokenFactory
 * @author Fluent Labs
 * @notice Deploys Universal (precompile) pegged tokens via CREATE2 using UniversalTokenSDK; used for L2 bridge representation of L1 tokens.
 * @dev Only callable by PaymentGateway or owner. Same external API as {ERC20TokenFactory}: deployToken(gateway, originToken, deployArgs).
 *      deployArgs = abi.encode(name, symbol, decimals, initialSupply, minter, pauser). Salt = keccak256(abi.encodePacked(gateway, originToken)).
 *      No beacon; each deployment is immutable init code from UniversalTokenSDK.createDeploymentData.
 */
contract UniversalTokenFactory is GenericTokenFactory {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the factory when used behind a proxy.
    function initialize(address initialOwner) external initializer {
        __GenericTokenFactory_init(initialOwner);
    }

    /// @inheritdoc IGenericTokenFactory
    function deployToken(
        address gateway,
        address originToken,
        bytes calldata deployArgs
    ) external override onlyPaymentGateway returns (address) {
        address tokenAddress = _deployToken(gateway, originToken, deployArgs);
        _afterDeployToken(tokenAddress, originToken);

        emit TokenDeployed(originToken, tokenAddress);

        return tokenAddress;
    }

    function _deployToken(address gateway, address originToken, bytes calldata deployArgs) internal override returns (address) {
        (string memory name, string memory symbol, uint8 decimals, uint256 initialSupply, address minter, address pauser) = _decodeDeployArgs(
            deployArgs
        );

        require(gateway != address(0), ZeroAddressNotAllowed("gateway"));
        require(originToken != address(0), InvalidOriginToken());
        require(bridgedTokens(originToken) == address(0), TokenAlreadyDeployed());
        require(bytes(name).length > 0, ZeroValueNotAllowed("name"));
        require(bytes(symbol).length > 0, ZeroValueNotAllowed("symbol"));
        require(decimals > 0, ZeroValueNotAllowed("decimals"));

        bytes memory deploymentData = _deploymentData(name, symbol, decimals, initialSupply, minter, pauser);
        bytes32 salt = _calculateSalt(gateway, originToken);

        return Create2.deploy(0, salt, deploymentData);
    }

    /**
     * @notice Returns the deployment arguments for a token
     * @param tokenName The name of the token
     * @param tokenSymbol The symbol of the token
     * @param decimals The decimals of the token
     * @dev The initial supply is 0 and the deployer is the sender.
     */
    function getDeployArgs(string memory tokenName, string memory tokenSymbol, uint8 decimals) external view override returns (bytes memory) {
        address deployer = _msgSender();
        return abi.encode(tokenName, tokenSymbol, decimals, 0, deployer, deployer);
    }

    /// @inheritdoc GenericTokenFactory
    function _computeTokenAddress(
        address gateway,
        address originToken,
        bytes calldata deployArgs
    ) internal view override returns (address) {
        (string memory name, string memory symbol, uint8 decimals, uint256 initialSupply, address minter, address pauser) = _decodeDeployArgs(
            deployArgs
        );
        return
            Create2.computeAddress(
                _calculateSalt(gateway, originToken),
                keccak256(_deploymentData(name, symbol, decimals, initialSupply, minter, pauser))
            );
    }

    function _decodeDeployArgs(
        bytes calldata deployArgs
    ) internal pure returns (string memory name, string memory symbol, uint8 decimals, uint256 initialSupply, address minter, address pauser) {
        return abi.decode(deployArgs, (string, string, uint8, uint256, address, address));
    }

    function _deploymentData(
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) internal pure returns (bytes memory deploymentData) {
        return abi.encodePacked(bytes4(0x45524320), abi.encode(name, symbol, decimals, initialSupply, minter, pauser));
    }
}
