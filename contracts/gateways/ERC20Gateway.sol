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
 */
contract ERC20Gateway is GatewayBase, IERC20Gateway {
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public constant DEFAULT_GAS_LIMIT = 50_000;

    /// @dev Magic prefix used in Universal token CREATE2 init-code encoding.
    bytes4 private constant UNIVERSAL_TOKEN_MAGIC_BYTES = bytes4(0x45524320); // "ERC "

    /// @dev CREATE2 salt prefix used by Universal token deployments.
    string private constant BRIDGE_TOKEN_PREFIX = "BRIDGE_TOKEN";

    /// @custom:storage-location erc7201:fluent.storage.ERC20Gateway
    struct ERC20GatewayStorage {
        address tokenFactory;
        address otherSideTokenImplementation;
        address otherSideFactory;
        address otherSideBeacon;
        mapping(address => address) tokenMapping;
        uint256[50] __gap;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.ERC20Gateway")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC20_GATEWAY_STORAGE_LOCATION = 0x49a4a8f6a0eb57ce4c9f79395833ca638fce1115fd2104cef2fba8f2bc71f700;

    error InvalidRecipient();

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

    /// @inheritdoc IERC20Gateway
    function sendTokens(address token, address to, uint256 amount) external nonReentrant {
        require(getOtherSide() != address(0), ZeroAddress());
        // require(to != address(0), InvalidRecipient());
        _sendTokensFrom(token, msg.sender, msg.sender, to, amount);
    }

    function _sendTokensFrom(address token, address sender, address from, address to, uint256 amount) internal {
        bytes memory _message;

        if (getTokenMapping(token) == address(0)) {
            require(getOtherSide() != address(0) && getOtherSideFactory() != address(0), ZeroAddress());
            require(getOtherSideChainId() != 0 || getOtherSideBeacon() != address(0), ZeroAddress());
            if (from != address(this)) {
                IERC20(token).safeTransferFrom(from, address(this), amount);
            }

            string memory symbol = ERC20(token).symbol();
            string memory name = ERC20(token).name();
            uint8 decimals = ERC20(token).decimals();
            bytes memory rawTokenMetadata = abi.encode(symbol, name, decimals);

            address peggedToken = _computeOtherSidePeggedTokenAddress(token, name, symbol, decimals);
            _message = abi.encodeCall(IERC20Gateway.receivePeggedTokens, (token, peggedToken, sender, to, amount, rawTokenMetadata));
        } else {
            address originAddress = getTokenMapping(token);
            require(originAddress != address(0), TokenMappingCheckFailed());
            // tokenMapping is the single source of truth (set on receive); no getOrigin() call so Universal tokens need not implement it
            ERC20PeggedToken(token).burn(from, amount);

            _message = abi.encodeCall(IERC20Gateway.receiveOriginTokens, (originAddress, sender, to, amount));
        }

        FluentBridge(getBridgeContract()).sendMessage(getOtherSide(), _message);
    }

    /// @inheritdoc IERC20Gateway
    function receivePeggedTokens(
        address originToken,
        address peggedToken,
        address from,
        address to,
        uint256 amount,
        bytes calldata tokenMetadata
    ) public payable onlyBridgeSender nonReentrant {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSide(), MessageFromWrongGateway());
        require(msg.value == 0, MessageValueMustBeZero());
        require(originToken != address(0), OriginTokenZero());
        require(to != address(0), InvalidRecipient());

        if (peggedToken.code.length == 0) {
            address new_pegged_token = _deployL2Token(tokenMetadata, originToken);
            require(new_pegged_token == peggedToken, WrongPeggedToken());
            _getERC20GatewayStorage().tokenMapping[peggedToken] = originToken;
        } else {
            require(getTokenMapping(peggedToken) == originToken, TokenMappingCheckFailed());
        }

        ERC20PeggedToken(peggedToken).mint(to, amount);

        emit ReceivedTokens(from, to, amount);
    }

    /// @inheritdoc IERC20Gateway
    function receiveOriginTokens(
        address _originToken,
        address _from,
        address _to,
        uint256 _amount
    ) public payable onlyBridgeSender nonReentrant {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSide(), MessageFromWrongGateway());
        require(msg.value == 0, MessageValueMustBeZero());
        require(_to != address(0), InvalidRecipient());

        IERC20(_originToken).safeTransfer(_to, _amount);

        emit ReceivedTokens(_from, _to, _amount);
    }

    /**
     * @notice Deploys a new pegged token.
     * @param tokenMetadata The metadata of the token (symbol, name, decimals)
     * @param originToken The origin token address.
     * @return The address of the pegged token.
     */
    function _deployL2Token(bytes memory tokenMetadata, address originToken) internal returns (address) {
        (string memory symbol, string memory name, uint8 decimals) = abi.decode(tokenMetadata, (string, string, uint8));
        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        bytes memory deployArgs = IGenericTokenFactory($.tokenFactory).getDeployArgs(name, symbol, decimals);

        bytes memory keyData;
        if (IGenericTokenFactory($.tokenFactory).beacon() != address(0)) {
            keyData = abi.encode(address(this), originToken);
        } else {
            keyData = abi.encode(originToken);
        }

        address peggedToken = IGenericTokenFactory($.tokenFactory).deployToken(keyData, deployArgs);

        try ERC20PeggedToken(peggedToken).initialize(name, symbol, decimals, address(this), originToken) {
            // ERC20PeggedToken (beacon proxy) needs one-time initialize; success path.
        } catch {
            // Token already initialized (e.g. Universal token from UniversalTokenFactory); skip.
        }
        return peggedToken;
    }

    // ============ Public getters ============

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
            return _computeBeaconProxyAddress($.otherSideFactory, $.otherSideBeacon, getOtherSide(), originToken);
        }
        // Universal (otherSideChainId != 0): minter/pauser must be the remote gateway so L2 deployment matches.
        return _computeUniversalTokenAddress($.otherSideFactory, originToken, name, symbol, decimals, 0, getOtherSide(), getOtherSide());
    }

    /// @dev CREATE2 address for a BeaconProxy deployed by the remote factory (same formula as ERC20TokenFactory).
    function _computeBeaconProxyAddress(
        address factory,
        address beacon,
        address gateway,
        address originToken
    ) internal pure returns (address) {
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
        bytes memory deploymentData = _universalDeploymentData(name, symbol, decimals, initialSupply, minter, pauser);
        bytes32 salt = keccak256(abi.encodePacked(BRIDGE_TOKEN_PREFIX, originToken));
        bytes32 initCodeHash = keccak256(deploymentData);
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash));
        return address(uint160(uint256(hash)));
    }

    function _universalDeploymentData(
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
        require(tokenFactory != address(0), ZeroAddress());
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
        require(otherSideTokenImplementation != address(0), ZeroAddress());
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
            ZeroAddress()
        );

        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        emit OtherSideUpdated(
            getOtherSide(),
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
    function setOtherSideUniversal(
        address otherSide,
        address otherSideTokenImplementation,
        address otherSideFactory,
        uint256 otherSideChainId
    ) external onlyOwner {
        require(
            otherSide != address(0) && otherSideTokenImplementation != address(0) && otherSideFactory != address(0) && otherSideChainId != 0,
            ZeroAddress()
        );

        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        emit OtherSideUpdated(
            getOtherSide(),
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

    /**
     * @notice Updates local peggedToken => originToken mapping used for burn/unlock flows.
     * @dev High-trust admin action; incorrect mapping can misroute user withdrawals.
     * @param originToken The address of the origin token.
     * @param peggedToken The address of the pegged token.
     */
    function updateTokenMapping(address originToken, address peggedToken) external onlyOwner {
        _updateTokenMapping(originToken, peggedToken);
    }

    function _updateTokenMapping(address originToken, address peggedToken) internal {
        require(originToken != address(0), TokenAddressZero());
        require(peggedToken != address(0), TokenAddressZero());
        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        address oldOriginToken = $.tokenMapping[peggedToken];
        require(oldOriginToken != address(0), UnknownPeggedToken());
        $.tokenMapping[peggedToken] = originToken;
        emit UpdateTokenMapping(peggedToken, oldOriginToken, originToken);
    }
}
