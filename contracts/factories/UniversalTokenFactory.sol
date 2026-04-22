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
 *      deployArgs = abi.encode(name, symbol, decimals, initialSupply, minter, pauser, wrapped). Salt = keccak256(abi.encodePacked(gateway, originToken)).
 *      No beacon; each deployment is immutable init code from UniversalTokenSDK.createDeploymentData.
 *
 *      The `wrapped` flag (7th deploy arg) instructs the L2 precompile to expose WETH9-style
 *      `deposit()` / `withdraw(uint256)` entrypoints on the deployed token. It must be set
 *      to `true` when deploying Universal-WETH (paired with {WETHGateway}); it should remain
 *      `false` for generic bridged ERC20s (paired with {ERC20Gateway}).
 */
contract UniversalTokenFactory is GenericTokenFactory {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
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
        (
            string memory name,
            string memory symbol,
            uint8 decimals,
            uint256 initialSupply,
            address minter,
            address pauser,
            bool wrapped
        ) = _decodeDeployArgs(deployArgs);

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
        bytes memory deploymentData = _deploymentData(name, symbol, decimals, initialSupply, minter, pauser, wrapped);
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
        // Pack into the format expected by _decodeDeployArgs and _deployToken.
        // `wrapped = false` — generic bridged ERC20s never want WETH9 deposit/withdraw.
        // Callers that need a wrapped token (e.g. {WETHGateway} bootstrap) must build
        // the deploy args blob directly with `wrapped = true`.
        return abi.encode(tokenName, tokenSymbol, decimals, uint256(0), deployer, deployer, false);
    }

    // ============ Internal ============

    /// @inheritdoc GenericTokenFactory
    function _computeTokenAddress(address gateway, address originToken, bytes calldata deployArgs) internal view override returns (address) {
        // Decode the same args that _deployToken would use
        (
            string memory name,
            string memory symbol,
            uint8 decimals,
            uint256 initialSupply,
            address minter,
            address pauser,
            bool wrapped
        ) = _decodeDeployArgs(deployArgs);
        // Predict the CREATE2 address without deploying — used for pre-registration checks
        return
            Create2.computeAddress(
                _calculateSalt(gateway, originToken),
                keccak256(_deploymentData(name, symbol, decimals, initialSupply, minter, pauser, wrapped))
            );
    }

    /**
     * @dev Extracts deploy arguments from the ABI-encoded payload.
     *      Layout: (string name, string symbol, uint8 decimals, uint256 initialSupply,
     *               address minter, address pauser, bool wrapped).
     */
    function _decodeDeployArgs(
        bytes calldata deployArgs
    )
        internal
        pure
        returns (string memory name, string memory symbol, uint8 decimals, uint256 initialSupply, address minter, address pauser, bool wrapped)
    {
        return abi.decode(deployArgs, (string, string, uint8, uint256, address, address, bool));
    }

    /**
     * @dev Constructs the deployment bytecode with the 0x45524320 magic prefix expected by the L2 precompile.
     *
     *      Encoding is version-branched on `wrapped`:
     *
     *        - `wrapped == false` → legacy V1 payload (6 fixed fields). Byte-identical to
     *           the pre-`wrapped` factory output, so bridged ERC20s deployed through either
     *           factory version land at the same CREATE2 address.
     *        - `wrapped == true`  → V2 payload (6 fields + `bool wrapped`). Matches the
     *           size threshold `InitialSettings::decode_with_prefix` uses to activate the
     *           precompile's WETH9 `deposit` / `withdraw` surface on this token.
     *
     *      The Rust precompile gates `deposit` / `withdraw` on
     *      `contract_metadata().len() >= INITIAL_SETTINGS_V2_SIZE`; emitting the shorter V1
     *      blob for non-wrapped tokens keeps that gate disabled by construction.
     *
     *      Fixed-size (non-dynamic) ABI encoding is mandatory — the precompile decoder
     *      does not follow dynamic tail offsets. That is why `name` / `symbol` are packed
     *      as `bytes32`, truncating at 32 bytes.
     */
    function _deploymentData(
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser,
        bool wrapped
    ) internal pure returns (bytes memory deploymentData) {
        // 0x45524320 ("ERC ") is the magic prefix the L2 precompile at 0x520008
        // expects as the first 4 bytes of deployment bytecode to identify ERC20 tokens.
        if (!wrapped) {
            // V1: (bytes32, bytes32, uint8, uint256, address, address) — 192 bytes after prefix.
            return
                abi.encodePacked(
                    bytes4(0x45524320),
                    abi.encode(_stringToBytes32(name), _stringToBytes32(symbol), decimals, initialSupply, minter, pauser)
                );
        }
        // V2: append `bool wrapped` → 224 bytes after prefix; crosses the precompile's
        // V2 size threshold and enables WETH9 deposit/withdraw on this token.
        // minter is set to address(0) to avoid the precompile from calling `mint` for Wrapped UST
        return
            abi.encodePacked(
                bytes4(0x45524320),
                abi.encode(_stringToBytes32(name), _stringToBytes32(symbol), decimals, initialSupply, address(0), pauser, wrapped)
            );
    }

    function _stringToBytes32(string memory str) internal pure returns (bytes32 result) {
        bytes memory b = bytes(str);
        assembly {
            result := mload(add(b, 32))
        }
    }
}
