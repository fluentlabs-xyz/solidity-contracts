// SPDX-License-Identifier: Apache-2.0
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
        // Prevent the implementation contract from being initialized directly
        _disableInitializers();
    }

    /**
     * @notice Initializes the factory when used behind a proxy.
     */
    function initialize(address initialOwner) external initializer {
        // Set up ownership and base factory state via the parent initializer
        __GenericTokenFactory_init(initialOwner);
    }

    /// @inheritdoc IGenericTokenFactory
    function deployToken(
        address gateway,
        address originToken,
        bytes calldata deployArgs
    ) external override onlyPaymentGateway returns (address) {
        // Deploy the universal token via CREATE2 with the precompile magic prefix
        address tokenAddress = _deployToken(gateway, originToken, deployArgs);
        // Register the bidirectional mapping between origin and bridged token
        _afterDeployToken(tokenAddress, originToken);

        // Emit so off-chain indexers can discover the new pegged token address
        emit TokenDeployed(originToken, tokenAddress);

        return tokenAddress;
    }

    // ============ Deploy ============

    /**
     * @dev Deploys a universal token via the L2 precompile at 0x520008 using CREATE2.
     */
    function _deployToken(address gateway, address originToken, bytes calldata deployArgs) internal override returns (address) {
        // Unpack the ABI-encoded deployment parameters from the caller
        (string memory name, string memory symbol, uint8 decimals, uint256 initialSupply, address minter, address pauser) = _decodeDeployArgs(
            deployArgs
        );

        // Validate all inputs before spending gas on deployment
        // Gateway must be a valid address — it receives minting authority
        require(gateway != address(0), ZeroAddressNotAllowed("gateway"));
        // Origin token address is used as the identity key for the pegged mapping
        require(originToken != address(0), InvalidOriginToken());
        // Prevent deploying a second pegged token for the same origin
        require(bridgedTokens(originToken) == address(0), TokenAlreadyDeployed());
        // Token metadata must be non-empty — the precompile requires valid ERC20 metadata
        require(bytes(name).length > 0, ZeroValueNotAllowed("name"));
        require(bytes(symbol).length > 0, ZeroValueNotAllowed("symbol"));
        // Decimals of 0 is technically valid for ERC20, but disallowed here
        // because it signals a misconfigured deployment
        require(decimals > 0, ZeroValueNotAllowed("decimals"));

        // Build init code with the 0x45524320 magic prefix for the L2 precompile
        bytes memory deploymentData = _deploymentData(name, symbol, decimals, initialSupply, minter, pauser);
        // Deterministic salt from gateway+origin ensures one pegged token per pair
        bytes32 salt = _calculateSalt(gateway, originToken);

        // CREATE2 deployment — address is predictable from salt + init code hash
        return Create2.deploy(0, salt, deploymentData);
    }

    // ============ Views ============

    /**
     * @notice Returns the deployment arguments for a token
     * @param tokenName The name of the token
     * @param tokenSymbol The symbol of the token
     * @param decimals The decimals of the token
     * @dev The initial supply is 0 and the deployer is the sender.
     */
    function getDeployArgs(string memory tokenName, string memory tokenSymbol, uint8 decimals) external view override returns (bytes memory) {
        // Use the caller as both minter and pauser, with zero initial supply
        address deployer = _msgSender();
        // Pack into the format expected by _decodeDeployArgs and _deployToken
        return abi.encode(tokenName, tokenSymbol, decimals, 0, deployer, deployer);
    }

    // ============ Internal ============

    /// @inheritdoc GenericTokenFactory
    function _computeTokenAddress(
        address gateway,
        address originToken,
        bytes calldata deployArgs
    ) internal view override returns (address) {
        // Decode the same args that _deployToken would use
        (string memory name, string memory symbol, uint8 decimals, uint256 initialSupply, address minter, address pauser) = _decodeDeployArgs(
            deployArgs
        );
        // Predict the CREATE2 address without deploying — used for pre-registration checks
        return
            Create2.computeAddress(
                _calculateSalt(gateway, originToken),
                keccak256(_deploymentData(name, symbol, decimals, initialSupply, minter, pauser))
            );
    }

    /**
     * @dev Extracts deploy arguments (name, symbol, decimals) from the ABI-encoded payload.
     */
    function _decodeDeployArgs(
        bytes calldata deployArgs
    ) internal pure returns (string memory name, string memory symbol, uint8 decimals, uint256 initialSupply, address minter, address pauser) {
        // Layout must match the encoding in getDeployArgs: (name, symbol, decimals, supply, minter, pauser)
        return abi.decode(deployArgs, (string, string, uint8, uint256, address, address));
    }

    /**
     * @dev Constructs the deployment bytecode with the 0x45524320 magic prefix expected by the L2 precompile.
     */
    function _deploymentData(
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) internal pure returns (bytes memory deploymentData) {
        // 0x45524320 ("ERC ") is the magic prefix the L2 precompile at 0x520008
        // expects as the first 4 bytes of deployment bytecode to identify ERC20 tokens.
        // The remaining bytes must be abi.encode(bytes32, bytes32, uint8, uint256, address, address)
        // — fixed-size encoding matching the Rust InitialSettings struct layout.
        // Using string types here would produce dynamic ABI encoding which the precompile cannot decode.
        return
            abi.encodePacked(
                bytes4(0x45524320),
                abi.encode(_stringToBytes32(name), _stringToBytes32(symbol), decimals, initialSupply, minter, pauser)
            );
    }

    function _stringToBytes32(string memory str) internal pure returns (bytes32 result) {
        bytes memory b = bytes(str);
        assembly {
            result := mload(add(b, 32))
        }
    }
}
