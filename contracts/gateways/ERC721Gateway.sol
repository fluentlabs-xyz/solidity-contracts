// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

import {FluentBridge} from "../bridge/FluentBridge.sol";
import {IGenericTokenFactory} from "../interfaces/IGenericTokenFactory.sol";
import {IERC721Gateway} from "../interfaces/gateways/IERC721Gateway.sol";
import {ERC721PeggedToken} from "../tokens/ERC721PeggedToken.sol";
import {GatewayBase} from "./GatewayBase.sol";

contract ERC721Gateway is GatewayBase, IERC721Gateway, IERC721Receiver {
    bytes32 private constant ERC721_GATEWAY_STORAGE_LOCATION =
        0xa4ae678d969d5e376a3d5cbf49bfd4ff38b460d93543aaf10853d46d47d74200;

    struct ERC721GatewayStorage {
        address _tokenFactory;
        address _otherSideFactory;
        address _otherSideBeacon;
        mapping(address => address) _tokenMapping;
        mapping(address => address) _otherSidePeggedForOrigin;
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

    function sendToken(address token, address to, uint256 tokenId) external payable nonReentrant {
        address sender = msg.sender;
        address otherSideGateway = getOtherSideGateway();
        require(otherSideGateway != address(0), ZeroAddressNotAllowed("getOtherSideGateway"));
        require(to != address(0), InvalidRecipient());
        require(msg.value == FluentBridge(getBridgeContract()).getSentMessageFee(), ExactFeeRequired());
        _requireAccountNotBlacklisted(sender);
        _requireAccountNotBlacklisted(to);

        bytes memory message;
        if (getTokenMapping(token) == address(0)) {
            message = _sendOriginToken(token, sender, to, tokenId, otherSideGateway);
        } else {
            message = _sendPeggedToken(token, sender, to, tokenId);
        }

        FluentBridge(getBridgeContract()).sendMessage{value: msg.value}(otherSideGateway, message);
    }

    function _sendOriginToken(address token, address sender, address to, uint256 tokenId, address otherSideGateway)
        internal
        returns (bytes memory)
    {
        require(getOtherSideFactory() != address(0), ZeroAddressNotAllowed("getOtherSideFactory"));
        require(getOtherSideBeacon() != address(0), ZeroAddressNotAllowed("getOtherSideBeacon"));

        IERC721(token).safeTransferFrom(sender, address(this), tokenId);
        bytes memory tokenMetadata = abi.encode(_safeName(token), _safeSymbol(token), _safeTokenURI(token, tokenId));

        ERC721GatewayStorage storage $ = _getERC721GatewayStorage();
        address peggedTokenOnOtherSide = $._otherSidePeggedForOrigin[token];
        if (peggedTokenOnOtherSide == address(0)) {
            peggedTokenOnOtherSide = _computeOtherSidePeggedTokenAddressWithGateway(otherSideGateway, token);
            $._otherSidePeggedForOrigin[token] = peggedTokenOnOtherSide;
        }

        return abi.encodeCall(
            IERC721Gateway.receivePeggedToken, (token, peggedTokenOnOtherSide, sender, to, tokenId, tokenMetadata)
        );
    }

    function _sendPeggedToken(address peggedToken, address sender, address to, uint256 tokenId)
        internal
        returns (bytes memory)
    {
        address originAddress = getTokenMapping(peggedToken);
        require(originAddress != address(0), ZeroAddressNotAllowed("originAddress"));
        ERC721PeggedToken(peggedToken).burn(sender, tokenId);
        return abi.encodeCall(IERC721Gateway.receiveOriginToken, (originAddress, sender, to, tokenId));
    }

    function receivePeggedToken(
        address originToken,
        address peggedToken,
        address from,
        address to,
        uint256 tokenId,
        bytes calldata tokenMetadata
    ) external onlyFluentBridge nonReentrant {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(originToken != address(0), OriginTokenZero());
        require(to != address(0), InvalidRecipient());

        if (peggedToken.code.length == 0) {
            address newPeggedToken = _deployPeggedToken(tokenMetadata, originToken);
            require(newPeggedToken == peggedToken, WrongPeggedToken());
            _getERC721GatewayStorage()._tokenMapping[peggedToken] = originToken;
        } else {
            require(getTokenMapping(peggedToken) == originToken, TokenMappingCheckFailed());
        }

        _consumeLimit(originToken, 1);
        (,, string memory tokenURI_) = abi.decode(tokenMetadata, (string, string, string));
        ERC721PeggedToken(peggedToken).mint(to, tokenId, tokenURI_);
        emit ReceivedTokens(from, to, 1);
    }

    function receiveOriginToken(address originToken, address from, address to, uint256 tokenId)
        external
        onlyFluentBridge
        nonReentrant
    {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(originToken != address(0), OriginTokenZero());
        require(to != address(0), InvalidRecipient());
        _consumeLimit(originToken, 1);
        IERC721(originToken).safeTransferFrom(address(this), to, tokenId);
        emit ReceivedTokens(from, to, 1);
    }

    function _deployPeggedToken(bytes calldata tokenMetadata, address originToken) internal returns (address) {
        (string memory name_, string memory symbol_,) = abi.decode(tokenMetadata, (string, string, string));
        address peggedToken = IGenericTokenFactory(getTokenFactory()).deployToken(address(this), originToken, bytes(""));
        ERC721PeggedToken(peggedToken).initialize(name_, symbol_, originToken);
        return peggedToken;
    }

    function getTokenFactory() public view returns (address) {
        return _getERC721GatewayStorage()._tokenFactory;
    }

    function getOtherSideFactory() public view returns (address) {
        return _getERC721GatewayStorage()._otherSideFactory;
    }

    function getOtherSideBeacon() public view returns (address) {
        return _getERC721GatewayStorage()._otherSideBeacon;
    }

    function getTokenMapping(address peggedToken) public view returns (address) {
        return _getERC721GatewayStorage()._tokenMapping[peggedToken];
    }

    function computeTokenAddress(address gateway, address originToken) external view returns (address) {
        return IGenericTokenFactory(getTokenFactory()).computeTokenAddress(gateway, originToken, bytes(""));
    }

    function computeOtherSidePeggedTokenAddress(address gateway, address originToken) external view returns (address) {
        address cached = _getERC721GatewayStorage()._otherSidePeggedForOrigin[originToken];
        if (cached != address(0)) return cached;
        return _computeOtherSidePeggedTokenAddressWithGateway(gateway, originToken);
    }

    function setTokenFactory(address tokenFactory) external onlyOwner {
        _setTokenFactory(tokenFactory);
    }

    function _setTokenFactory(address tokenFactory) internal {
        require(tokenFactory != address(0), ZeroAddressNotAllowed("tokenFactory"));
        _getERC721GatewayStorage()._tokenFactory = tokenFactory;
    }

    function setOtherSide(
        address otherSideGateway,
        uint256 otherSideChainId,
        address otherSideFactory,
        address otherSideBeacon
    ) external onlyOwner {
        _setOtherSideGateway(otherSideGateway);
        _setOtherSideChainId(otherSideChainId);
        require(otherSideFactory != address(0), ZeroAddressNotAllowed("otherSideFactory"));
        require(otherSideBeacon != address(0), ZeroAddressNotAllowed("otherSideBeacon"));
        ERC721GatewayStorage storage $ = _getERC721GatewayStorage();
        $._otherSideFactory = otherSideFactory;
        $._otherSideBeacon = otherSideBeacon;
    }

    function _computeOtherSidePeggedTokenAddressWithGateway(address gateway, address originToken)
        internal
        view
        returns (address)
    {
        bytes memory bytecode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(getOtherSideBeacon(), ""));
        bytes32 salt = keccak256(abi.encodePacked(gateway, originToken));
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), getOtherSideFactory(), salt, keccak256(bytecode))))
            )
        );
    }

    function _safeName(address token) internal view returns (string memory) {
        try IERC721Metadata(token).name() returns (string memory value) {
            return value;
        } catch {
            return "Bridged ERC721";
        }
    }

    function _safeSymbol(address token) internal view returns (string memory) {
        try IERC721Metadata(token).symbol() returns (string memory value) {
            return value;
        } catch {
            return "bNFT";
        }
    }

    function _safeTokenURI(address token, uint256 tokenId) internal view returns (string memory) {
        try IERC721Metadata(token).tokenURI(tokenId) returns (string memory value) {
            return value;
        } catch {
            return "";
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
