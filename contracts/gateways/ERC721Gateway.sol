// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {FluentBridge} from "../bridge/FluentBridge.sol";
import {IGenericTokenFactory} from "../interfaces/IGenericTokenFactory.sol";

import {GatewayBase} from "./GatewayBase.sol";
import {IERC721Gateway} from "./IERC721Gateway.sol";
import {ERC721PeggedToken} from "./ERC721PeggedToken.sol";

/**
 * @title ERC721Gateway
 * @author Fluent Labs
 * @notice Bridges ERC721 collections via `FluentBridge`: escrow origin NFTs, mint/burn pegged beacon proxies.
 * @dev Beacon-based CREATE2 addressing only (mirrors non-universal {ERC20Gateway} path). Implements {IERC721Receiver} for escrow.
 */
contract ERC721Gateway is GatewayBase, IERC721Gateway, IERC721Receiver {
    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.ERC721GatewayStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC721_GATEWAY_STORAGE_LOCATION =
        0xebf93b871411fa1e6a1daa8732a6452ccbe9c22588fbc0a5b37b9045e8baaa00;

    /// @custom:storage-location erc7201:Fluent.storage.ERC721GatewayStorage
    struct ERC721GatewayStorage {
        address _tokenFactory;
        address _otherSideTokenImplementation;
        address _otherSideFactory;
        address _otherSideBeacon;
        mapping(address => address) _tokenMapping;
        mapping(address => address) _otherSidePeggedForOrigin;
        mapping(address => bool) _bridgingExcludedOrigins;
        uint256[48] __gap;
    }

    function _getERC721GatewayStorage() private pure returns (ERC721GatewayStorage storage $) {
        assembly ("memory-safe") {
            $.slot := ERC721_GATEWAY_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address bridgeContract, address tokenFactory) public initializer {
        __GatewayBase_init(initialOwner, bridgeContract);
        _setTokenFactory(tokenFactory);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function _requireBridgingAllowedForOrigin(address originToken) internal view {
        require(!_getERC721GatewayStorage()._bridgingExcludedOrigins[originToken], BridgingExcludedOriginToken(originToken));
    }

    /// @inheritdoc IERC721Gateway
    function sendToken(address token, address to, uint256 tokenId) external payable nonReentrant {
        address sender = msg.sender;
        address otherSideGateway = getOtherSideGateway();
        address bridgeContract = getBridgeContract();
        require(otherSideGateway != address(0), ZeroAddressNotAllowed("getOtherSideGateway"));
        require(to != address(0), InvalidRecipient());
        require(msg.value == FluentBridge(bridgeContract).getSentMessageFee(), ExactFeeRequired());
        _requireAccountNotBlacklisted(sender);
        _requireAccountNotBlacklisted(to);

        bytes memory message;
        if (getTokenMapping(token) == address(0)) {
            message = _sendOriginToken(token, sender, sender, to, tokenId, otherSideGateway);
        } else {
            message = _sendPeggedToken(token, sender, sender, to, tokenId);
        }
        FluentBridge(bridgeContract).sendMessage{value: msg.value}(otherSideGateway, message);
    }

    function _sendOriginToken(
        address token,
        address sender,
        address from,
        address to,
        uint256 tokenId,
        address otherSideGateway
    ) internal returns (bytes memory) {
        require(getOtherSideFactory() != address(0), ZeroAddressNotAllowed("getOtherSideFactory"));
        require(getOtherSideChainId() != 0 || getOtherSideBeacon() != address(0), ZeroAddressNotAllowed("getOtherSideChainId or getOtherSideBeacon"));
        _requireBridgingAllowedForOrigin(token);

        IERC721(token).safeTransferFrom(from, address(this), tokenId);

        (string memory name, string memory symbol, string memory uri) = _readCollectionAndUri(token, tokenId);
        bytes memory tokenMetadata = abi.encode(name, symbol, uri);
        ERC721GatewayStorage storage $ = _getERC721GatewayStorage();

        address peggedOnOtherSide = $._otherSidePeggedForOrigin[token];
        if (peggedOnOtherSide == address(0)) {
            peggedOnOtherSide = _computeOtherSidePeggedTokenAddressWithGateway(otherSideGateway, token);
            $._otherSidePeggedForOrigin[token] = peggedOnOtherSide;
        }

        return abi.encodeCall(IERC721Gateway.receivePeggedToken, (token, peggedOnOtherSide, sender, to, tokenId, tokenMetadata));
    }

    function _sendPeggedToken(address peggedToken, address sender, address from, address to, uint256 tokenId) internal returns (bytes memory) {
        address originAddress = getTokenMapping(peggedToken);
        require(originAddress != address(0), ZeroAddressNotAllowed("originAddress"));
        _requireBridgingAllowedForOrigin(originAddress);
        ERC721PeggedToken(peggedToken).burn(from, tokenId);
        return abi.encodeCall(IERC721Gateway.receiveOriginToken, (originAddress, sender, to, tokenId));
    }

    function _readCollectionAndUri(address token, uint256 tokenId) internal view returns (string memory name, string memory symbol, string memory uri) {
        try IERC721Metadata(token).name() returns (string memory n) {
            name = n;
        } catch {
            name = "";
        }
        try IERC721Metadata(token).symbol() returns (string memory s) {
            symbol = s;
        } catch {
            symbol = "";
        }
        try IERC721Metadata(token).tokenURI(tokenId) returns (string memory u) {
            uri = u;
        } catch {
            uri = "";
        }
    }

    /// @inheritdoc IERC721Gateway
    function receivePeggedToken(
        address originToken,
        address peggedToken,
        address from,
        address to,
        uint256 tokenId,
        bytes calldata tokenMetadata
    ) external onlyFluentBridge nonReentrant {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(originToken != address(0), ZeroAddressNotAllowed("originToken"));
        require(to != address(0), InvalidRecipient());
        _requireBridgingAllowedForOrigin(originToken);

        if (peggedToken.code.length == 0) {
            address deployed = _deployPeggedToken(tokenMetadata, originToken);
            require(deployed == peggedToken, WrongPeggedToken());
            _getERC721GatewayStorage()._tokenMapping[peggedToken] = originToken;
        } else {
            require(getTokenMapping(peggedToken) == originToken, TokenMappingCheckFailed());
        }

        (, , string memory uri) = abi.decode(tokenMetadata, (string, string, string));

        _consumeLimit(originToken, 1);

        ERC721PeggedToken(peggedToken).mint(to, tokenId, uri);

        emit ReceivedTokens(from, to, 1);
        emit ReceivedNFT(from, to, tokenId);
    }

    /// @inheritdoc IERC721Gateway
    function receiveOriginToken(address originToken, address from, address to, uint256 tokenId) external onlyFluentBridge nonReentrant {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(originToken != address(0), OriginTokenZero());
        require(to != address(0), InvalidRecipient());
        _requireBridgingAllowedForOrigin(originToken);

        _consumeLimit(originToken, 1);

        require(IERC721(originToken).ownerOf(tokenId) == address(this), GatewayDoesNotHoldToken());
        IERC721(originToken).safeTransferFrom(address(this), to, tokenId);

        emit ReceivedTokens(from, to, 1);
        emit ReceivedNFT(from, to, tokenId);
    }

    function _deployPeggedToken(bytes memory tokenMetadata, address originToken) internal returns (address) {
        (string memory name, string memory symbol, ) = abi.decode(tokenMetadata, (string, string, string));
        ERC721GatewayStorage storage $ = _getERC721GatewayStorage();
        bytes memory deployArgs = IGenericTokenFactory($._tokenFactory).getDeployArgs(name, symbol, 0);
        address peggedToken = IGenericTokenFactory($._tokenFactory).deployToken(address(this), originToken, deployArgs);
        if (deployArgs.length == 0) ERC721PeggedToken(peggedToken).initialize(name, symbol, originToken);
        return peggedToken;
    }

    /// @inheritdoc IERC721Gateway
    function getTokenFactory() public view returns (address) {
        return _getERC721GatewayStorage()._tokenFactory;
    }

    function getOtherSideTokenImplementation() public view returns (address) {
        return _getERC721GatewayStorage()._otherSideTokenImplementation;
    }

    function getOtherSideFactory() public view returns (address) {
        return _getERC721GatewayStorage()._otherSideFactory;
    }

    function getOtherSideBeacon() public view returns (address) {
        return _getERC721GatewayStorage()._otherSideBeacon;
    }

    /// @inheritdoc IERC721Gateway
    function getTokenMapping(address key) public view returns (address) {
        return _getERC721GatewayStorage()._tokenMapping[key];
    }

    /// @inheritdoc IERC721Gateway
    function computeOtherSidePeggedTokenAddress(address gateway, address originToken) external view returns (address) {
        address cached = _getERC721GatewayStorage()._otherSidePeggedForOrigin[originToken];
        if (cached != address(0)) return cached;
        return _computeOtherSidePeggedTokenAddressWithGateway(gateway, originToken);
    }

    /// @inheritdoc IERC721Gateway
    function computeTokenAddress(address gateway, address originToken) external view returns (address) {
        bytes memory deployArgs;
        if (IGenericTokenFactory(getTokenFactory()).beacon() != address(0)) {
            deployArgs = "";
        } else {
            deployArgs = IGenericTokenFactory(getTokenFactory()).getDeployArgs("", "", 0);
        }
        return IGenericTokenFactory(getTokenFactory()).computeTokenAddress(gateway, originToken, deployArgs);
    }

    function _computeOtherSidePeggedTokenAddressWithGateway(address otherSideGateway, address originToken) internal view returns (address) {
        return _computeBeaconProxyAddress(getOtherSideFactory(), getOtherSideBeacon(), otherSideGateway, originToken);
    }

    function _computeBeaconProxyAddress(address factory, address beacon, address gateway, address originToken) internal pure returns (address) {
        bytes memory bytecode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, ""));
        bytes32 salt = keccak256(abi.encodePacked(gateway, originToken));
        bytes32 bytecodeHash = keccak256(bytecode);
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, bytecodeHash)))));
    }

    /// @inheritdoc IERC721Gateway
    function setTokenFactory(address tokenFactory) external onlyOwner {
        _setTokenFactory(tokenFactory);
    }

    function _setTokenFactory(address tokenFactory) internal {
        require(tokenFactory != address(0), ZeroAddressNotAllowed("tokenFactory"));
        ERC721GatewayStorage storage $ = _getERC721GatewayStorage();
        emit TokenFactoryUpdated($._tokenFactory, tokenFactory);
        $._tokenFactory = tokenFactory;
    }

    /// @inheritdoc IERC721Gateway
    function setOtherSideTokenImplementation(address otherSideTokenImplementation) external onlyOwner {
        require(otherSideTokenImplementation != address(0), ZeroAddressNotAllowed("otherSideTokenImplementation"));
        ERC721GatewayStorage storage $ = _getERC721GatewayStorage();
        emit OtherSideTokenImplementationUpdated($._otherSideTokenImplementation, otherSideTokenImplementation);
        $._otherSideTokenImplementation = otherSideTokenImplementation;
    }

    /// @inheritdoc IERC721Gateway
    function setOtherSide(
        address otherSideGateway,
        uint256 otherSideChainId,
        address otherSideTokenImplementation,
        address otherSideFactory,
        address otherSideBeacon
    ) external onlyOwner {
        require(
            otherSideGateway != address(0) && otherSideTokenImplementation != address(0) && otherSideFactory != address(0),
            ZeroAddressNotAllowed("otherSideGateway or otherSideTokenImplementation or otherSideFactory")
        );
        ERC721GatewayStorage storage $ = _getERC721GatewayStorage();
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
        _setOtherSideGateway(otherSideGateway);
        $._otherSideTokenImplementation = otherSideTokenImplementation;
        $._otherSideFactory = otherSideFactory;
        $._otherSideBeacon = otherSideBeacon;
        _setOtherSideChainId(otherSideChainId);
    }

    /// @inheritdoc IERC721Gateway
    function isBridgingExcludedOrigin(address originToken) external view returns (bool) {
        return _getERC721GatewayStorage()._bridgingExcludedOrigins[originToken];
    }

    /// @inheritdoc IERC721Gateway
    function setBridgingExcludedOrigin(address originToken, bool excluded) external onlyOwner {
        require(originToken != address(0), ZeroAddressNotAllowed("originToken"));
        ERC721GatewayStorage storage $ = _getERC721GatewayStorage();
        emit BridgingExcludedOriginUpdated(originToken, excluded);
        $._bridgingExcludedOrigins[originToken] = excluded;
    }
}
