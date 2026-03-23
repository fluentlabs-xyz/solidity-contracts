// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {FluentBridge} from "../bridge/FluentBridge.sol";
import {ERC20PeggedToken} from "../tokens/ERC20PeggedToken.sol";

import {IERC20Gateway} from "../interfaces/gateways/IERC20Gateway.sol";
import {IGenericTokenFactory} from "../interfaces/IGenericTokenFactory.sol";
import {GatewayBase} from "./GatewayBase.sol";

/**
 * @title ERC20Gateway
 * @author Fluent Labs
 *
 * @notice Gateway for bridging ERC20 assets between chains through `FluentBridge`.
 * @dev Handles two token modes:
 *      1) Origin-token mode: token has no local pegged mapping; tokens are escrowed on source chain and
 *         destination chain mints/releases a pegged representation.
 *      2) Pegged-token mode: token is mapped to an origin token; local pegged tokens are burned and
 *         destination chain releases origin tokens.
 * @dev Bridge-delivered receive functions (`receivePeggedTokens`, `receiveOriginTokens`) are restricted to
 *      the configured local bridge and verify the remote gateway sender via `getNativeSender()`.
 * @dev Supports deterministic pegged-token address derivation for both beacon-proxy and universal-token
 *      deployments using stored remote configuration (`otherSide`, factory, beacon/chainId).
 * @dev Admin controls include remote routing config and token-mapping maintenance.
 */
contract ERC20Gateway is GatewayBase, IERC20Gateway {
    // SafeERC20 wraps all IERC20 calls with revert-on-failure checks,
    // handling non-standard tokens that return false instead of reverting
    using SafeERC20 for IERC20;

    /**
     * @dev Magic prefix used in Universal token CREATE2 init-code encoding.
     * @dev "ERC "
     */
    // 0x45524320 == ASCII "ERC " — the L2 precompile recognizes this prefix to
    // distinguish universal-token deploys from arbitrary CREATE2 bytecode
    bytes4 private constant UNIVERSAL_TOKEN_MAGIC_BYTES = bytes4(0x45524320);

    /// @custom:storage-location erc7201:fluent.storage.ERC20GatewayStorage
    struct ERC20GatewayStorage {
        /// @dev True when the remote chain uses UniversalTokenFactory (precompile-based).
        bool _isOtherSideUniversal;
        /// @dev Local token factory for deploying pegged tokens.
        address _tokenFactory;
        /// @dev Token implementation address on the remote chain (for address computation).
        address _otherSideTokenImplementation;
        /// @dev Factory address on the remote chain (for address computation).
        address _otherSideFactory;
        /// @dev Beacon address on the remote chain (for beacon proxy address computation).
        address _otherSideBeacon;
        /// @dev Origin token address to locally deployed pegged token address.
        mapping(address => address) _tokenMapping;
        /// @dev Reserved for future storage fields.
        uint256[50] __gap;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.ERC20GatewayStorage")) - 1)) & ~bytes32(uint256(0xff))
    // This deterministic slot hash isolates ERC20Gateway storage from the rest of the
    // proxy's storage layout, preventing slot collisions during upgrades (ERC-7201 pattern)
    bytes32 private constant ERC20_GATEWAY_STORAGE_LOCATION = 0xe252cab26214ab2f0e4d4e6f063d78ba24b618cf5f8fd25d1b9aef671b7f9100;

    /** @dev Returns the ERC-7201 storage pointer for ERC20 gateway state. */
    function _getERC20GatewayStorage() private pure returns (ERC20GatewayStorage storage $) {
        // Load the deterministic ERC-7201 storage slot via assembly — avoids linear slot allocation
        // that would be unsafe across proxy upgrades with changing inheritance chains
        assembly ("memory-safe") {
            $.slot := ERC20_GATEWAY_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Prevent the implementation contract from being initialized directly.
        // Only proxies pointing to this implementation should be initialized.
        _disableInitializers();
    }

    /** @notice Initializes the ERC20 gateway with base config, token factory, and remote chain parameters. */
    function initialize(address initialOwner, address bridgeContract, address tokenFactory) public initializer {
        // Initialize the base gateway: sets owner, bridge address, reentrancy guard, and UUPS support.
        // This must be called before any ERC20Gateway-specific storage writes.
        __GatewayBase_init(initialOwner, bridgeContract);

        // ============ Storage ============
        // Store the local token factory used to deploy pegged token representations on this chain
        _setTokenFactory(tokenFactory);
    }

    // ============ Send Tokens ============

    /// @inheritdoc IERC20Gateway
    /// @dev Callable by anyone. Nonreentrant guard prevents callbacks from token hooks re-entering.
    function sendTokens(address token, address to, uint256 amount) external payable nonReentrant {
        // Ensure the remote gateway has been configured — cannot route messages without a destination
        require(getOtherSideGateway() != address(0), ZeroAddressNotAllowed("getOtherSideGateway"));
        // Prevent accidental burns to the zero address on the destination chain
        require(to != address(0), InvalidRecipient());

        // Cache msg.sender to pass as both the protocol-level sender and the token source
        address sender = msg.sender;
        bytes memory message;

        // Determine token mode by checking whether a pegged-to-origin mapping exists.
        // No mapping means this is an origin token on the current chain (deposit path: escrow locally).
        // A mapping means this is a pegged token on the current chain (withdraw path: burn locally).
        if (getTokenMapping(token) == address(0)) {
            // Origin token path: lock tokens in this gateway and encode a receivePeggedTokens call
            message = _sendOriginTokens(token, sender, sender, to, amount);
        } else {
            // Pegged token path: burn the pegged representation and encode a receiveOriginTokens call
            message = _sendPeggedTokens(token, sender, sender, to, amount);
        }

        // Forward the encoded message to FluentBridge for cross-chain delivery.
        // msg.value is passed through as the bridge fee paid by the caller.
        FluentBridge(getBridgeContract()).sendMessage{value: msg.value}(getOtherSideGateway(), message);
    }

    /// @dev Used on L1 to send origin tokens to the other side.
    function _sendOriginTokens(address token, address sender, address from, address to, uint256 amount) internal returns (bytes memory) {
        // Verify remote routing is fully configured — both gateway and factory are needed to
        // deterministically compute the pegged token address on the destination chain
        require(
            getOtherSideGateway() != address(0) && getOtherSideFactory() != address(0),
            ZeroAddressNotAllowed("getOtherSideGateway or getOtherSideFactory")
        );
        // At least one of chainId (universal path) or beacon (beacon-proxy path) must be set
        // to allow pegged token address computation on the remote chain
        require(
            getOtherSideChainId() != 0 || getOtherSideBeacon() != address(0),
            ZeroAddressNotAllowed("getOtherSideChainId or getOtherSideBeacon")
        );

        // Lock origin tokens in this gateway — they remain escrowed until a future
        // receiveOriginTokens call releases them back to a withdrawer
        IERC20(token).safeTransferFrom(from, address(this), amount);

        // Read on-chain token metadata to forward to the destination chain.
        // The remote gateway needs this to deploy a matching pegged token if one doesn't exist yet.
        string memory symbol = ERC20(token).symbol();
        string memory name = ERC20(token).name();
        uint8 decimals = ERC20(token).decimals();
        // ABI-encode metadata into a single bytes blob for cross-chain transport.
        // The receiving gateway decodes this to deploy or verify the pegged token.
        bytes memory rawTokenMetadata = abi.encode(symbol, name, decimals);

        // Deterministically compute the expected pegged token address on the remote chain.
        // This lets the remote gateway verify that its locally deployed token matches.
        address peggedTokenOnOtherSide = _computeOtherSidePeggedTokenAddressWithGateway(getOtherSideGateway(), token, name, symbol, decimals);

        // Encode the cross-chain call: destination gateway will call receivePeggedTokens
        // to mint pegged tokens to the recipient
        return abi.encodeCall(IERC20Gateway.receivePeggedTokens, (token, peggedTokenOnOtherSide, sender, to, amount, rawTokenMetadata));
    }

    /// @dev Used on L2 to send pegged tokens to the other side.
    function _sendPeggedTokens(address token, address sender, address from, address to, uint256 amount) internal returns (bytes memory) {
        // Look up the origin token address that this pegged token represents on the remote chain
        address originAddress = getTokenMapping(token);
        // Safety check: a zero origin address would mean a broken mapping — should never happen
        // since sendTokens only calls this path when getTokenMapping(token) != address(0)
        require(originAddress != address(0), ZeroAddressNotAllowed("originAddress"));

        // Burn the pegged tokens from the sender — permanently destroys the local representation.
        // This gateway was set as minter/burner during pegged token deployment.
        ERC20PeggedToken(token).burn(from, amount);

        // Encode the cross-chain call: destination gateway will call receiveOriginTokens
        // to release the corresponding origin tokens from escrow to the recipient
        return abi.encodeCall(IERC20Gateway.receiveOriginTokens, (originAddress, sender, to, amount));
    }

    // ============ Receive Tokens ============

    /// @inheritdoc IERC20Gateway
    function receivePeggedTokens(
        address originToken,
        address peggedToken,
        address from,
        address to,
        uint256 amount,
        bytes calldata tokenMetadata
    ) external onlyFluentBridge nonReentrant {
        // Access control: onlyFluentBridge modifier restricts callers to the local bridge contract.
        // The bridge is trusted infrastructure — it decodes cross-chain messages and calls this function.

        // Trust check: verify the original cross-chain sender is the configured remote gateway.
        // getNativeSender() returns the address that called sendMessage on the remote bridge.
        // Without this check, any contract could send arbitrary messages through the bridge.
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        // Validate inputs to prevent minting against a zero origin or burning tokens to zero address
        require(originToken != address(0), ZeroAddressNotAllowed("originToken"));
        require(to != address(0), InvalidRecipient());

        // Check whether the pegged token contract already exists on this chain by inspecting
        // code size. length == 0 means no contract deployed at that address yet.
        if (peggedToken.code.length == 0) {
            // First time seeing this origin token — deploy a new pegged token via the factory.
            // The factory uses CREATE2 so the address is deterministic and matches what the sender computed.
            address newPeggedToken = _deployPeggedToken(tokenMetadata, originToken);
            // Verify the deployed address matches the sender's prediction — mismatch means
            // factory/config divergence between the two chains
            require(newPeggedToken == peggedToken, WrongPeggedToken());
            // Record the pegged-to-origin mapping so future sends from this chain
            // route through _sendPeggedTokens (burn path) instead of _sendOriginTokens
            _getERC20GatewayStorage()._tokenMapping[peggedToken] = originToken;
        } else {
            // Pegged token already deployed — verify the mapping is consistent.
            // Prevents a malicious message from associating a different origin with an existing pegged token.
            require(getTokenMapping(peggedToken) == originToken, TokenMappingCheckFailed());
        }

        // Mint the pegged token amount to the recipient — this gateway has minter authority
        // because it was set as the owner during _deployPeggedToken
        ERC20PeggedToken(peggedToken).mint(to, amount);

        // Emit for off-chain indexers tracking cross-chain token arrivals
        emit ReceivedTokens(from, to, amount);
    }

    /// @inheritdoc IERC20Gateway
    /// @dev Releases escrowed origin tokens on L1. Restricted to bridge via {onlyFluentBridge}.
    function receiveOriginTokens(address originToken, address from, address to, uint256 amount) external onlyFluentBridge nonReentrant {
        // Trust check: only the bridge can call this, and the original cross-chain sender
        // must be the configured remote gateway — prevents unauthorized token release
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        // Guard against releasing tokens for an invalid origin address
        require(originToken != address(0), OriginTokenZero());
        // Prevent releasing tokens to the zero address
        require(to != address(0), InvalidRecipient());

        // Release escrowed origin tokens to the recipient — these were locked during
        // _sendOriginTokens on this chain when the deposit was made.
        // SafeERC20 handles non-standard tokens that return false instead of reverting.
        IERC20(originToken).safeTransfer(to, amount);

        // Emit for off-chain indexers tracking cross-chain token arrivals
        emit ReceivedTokens(from, to, amount);
    }

    /**
     * @dev Deploys a new pegged token locally on this chain.
     *      If the Factory is a BeaconProxy, the pegged token is deployed as a BeaconProxy.
     *      If the Factory is a UniversalTokenFactory, the pegged token is deployed as precompiled UniversalToken.
     * @param tokenMetadata The metadata of the token (symbol, name, decimals)
     * @param originToken The origin token address.
     * @return The address of the pegged token.
     */
    function _deployPeggedToken(bytes memory tokenMetadata, address originToken) internal returns (address) {
        // Decode the token metadata forwarded from the origin chain
        (string memory symbol, string memory name, uint8 decimals) = abi.decode(tokenMetadata, (string, string, uint8));
        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();

        // Ask the factory for deployment arguments. Two factory types exist:
        //   - BeaconProxyFactory: returns empty bytes (beacon proxy is initialized separately)
        //   - UniversalTokenFactory: returns encoded init code with token parameters baked in
        bytes memory deployArgs = IGenericTokenFactory($._tokenFactory).getDeployArgs(name, symbol, decimals);

        // Deploy the pegged token via the factory using CREATE2.
        // The salt is derived from (gateway, originToken) ensuring deterministic addresses.
        address peggedToken = IGenericTokenFactory($._tokenFactory).deployToken(address(this), originToken, deployArgs);

        // Beacon proxy tokens need explicit initialization because their constructor is empty.
        // Universal tokens are self-initializing via their constructor arguments.
        // This gateway becomes the owner/minter of the pegged token, granting mint/burn authority.
        if (deployArgs.length == 0) ERC20PeggedToken(peggedToken).initialize(name, symbol, decimals, address(this), originToken);

        return peggedToken;
    }

    // ============ Public getters ============

    /// @inheritdoc IERC20Gateway
    function getTokenFactory() public view returns (address) {
        // Returns the local factory that deploys pegged tokens on this chain
        return _getERC20GatewayStorage()._tokenFactory;
    }

    /**
     * @notice Returns the token implementation address on the remote chain.
     */
    function getOtherSideTokenImplementation() public view returns (address) {
        // Used for off-chain queries; not consumed in on-chain address computation
        return _getERC20GatewayStorage()._otherSideTokenImplementation;
    }

    /**
     * @notice Returns the factory address on the remote chain.
     */
    function getOtherSideFactory() public view returns (address) {
        // Needed for deterministic CREATE2 address computation of remote pegged tokens
        return _getERC20GatewayStorage()._otherSideFactory;
    }

    /**
     * @notice Returns the beacon address on the remote chain.
     */
    function getOtherSideBeacon() public view returns (address) {
        // Used in the beacon-proxy CREATE2 address computation path
        return _getERC20GatewayStorage()._otherSideBeacon;
    }

    /// @inheritdoc IERC20Gateway
    function getTokenMapping(address key) public view returns (address) {
        // Maps a local pegged token to its origin token on the remote chain.
        // Returns address(0) if the token is not a pegged representation (i.e., it is an origin token).
        return _getERC20GatewayStorage()._tokenMapping[key];
    }

    /// @inheritdoc IERC20Gateway
    function computeOtherSidePeggedTokenAddress(address gateway, address originToken) external view returns (address) {
        // Convenience wrapper: reads metadata from the on-chain origin token and delegates
        // to the internal computation that predicts the pegged token address on the remote chain
        return
            _computeOtherSidePeggedTokenAddressWithGateway(
                gateway,
                originToken,
                ERC20(originToken).name(),
                ERC20(originToken).symbol(),
                ERC20(originToken).decimals()
            );
    }

    /// @inheritdoc IERC20Gateway
    function computeTokenAddress(address gateway, address originToken) external view returns (address) {
        // Convenience wrapper: reads metadata from the on-chain origin token and delegates
        // to the internal computation that predicts the local pegged token address
        return
            _computeTokenAddressWithGateway(
                gateway,
                originToken,
                ERC20(originToken).name(),
                ERC20(originToken).symbol(),
                ERC20(originToken).decimals()
            );
    }

    // ============ Universal Token Factory ============

    /// @dev CREATE2 address math for UniversalTokenFactory without external calls (salt matches {ERC20TokenFactory}).
    function _computeUniversalTokenAddress(
        address factory,
        address gateway,
        address originToken,
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) internal pure returns (address) {
        // Build the full init code that would be used by the UniversalTokenFactory precompile.
        // This includes the magic prefix and ABI-encoded token constructor params.
        bytes memory deploymentData = _universalTokenDeploymentData(name, symbol, decimals, initialSupply, minter, pauser);

        // The CREATE2 salt binds the token to a specific gateway and origin token pair,
        // ensuring each origin token gets exactly one pegged representation per gateway
        bytes32 salt = keccak256(abi.encodePacked(gateway, originToken));

        // Hash the full init code — CREATE2 uses this to derive the deployed address
        bytes32 initCodeHash = keccak256(deploymentData);

        // Standard CREATE2 address formula: keccak256(0xff ++ deployer ++ salt ++ initCodeHash)
        // Truncated to 160 bits (20 bytes) for the Ethereum address
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash));
        return address(uint160(uint256(hash)));
    }

    /** @dev Constructs the UniversalToken init code with magic prefix for the L2 precompile. */
    function _universalTokenDeploymentData(
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) internal pure returns (bytes memory) {
        // The L2 UniversalTokenFactory precompile expects init code prefixed with "ERC " (0x45524320).
        // This magic prefix distinguishes universal token deployments from regular CREATE2 calls.
        // The remaining payload is the standard ABI-encoded constructor arguments.
        return abi.encodePacked(UNIVERSAL_TOKEN_MAGIC_BYTES, abi.encode(name, symbol, decimals, initialSupply, minter, pauser));
    }

    /** @dev Computes the local token address for a given origin token using this gateway. */
    function _computeTokenAddress(address token, string memory name, string memory symbol, uint8 decimals) internal view returns (address) {
        // Shorthand that uses this gateway's own address as the deployer in the CREATE2 salt
        return _computeTokenAddressWithGateway(address(this), token, name, symbol, decimals);
    }

    /** @dev Computes the token address for a given origin token and explicit gateway address. */
    function _computeTokenAddressWithGateway(
        address gateway,
        address token,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal view returns (address) {
        bytes memory deployArgs;
        // Detect which factory type is in use by checking if a beacon is configured.
        // Beacon-proxy factories use empty deploy args (init happens post-deployment).
        // Universal token factories include full constructor params in deploy args.
        if (IGenericTokenFactory(getTokenFactory()).beacon() != address(0)) {
            deployArgs = "";
        } else {
            deployArgs = IGenericTokenFactory(getTokenFactory()).getDeployArgs(name, symbol, decimals);
        }
        // Delegate the actual CREATE2 address derivation to the factory contract,
        // which knows its own deployer address and bytecode hashing logic
        return IGenericTokenFactory(getTokenFactory()).computeTokenAddress(gateway, token, deployArgs);
    }

    /// @dev Computes the remote (other-chain) pegged token address; uses `otherSideGateway` in CREATE2 salt.
    function _computeOtherSidePeggedTokenAddress(
        address originToken,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal view returns (address) {
        // Shorthand that uses the stored remote gateway address as the deployer identity
        return _computeOtherSidePeggedTokenAddressWithGateway(getOtherSideGateway(), originToken, name, symbol, decimals);
    }

    /** @dev Computes the remote pegged token address for a given gateway and origin token. */
    function _computeOtherSidePeggedTokenAddressWithGateway(
        address otherSideGateway,
        address originToken,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal view returns (address) {
        // Branch based on the remote chain's factory type.
        // Universal path: the L2 precompile uses magic-prefixed init code in CREATE2.
        // Beacon path: standard OZ BeaconProxy creation code in CREATE2.
        if (_getERC20GatewayStorage()._isOtherSideUniversal) {
            // Universal tokens: initialSupply=0 (gateway mints on demand),
            // minter=gateway, pauser=gateway — both roles go to the remote gateway
            return
                _computeUniversalTokenAddress(
                    getOtherSideFactory(),
                    otherSideGateway,
                    originToken,
                    name,
                    symbol,
                    decimals,
                    0,
                    otherSideGateway,
                    otherSideGateway
                );
        }
        // Beacon-proxy path: address depends only on factory, beacon, gateway, and origin token.
        // Token metadata does not affect the address because the proxy is metadata-agnostic at deploy time.
        return _computeBeaconProxyAddress(getOtherSideFactory(), getOtherSideBeacon(), otherSideGateway, originToken);
    }

    /**
     * @dev Computes the remote (other-chain) pegged token address from stored config only.
     * @param factory The address of the factory: L1 or L2 factory address
     * @param beacon The address of the beacon: L1 or L2 BeaconProxy address
     * @param gateway The address of the gateway: L1 or L2 gateway address
     * @param originToken The address of the origin token: L1 or L2 origin token address
     * @return The address of the pegged token: L1 or L2 PeggedToken address
     */
    function _computeBeaconProxyAddress(address factory, address beacon, address gateway, address originToken) internal pure returns (address) {
        // Reconstruct the exact creation bytecode that the factory would use:
        // BeaconProxy constructor takes (beacon, "") — empty data because initialization is separate
        bytes memory bytecode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, ""));
        // Salt ties the proxy to a unique (gateway, originToken) pair
        bytes32 salt = keccak256(abi.encodePacked(gateway, originToken));
        // Hash the full creation code — must exactly match what the factory uses at deploy time
        bytes32 bytecodeHash = keccak256(bytecode);
        // Standard CREATE2 formula: address = keccak256(0xff ++ factory ++ salt ++ bytecodeHash)[12:]
        // The 0xff prefix prevents collisions with regular CREATE-deployed contracts
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, bytecodeHash)))));
    }

    // ============ Admin functions ============

    /**
     * @notice Updates the local token factory used for pegged token deployment and address computation.
     * @param tokenFactory The address of the token factory.
     */
    function setTokenFactory(address tokenFactory) external onlyOwner {
        // Owner-only: delegates to internal setter with zero-address validation
        _setTokenFactory(tokenFactory);
    }

    /** @dev Validates and stores the token factory address. Reverts on zero address. */
    function _setTokenFactory(address tokenFactory) internal {
        // A zero factory would break all pegged token deployments and address computations
        require(tokenFactory != address(0), ZeroAddressNotAllowed("tokenFactory"));
        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        // Emit before writing so the event carries both old and new values for off-chain tracking
        emit TokenFactoryUpdated($._tokenFactory, tokenFactory);
        $._tokenFactory = tokenFactory;
    }

    /**
     * @notice Updates remote token implementation used in deterministic pegged token address computation.
     * @param otherSideTokenImplementation The address of the other side token implementation.
     */
    function setOtherSideTokenImplementation(address otherSideTokenImplementation) external onlyOwner {
        // Owner-only: delegates to internal setter with zero-address validation
        _setOtherSideTokenImplementation(otherSideTokenImplementation);
    }

    /** @dev Stores the remote token implementation address. */
    function _setOtherSideTokenImplementation(address otherSideTokenImplementation) internal {
        // Zero address would break remote token address prediction
        require(otherSideTokenImplementation != address(0), ZeroAddressNotAllowed("otherSideTokenImplementation"));
        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        // Emit before writing so the event carries both old and new values for off-chain tracking
        emit OtherSideTokenImplementationUpdated($._otherSideTokenImplementation, otherSideTokenImplementation);
        $._otherSideTokenImplementation = otherSideTokenImplementation;
    }

    /**
     * @notice Sets remote gateway/factory configuration used for cross-chain token routing.
     * @param isOtherSideUniversal Whether the other side is a Universal-token destination chain.
     * @param otherSideGateway The address of the other side gateway.
     * @param otherSideChainId The chain id of the other side.
     * @dev High-trust admin action; should be controlled by multisig governance.
     * @param otherSideTokenImplementation The address of the other side token implementation.
     * @param otherSideFactory The address of the other side factory.
     * @param otherSideBeacon The address of the other side beacon.
     */
    function setOtherSide(
        bool isOtherSideUniversal,
        address otherSideGateway,
        uint256 otherSideChainId,
        address otherSideTokenImplementation,
        address otherSideFactory,
        address otherSideBeacon
    ) external onlyOwner {
        // Owner-only bulk setter: configures all remote-chain routing parameters atomically.
        // Prefer this over individual setters to avoid partial-config states where some fields
        // are updated but others still point to the old chain.
        _setOtherSide(isOtherSideUniversal, otherSideGateway, otherSideChainId, otherSideTokenImplementation, otherSideFactory, otherSideBeacon);
    }

    /** @dev Stores all remote-chain addressing parameters at once. */
    function _setOtherSide(
        bool isOtherSideUniversal,
        address otherSideGateway,
        uint256 otherSideChainId,
        address otherSideTokenImplementation,
        address otherSideFactory,
        address otherSideBeacon
    ) internal {
        // Core routing addresses must be non-zero — without these, cross-chain messages
        // cannot be sent or pegged token addresses cannot be computed.
        // Note: otherSideBeacon is allowed to be zero for the universal-token path.
        require(
            otherSideGateway != address(0) && otherSideTokenImplementation != address(0) && otherSideFactory != address(0),
            ZeroAddressNotAllowed("otherSideGateway or otherSideTokenImplementation or otherSideFactory")
        );

        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        // Emit a comprehensive event with both old and new values for every field,
        // allowing off-chain systems to track configuration changes
        emit OtherSideUpdated(
            getOtherSideGateway(),
            otherSideGateway,
            getOtherSideTokenImplementation(),
            otherSideTokenImplementation,
            getOtherSideFactory(),
            otherSideFactory,
            getOtherSideBeacon(),
            otherSideBeacon
        );
        // Determines which CREATE2 address computation path to use (universal vs beacon)
        $._isOtherSideUniversal = isOtherSideUniversal;
        // Delegate to GatewayBase setter which also emits its own event and validates non-zero
        _setOtherSideGateway(otherSideGateway);
        // Store remote token implementation, factory, and beacon for deterministic address computation.
        // These values must match the actual deployment on the remote chain for CREATE2 to produce
        // matching addresses — misconfiguration would cause receivePeggedTokens to fail with WrongPeggedToken.
        $._otherSideTokenImplementation = otherSideTokenImplementation;
        $._otherSideFactory = otherSideFactory;
        // Beacon can be zero when using the universal-token path (precompile-based L2)
        $._otherSideBeacon = otherSideBeacon;
        // Delegate to GatewayBase setter; allows zero for beacon-based routing
        _setOtherSideChainId(otherSideChainId);
    }
}
