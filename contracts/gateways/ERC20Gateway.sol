// SPDX-License-Identifier: MIT
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
    using SafeERC20 for IERC20;

    /**
     * @dev Magic prefix used in Universal token CREATE2 init-code encoding.
     * @dev "ERC "
     */
    bytes4 private constant UNIVERSAL_TOKEN_MAGIC_BYTES = bytes4(0x45524320);

    /**
     * @dev CREATE2 salt prefix used by Universal token deployments.
     */
    string private constant BRIDGE_TOKEN_PREFIX = "BRIDGE_TOKEN";

    /// @custom:storage-location erc7201:fluent.storage.ERC20GatewayStorage
    struct ERC20GatewayStorage {
        address tokenFactory;
        address otherSideTokenImplementation;
        address otherSideFactory;
        address otherSideBeacon;
        mapping(address => address) tokenMapping;
        uint256[50] __gap;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.ERC20GatewayStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC20_GATEWAY_STORAGE_LOCATION = 0xe252cab26214ab2f0e4d4e6f063d78ba24b618cf5f8fd25d1b9aef671b7f9100;

    function _getERC20GatewayStorage() private pure returns (ERC20GatewayStorage storage $) {
        assembly {
            $.slot := ERC20_GATEWAY_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address bridgeContract, address tokenFactory) public initializer {
        __GatewayBase_init(initialOwner, bridgeContract);

        // ============ Storage ============
        _setTokenFactory(tokenFactory);
    }

    // ============ Send Tokens ============

    /// @inheritdoc IERC20Gateway
    function sendTokens(address token, address to, uint256 amount) external nonReentrant {
        require(getOtherSideGateway() != address(0), ZeroAddressNotAllowed("getOtherSideGateway"));
        require(to != address(0), InvalidRecipient());

        address sender = msg.sender;
        bytes memory message;

        // If the token is not mapped, it means it is an origin token.
        if (getTokenMapping(token) == address(0)) {
            message = _sendOriginTokens(token, sender, sender, to, amount);
        } else {
            message = _sendPeggedTokens(token, sender, sender, to, amount);
        }

        FluentBridge(getBridgeContract()).sendMessage(getOtherSideGateway(), message);
    }

    /// @notice Used on L1 to send origin tokens to the other side.
    function _sendOriginTokens(address token, address sender, address from, address to, uint256 amount) internal returns (bytes memory) {
        require(
            getOtherSideGateway() != address(0) && getOtherSideFactory() != address(0),
            ZeroAddressNotAllowed("getOtherSideGateway or getOtherSideFactory")
        );
        require(
            getOtherSideChainId() != 0 || getOtherSideBeacon() != address(0),
            ZeroAddressNotAllowed("getOtherSideChainId or getOtherSideBeacon")
        );

        if (from != address(this)) IERC20(token).safeTransferFrom(from, address(this), amount);

        string memory symbol = ERC20(token).symbol();
        string memory name = ERC20(token).name();
        uint8 decimals = ERC20(token).decimals();
        bytes memory rawTokenMetadata = abi.encode(symbol, name, decimals);

        address peggedTokenOnOtherSide = _computeOtherSidePeggedTokenAddress(token, name, symbol, decimals);

        return abi.encodeCall(IERC20Gateway.receivePeggedTokens, (token, peggedTokenOnOtherSide, sender, to, amount, rawTokenMetadata));
    }

    /// @notice Used on L2 to send pegged tokens to the other side.
    function _sendPeggedTokens(address token, address sender, address from, address to, uint256 amount) internal returns (bytes memory) {
        address originAddress = getTokenMapping(token);
        require(originAddress != address(0), ZeroAddressNotAllowed("originAddress"));

        ERC20PeggedToken(token).burn(from, amount);

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
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(originToken != address(0), ZeroAddressNotAllowed("originToken"));
        require(to != address(0), InvalidRecipient());

        // If the pegged token is not deployed, deploy it.
        // Else if the pegged token is deployed, check if the token mapping is correct.
        if (peggedToken.code.length == 0) {
            address newPeggedToken = _deployPeggedToken(tokenMetadata, originToken);
            require(newPeggedToken == peggedToken, WrongPeggedToken());
            _getERC20GatewayStorage().tokenMapping[peggedToken] = originToken;
        } else {
            require(getTokenMapping(peggedToken) == originToken, TokenMappingCheckFailed());
        }

        ERC20PeggedToken(peggedToken).mint(to, amount);

        emit ReceivedTokens(from, to, amount);
    }

    /// @inheritdoc IERC20Gateway
    function receiveOriginTokens(address originToken, address from, address to, uint256 amount) external onlyFluentBridge nonReentrant {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(originToken != address(0), OriginTokenZero());
        require(to != address(0), InvalidRecipient());

        IERC20(originToken).safeTransfer(to, amount);

        emit ReceivedTokens(from, to, amount);
    }

    /**
     * @notice Deploys a new pegged token on the other side.
     *         If the Factory is a BeaconProxy, the pegged token is deployed as a BeaconProxy.
     *         If the Factory is a UniversalTokenFactory, the pegged token is deployed as precompiled UniversalToken
     * @param tokenMetadata The metadata of the token (symbol, name, decimals)
     * @param originToken The origin token address.
     * @return The address of the pegged token.
     */
    function _deployPeggedToken(bytes memory tokenMetadata, address originToken) internal returns (address) {
        (string memory symbol, string memory name, uint8 decimals) = abi.decode(tokenMetadata, (string, string, uint8));
        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        bytes memory deployArgs = IGenericTokenFactory($.tokenFactory).getDeployArgs(name, symbol, decimals);

        bytes memory keyData;
        if (IGenericTokenFactory($.tokenFactory).beacon() != address(0)) {
            keyData = abi.encode(address(this), originToken);
        } else {
            keyData = abi.encode(originToken);
        }

        // If it's a beacon proxy -> the deployArgs is empty
        address peggedToken = IGenericTokenFactory($.tokenFactory).deployToken(keyData, deployArgs);
        if (deployArgs.length == 0) ERC20PeggedToken(peggedToken).initialize(name, symbol, decimals, address(this), originToken);

        return peggedToken;
    }

    // ============ Public getters ============

    /// @inheritdoc IERC20Gateway
    function getTokenFactory() public view returns (address) {
        return _getERC20GatewayStorage().tokenFactory;
    }

    function getOtherSideTokenImplementation() public view returns (address) {
        return _getERC20GatewayStorage().otherSideTokenImplementation;
    }

    function getOtherSideFactory() public view returns (address) {
        return _getERC20GatewayStorage().otherSideFactory;
    }

    function getOtherSideBeacon() public view returns (address) {
        return _getERC20GatewayStorage().otherSideBeacon;
    }

    /// @inheritdoc IERC20Gateway
    function getTokenMapping(address key) public view returns (address) {
        return _getERC20GatewayStorage().tokenMapping[key];
    }

    /// @inheritdoc IERC20Gateway
    function computePeggedTokenAddress(address token) external view returns (address) {
        return _computePeggedTokenAddress(token, ERC20(token).name(), ERC20(token).symbol(), ERC20(token).decimals());
    }

    function _computePeggedTokenAddress(
        address token,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal view returns (address) {
        bytes memory deployArgs;
        bytes memory keyData;
        if (IGenericTokenFactory(getTokenFactory()).beacon() != address(0)) {
            keyData = abi.encode(address(this), token);
            deployArgs = "";
        } else {
            deployArgs = IGenericTokenFactory(getTokenFactory()).getDeployArgs(name, symbol, decimals);
            keyData = abi.encode(token);
        }
        return IGenericTokenFactory(getTokenFactory()).computePeggedTokenAddress(keyData, deployArgs);
    }

    /// @inheritdoc IERC20Gateway
    function computeOtherSidePeggedTokenAddress(address originToken) external view returns (address) {
        return
            _computeOtherSidePeggedTokenAddress(
                originToken,
                ERC20(originToken).name(),
                ERC20(originToken).symbol(),
                ERC20(originToken).decimals()
            );
    }

    /// @dev Computes the remote (other-chain) pegged token address from stored config only.
    ///      CRITICAL: Do not call the destination factory (otherSideFactory) from send paths. It is a
    ///      destination-chain address; a local call would hit the same address on this chain (wrong or no code).
    ///      For Universal flows, getDeployArgs() on the remote would also derive minter/pauser from the
    ///      source gateway. We use only local CREATE2 math: Beacon path = _computeBeaconProxyAddress (pure);
    ///      Universal path = _computeUniversalTokenAddress (pure) with remote gateway as minter/pauser.
    function _computeOtherSidePeggedTokenAddress(
        address originToken,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal view returns (address) {
        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        if (getOtherSideBeacon() != address(0)) {
            return _computeBeaconProxyAddress($.otherSideFactory, $.otherSideBeacon, getOtherSideGateway(), originToken);
        }
        // Universal (otherSideChainId != 0): minter/pauser must be the remote gateway so L2 deployment matches.
        return
            _computeUniversalTokenAddress(
                $.otherSideFactory,
                originToken,
                name,
                symbol,
                decimals,
                0,
                getOtherSideGateway(),
                getOtherSideGateway()
            );
    }

    /// @dev CREATE2 address for a BeaconProxy deployed by the remote factory (same formula as ERC20TokenFactory).
    function _computeBeaconProxyAddress(address factory, address beacon, address gateway, address originToken) internal pure returns (address) {
        bytes memory bytecode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, ""));
        bytes32 salt = keccak256(abi.encodePacked(gateway, originToken));
        bytes32 bytecodeHash = keccak256(bytecode);
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, bytecodeHash)))));
    }

    /// @dev CREATE2 address math for UniversalTokenFactory without external calls.
    function _computeUniversalTokenAddress(
        address factory,
        address originToken,
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) internal pure returns (address) {
        bytes memory deploymentData = _universalTokenDeploymentData(name, symbol, decimals, initialSupply, minter, pauser);
        bytes32 salt = keccak256(abi.encodePacked(BRIDGE_TOKEN_PREFIX, originToken));
        bytes32 initCodeHash = keccak256(deploymentData);
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash));
        return address(uint160(uint256(hash)));
    }

    function _universalTokenDeploymentData(
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(UNIVERSAL_TOKEN_MAGIC_BYTES, abi.encode(name, symbol, decimals, initialSupply, minter, pauser));
    }

    // ============ Admin functions ============

    /**
     * @notice Updates the local token factory used for pegged token deployment and address computation.
     * @param tokenFactory The address of the token factory.
     */
    function setTokenFactory(address tokenFactory) external onlyOwner {
        _setTokenFactory(tokenFactory);
    }

    function _setTokenFactory(address tokenFactory) internal {
        require(tokenFactory != address(0), ZeroAddressNotAllowed("tokenFactory"));
        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        emit TokenFactoryUpdated($.tokenFactory, tokenFactory);
        $.tokenFactory = tokenFactory;
    }

    /**
     * @notice Updates remote token implementation used in deterministic pegged token address computation.
     * @param otherSideTokenImplementation The address of the other side token implementation.
     */
    function setOtherSideTokenImplementation(address otherSideTokenImplementation) external onlyOwner {
        _setOtherSideTokenImplementation(otherSideTokenImplementation);
    }

    function _setOtherSideTokenImplementation(address otherSideTokenImplementation) internal {
        require(otherSideTokenImplementation != address(0), ZeroAddressNotAllowed("otherSideTokenImplementation"));
        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        emit OtherSideTokenImplementationUpdated($.otherSideTokenImplementation, otherSideTokenImplementation);
        $.otherSideTokenImplementation = otherSideTokenImplementation;
    }

    /**
     * @notice Sets remote gateway/factory configuration used for cross-chain token routing.
     * @param otherSide The address of the other side gateway.
     * @dev High-trust admin action; should be controlled by multisig governance.
     * @param otherSideTokenImplementation The address of the other side token implementation.
     * @param otherSideFactory The address of the other side factory.
     * @param otherSideBeacon The address of the other side beacon.
     */
    function setOtherSide(
        address otherSide,
        address otherSideTokenImplementation,
        address otherSideFactory,
        address otherSideBeacon
    ) external onlyOwner {
        _setOtherSide(otherSide, otherSideTokenImplementation, otherSideFactory, otherSideBeacon);
    }

    function _setOtherSide(address otherSide, address otherSideTokenImplementation, address otherSideFactory, address otherSideBeacon) internal {
        require(
            otherSide != address(0) &&
                otherSideTokenImplementation != address(0) &&
                otherSideFactory != address(0) &&
                otherSideBeacon != address(0),
            ZeroAddressNotAllowed("otherSide or otherSideTokenImplementation or otherSideFactory or otherSideBeacon")
        );

        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        emit OtherSideUpdated(
            getOtherSideGateway(),
            otherSide,
            getOtherSideTokenImplementation(),
            otherSideTokenImplementation,
            getOtherSideFactory(),
            otherSideFactory,
            getOtherSideBeacon(),
            otherSideBeacon
        );
        _setOtherSideGateway(otherSide);
        $.otherSideTokenImplementation = otherSideTokenImplementation;
        $.otherSideFactory = otherSideFactory;
        $.otherSideBeacon = otherSideBeacon;
        _setOtherSideChainId(0);
    }

    /**
     * @notice Sets remote gateway/factory configuration for a Universal-token destination chain.
     * @param otherSide The remote gateway address.
     * @param otherSideTokenImplementation The remote token implementation/runtime identifier.
     * @param otherSideFactory The remote UniversalTokenFactory proxy address.
     * @param otherSideChainId The remote chain id used for Universal CREATE2 salt derivation.
     */
    function setOtherSideL2(
        address otherSide,
        address otherSideTokenImplementation,
        address otherSideFactory,
        uint256 otherSideChainId
    ) external onlyOwner {
        require(
            otherSide != address(0) && otherSideTokenImplementation != address(0) && otherSideFactory != address(0) && otherSideChainId != 0,
            ZeroAddressNotAllowed("setOtherSideL2 parameters")
        );

        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        emit OtherSideUpdated(
            getOtherSideGateway(),
            otherSide,
            $.otherSideTokenImplementation,
            otherSideTokenImplementation,
            $.otherSideFactory,
            otherSideFactory,
            $.otherSideBeacon,
            address(0)
        );

        _setOtherSideGateway(otherSide);
        $.otherSideTokenImplementation = otherSideTokenImplementation;
        $.otherSideFactory = otherSideFactory;
        $.otherSideBeacon = address(0);
        _setOtherSideChainId(otherSideChainId);
    }
}
