// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import {FluentBridge} from "../bridge/FluentBridge.sol";
import {IGenericTokenFactory} from "../interfaces/IGenericTokenFactory.sol";
import {IERC721Gateway} from "../interfaces/gateways/IERC721Gateway.sol";
import {ERC721PeggedToken} from "../tokens/ERC721PeggedToken.sol";
import {GatewayBase} from "./GatewayBase.sol";

/**
 * @title ERC721Gateway
 * @notice Bridges ERC-721 collections by escrowing origin NFTs and minting pegged NFTs.
 */
contract ERC721Gateway is GatewayBase, ERC721Holder, IERC721Gateway {
    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.ERC721GatewayStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC721_GATEWAY_STORAGE_LOCATION =
        0x2d02445dc319c1057f1fe71b04c2b24cac361e6ca849517bc1c75d980f08c400;

    /// @custom:storage-location erc7201:Fluent.storage.ERC721GatewayStorage
    struct ERC721GatewayStorage {
        address _tokenFactory;
        address _otherSideTokenImplementation;
        address _otherSideFactory;
        address _otherSideBeacon;
        mapping(address => address) _tokenMapping;
        mapping(address => address) _otherSidePeggedForOrigin;
        uint256[50] __gap;
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

        bytes memory message = getTokenMapping(token) == address(0)
            ? _sendOriginToken(token, sender, to, tokenId, otherSideGateway)
            : _sendPeggedToken(token, sender, to, tokenId);

        FluentBridge(bridgeContract).sendMessage{value: msg.value}(otherSideGateway, message);
    }

    function _sendOriginToken(address token, address sender, address to, uint256 tokenId, address otherSideGateway)
        internal
        returns (bytes memory)
    {
        require(getOtherSideFactory() != address(0), ZeroAddressNotAllowed("getOtherSideFactory"));
        require(getOtherSideBeacon() != address(0), ZeroAddressNotAllowed("getOtherSideBeacon"));

        IERC721(token).safeTransferFrom(sender, address(this), tokenId);
        bytes memory tokenMetadata = abi.encode(IERC721Metadata(token).name(), IERC721Metadata(token).symbol());
        string memory uri = _readTokenURI(token, tokenId);

        ERC721GatewayStorage storage $ = _getERC721GatewayStorage();
        address peggedTokenOnOtherSide = $._otherSidePeggedForOrigin[token];
        if (peggedTokenOnOtherSide == address(0)) {
            peggedTokenOnOtherSide = _computeOtherSidePeggedTokenAddressWithGateway(otherSideGateway, token);
            $._otherSidePeggedForOrigin[token] = peggedTokenOnOtherSide;
        }

        return abi.encodeCall(
            IERC721Gateway.receivePeggedToken, (token, peggedTokenOnOtherSide, sender, to, tokenId, tokenMetadata, uri)
        );
    }

    function _sendPeggedToken(address peggedToken, address sender, address to, uint256 tokenId)
        internal
        returns (bytes memory)
    {
        address originAddress = getTokenMapping(peggedToken);
        require(originAddress != address(0), ZeroAddressNotAllowed("originAddress"));
        require(IERC721(peggedToken).ownerOf(tokenId) == sender, NotTokenOwner());
        ERC721PeggedToken(peggedToken).burn(tokenId);
        return abi.encodeCall(IERC721Gateway.receiveOriginToken, (originAddress, sender, to, tokenId));
    }

    /// @inheritdoc IERC721Gateway
    function receivePeggedToken(
        address originToken,
        address peggedToken,
        address from,
        address to,
        uint256 tokenId,
        bytes calldata tokenMetadata,
        string calldata tokenURI
    ) external onlyFluentBridge nonReentrant {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(originToken != address(0), ZeroAddressNotAllowed("originToken"));
        require(to != address(0), InvalidRecipient());

        if (peggedToken.code.length == 0) {
            address newPeggedToken = _deployPeggedToken(tokenMetadata, originToken);
            require(newPeggedToken == peggedToken, WrongPeggedToken());
            _getERC721GatewayStorage()._tokenMapping[peggedToken] = originToken;
        } else {
            require(getTokenMapping(peggedToken) == originToken, TokenMappingCheckFailed());
        }

        ERC721PeggedToken(peggedToken).mint(to, tokenId, tokenURI);
        emit ReceivedTokens(from, to, 1);
    }

    /// @inheritdoc IERC721Gateway
    function receiveOriginToken(address originToken, address from, address to, uint256 tokenId)
        external
        onlyFluentBridge
        nonReentrant
    {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(originToken != address(0), OriginTokenZero());
        require(to != address(0), InvalidRecipient());
        IERC721(originToken).safeTransferFrom(address(this), to, tokenId);
        emit ReceivedTokens(from, to, 1);
    }

    function _deployPeggedToken(bytes memory tokenMetadata, address originToken) internal returns (address) {
        (string memory name, string memory symbol) = abi.decode(tokenMetadata, (string, string));
        address peggedToken = IGenericTokenFactory(getTokenFactory()).deployToken(address(this), originToken, "");
        ERC721PeggedToken(peggedToken).initialize(name, symbol, originToken);
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
    function computeOtherSidePeggedTokenAddress(address, address originToken) external view returns (address) {
        address cached = _getERC721GatewayStorage()._otherSidePeggedForOrigin[originToken];
        if (cached != address(0)) return cached;
        return _computeOtherSidePeggedTokenAddressWithGateway(getOtherSideGateway(), originToken);
    }

    /// @inheritdoc IERC721Gateway
    function computeTokenAddress(address gateway, address originToken) external view returns (address) {
        return IGenericTokenFactory(getTokenFactory()).computeTokenAddress(gateway, originToken, "");
    }

    function _computeOtherSidePeggedTokenAddressWithGateway(address otherSideGateway, address originToken)
        internal
        view
        returns (address)
    {
        return _computeBeaconProxyAddress(getOtherSideFactory(), getOtherSideBeacon(), otherSideGateway, originToken);
    }

    function _computeBeaconProxyAddress(address factory, address beacon, address gateway, address originToken)
        internal
        pure
        returns (address)
    {
        bytes memory bytecode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, ""));
        bytes32 salt = keccak256(abi.encodePacked(gateway, originToken));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, keccak256(bytecode))))));
    }

    function setTokenFactory(address tokenFactory) external onlyOwner {
        _setTokenFactory(tokenFactory);
    }

    function _setTokenFactory(address tokenFactory) internal {
        require(tokenFactory != address(0), ZeroAddressNotAllowed("tokenFactory"));
        ERC721GatewayStorage storage $ = _getERC721GatewayStorage();
        emit TokenFactoryUpdated($._tokenFactory, tokenFactory);
        $._tokenFactory = tokenFactory;
    }

    function setOtherSide(
        address otherSideGateway,
        uint256 otherSideChainId,
        address otherSideTokenImplementation,
        address otherSideFactory,
        address otherSideBeacon
    ) external onlyOwner {
        require(
            otherSideGateway != address(0) && otherSideTokenImplementation != address(0)
                && otherSideFactory != address(0) && otherSideBeacon != address(0),
            ZeroAddressNotAllowed(
                "otherSideGateway or otherSideTokenImplementation or otherSideFactory or otherSideBeacon"
            )
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
        _setOtherSideChainId(otherSideChainId);
        $._otherSideTokenImplementation = otherSideTokenImplementation;
        $._otherSideFactory = otherSideFactory;
        $._otherSideBeacon = otherSideBeacon;
    }

    function _readTokenURI(address token, uint256 tokenId) internal view returns (string memory) {
        try IERC721Metadata(token).tokenURI(tokenId) returns (string memory uri) {
            return uri;
        } catch {
            return "";
        }
    }
}
