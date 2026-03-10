// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {GenericTokenFactory} from "./GenericTokenFactory.sol";
import {IGenericTokenFactory} from "../interfaces/IGenericTokenFactory.sol";
import {UniversalTokenSDK} from "../libraries/UniversalTokenSDK.sol";

/**
 * @title UniversalTokenFactory
 * @author Fluent Labs
 * @notice Deploys Universal (precompile) pegged tokens via CREATE2 using UniversalTokenSDK; used for L2 bridge representation of L1 tokens.
 * @dev Only callable by PaymentGateway or owner. keyData = abi.encode(originToken). No chainId: same origin token => same pegged address per factory across chains.
 *      deployArgs = abi.encode(name, symbol, decimals, initialSupply, minter, pauser). Salt = keccak256(BRIDGE_TOKEN_PREFIX, originToken).
 *      No beacon; each deployment is immutable init code from UniversalTokenSDK.createDeploymentData.
 * @notice Workflows:
 * 1. First receive of an origin token on this chain: gateway calls deployToken(keyData, deployArgs); factory deploys via Create2 with SDK deployment data and salt.
 * 2. getDeployArgs(name, symbol, decimals): returns abi.encode(name, symbol, decimals, 0, msg.sender, msg.sender) (zero initial supply, deployer as minter/pauser).
 * 3. Address prediction: computePeggedTokenAddress / computeOtherSidePeggedTokenAddress use UniversalTokenSDK.computeTokenAddress(factory, originToken, ...).
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
    function deployToken(bytes calldata keyData, bytes calldata deployArgs) external override onlyPaymentGateway returns (address) {
        (address tokenAddress, address originToken) = _deployToken(keyData, deployArgs);
        _afterDeployToken(tokenAddress, originToken);

        emit TokenDeployed(originToken, tokenAddress);

        return tokenAddress;
    }

    function _deployToken(
        bytes calldata keyData,
        bytes calldata deployArgs
    ) internal override returns (address tokenAddress, address originToken) {
        originToken = _decodeKeyData(keyData);
        (string memory name, string memory symbol, uint8 decimals, uint256 initialSupply, address minter, address pauser) = _decodeDeployArgs(
            deployArgs
        );

        require(originToken != address(0), InvalidOriginToken());
        require(bridgedTokens(originToken) == address(0), TokenAlreadyDeployed());

        bytes memory deploymentData = UniversalTokenSDK.createDeploymentData(name, symbol, decimals, initialSupply, minter, pauser);
        bytes32 salt = _bridgeTokenSalt(originToken);

        return (Create2.deploy(0, salt, deploymentData), originToken);
    }

    /**
     * @notice Returns the deployment arguments for a token
     * @param tokenName The name of the token
     * @param tokenSymbol The symbol of the token
     * @param decimals The decimals of the token
     * @dev The initial supply is 0 and the deployer is the sender.
     * @return Deployment arguments
     */
    function getDeployArgs(string memory tokenName, string memory tokenSymbol, uint8 decimals) external view override returns (bytes memory) {
        address deployer = _msgSender();
        return abi.encode(tokenName, tokenSymbol, decimals, 0, deployer, deployer);
    }

    /**
     * @notice Computes the pegged token address for a Universal token deployed by a factory.
     * @param keyData Encoded as abi.encode(originToken)
     * @param deployArgs Encoded as abi.encode(name, symbol, decimals, initialSupply, minter, pauser)
     * @param factory The UniversalTokenFactory address that will perform the CREATE2 deployment
     * @return predicted The predicted token address
     */
    function computeTokenAddress(bytes calldata keyData, bytes calldata deployArgs, address factory) external pure returns (address predicted) {
        address originToken = abi.decode(keyData, (address));
        (string memory name, string memory symbol, uint8 decimals, uint256 initialSupply, address minter, address pauser) = abi.decode(
            deployArgs,
            (string, string, uint8, uint256, address, address)
        );

        return UniversalTokenSDK.computeTokenAddress(factory, originToken, name, symbol, decimals, initialSupply, minter, pauser);
    }

    /// @inheritdoc GenericTokenFactory
    function _computeTokenAddress(bytes calldata keyData, bytes calldata deployArgs) internal view override returns (address) {
        address originToken = _decodeKeyData(keyData);
        (string memory name, string memory symbol, uint8 decimals, uint256 initialSupply, address minter, address pauser) = _decodeDeployArgs(
            deployArgs
        );
        return UniversalTokenSDK.computeTokenAddress(address(this), originToken, name, symbol, decimals, initialSupply, minter, pauser);
    }

    /// @dev Uses UniversalTokenSDK to deploy with CREATE2 and updates base storage (internal only).
    function _deployWithSDK(
        address originToken,
        uint256 chainId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) internal returns (address tokenAddress) {}

    /// @dev Salt for CREATE2 (must match SDK: keccak256(BRIDGE_TOKEN_PREFIX, originToken)). No chainId.
    function _bridgeTokenSalt(address originToken) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(UniversalTokenSDK.BRIDGE_TOKEN_PREFIX, originToken));
    }

    function _decodeKeyData(bytes calldata keyData) internal pure returns (address originToken) {
        return abi.decode(keyData, (address));
    }

    function _decodeDeployArgs(
        bytes calldata deployArgs
    ) internal pure returns (string memory name, string memory symbol, uint8 decimals, uint256 initialSupply, address minter, address pauser) {
        return abi.decode(deployArgs, (string, string, uint8, uint256, address, address));
    }
}
