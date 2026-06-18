// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC1155MetadataURI} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";

import {FluentBridge} from "../bridge/FluentBridge.sol";
import {IGenericTokenFactory} from "../interfaces/IGenericTokenFactory.sol";
import {IERC1155Gateway} from "../interfaces/gateways/IERC1155Gateway.sol";
import {ERC1155PeggedToken} from "../tokens/ERC1155PeggedToken.sol";
import {GatewayBase} from "./GatewayBase.sol";

contract ERC1155Gateway is GatewayBase, IERC1155Gateway, IERC1155Receiver {
    bytes32 private constant ERC1155_GATEWAY_STORAGE_LOCATION =
        0x113de23f3a8ef961526334710552f2303ead3f5990e1c9e1443fc1eb6358a400;

    struct ERC1155GatewayStorage {
        address _tokenFactory;
        address _otherSideFactory;
        address _otherSideBeacon;
        mapping(address => address) _tokenMapping;
        mapping(address => address) _otherSidePeggedForOrigin;
        uint256[48] __gap;
    }

    function _getERC1155GatewayStorage() private pure returns (ERC1155GatewayStorage storage $) {
        assembly ("memory-safe") {
            $.slot := ERC1155_GATEWAY_STORAGE_LOCATION
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

    function sendToken(address token, address to, uint256 id, uint256 amount, bytes calldata data)
        external
        payable
        nonReentrant
    {
        require(amount > 0, ZeroValueNotAllowed("amount"));
        bytes memory message = _buildSendMessage(token, msg.sender, to, _singleton(id), _singleton(amount), data, false);
        FluentBridge(getBridgeContract()).sendMessage{value: msg.value}(getOtherSideGateway(), message);
    }

    function sendBatch(
        address token,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external payable nonReentrant {
        require(ids.length == amounts.length && ids.length != 0, InvalidArrayLength());
        _requireNonZeroAmounts(amounts);
        bytes memory message = _buildSendMessage(token, msg.sender, to, ids, amounts, data, true);
        FluentBridge(getBridgeContract()).sendMessage{value: msg.value}(getOtherSideGateway(), message);
    }

    function _buildSendMessage(
        address token,
        address sender,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes calldata data,
        bool batch
    ) internal returns (bytes memory) {
        address otherSideGateway = getOtherSideGateway();
        require(otherSideGateway != address(0), ZeroAddressNotAllowed("getOtherSideGateway"));
        require(to != address(0), InvalidRecipient());
        require(msg.value == FluentBridge(getBridgeContract()).getSentMessageFee(), ExactFeeRequired());
        _requireAccountNotBlacklisted(sender);
        _requireAccountNotBlacklisted(to);

        if (getTokenMapping(token) == address(0)) {
            return _sendOriginTokens(token, sender, to, ids, amounts, data, batch, otherSideGateway);
        }
        return _sendPeggedTokens(token, sender, to, ids, amounts, data, batch);
    }

    function _sendOriginTokens(
        address token,
        address sender,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes calldata data,
        bool batch,
        address otherSideGateway
    ) internal returns (bytes memory) {
        require(getOtherSideFactory() != address(0), ZeroAddressNotAllowed("getOtherSideFactory"));
        require(getOtherSideBeacon() != address(0), ZeroAddressNotAllowed("getOtherSideBeacon"));

        if (batch) {
            IERC1155(token).safeBatchTransferFrom(sender, address(this), ids, amounts, data);
        } else {
            IERC1155(token).safeTransferFrom(sender, address(this), ids[0], amounts[0], data);
        }

        bytes memory tokenMetadata = abi.encode(_safeURI(token, ids[0]));
        ERC1155GatewayStorage storage $ = _getERC1155GatewayStorage();
        address peggedTokenOnOtherSide = $._otherSidePeggedForOrigin[token];
        if (peggedTokenOnOtherSide == address(0)) {
            peggedTokenOnOtherSide = _computeOtherSidePeggedTokenAddressWithGateway(otherSideGateway, token);
            $._otherSidePeggedForOrigin[token] = peggedTokenOnOtherSide;
        }

        if (batch) {
            return abi.encodeCall(
                IERC1155Gateway.receivePeggedBatch,
                (token, peggedTokenOnOtherSide, sender, to, ids, amounts, data, tokenMetadata)
            );
        }
        return abi.encodeCall(
            IERC1155Gateway.receivePeggedToken,
            (token, peggedTokenOnOtherSide, sender, to, ids[0], amounts[0], data, tokenMetadata)
        );
    }

    function _sendPeggedTokens(
        address peggedToken,
        address sender,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes calldata data,
        bool batch
    ) internal returns (bytes memory) {
        address originAddress = getTokenMapping(peggedToken);
        require(originAddress != address(0), ZeroAddressNotAllowed("originAddress"));
        if (batch) {
            ERC1155PeggedToken(peggedToken).burnBatch(sender, ids, amounts);
            return abi.encodeCall(IERC1155Gateway.receiveOriginBatch, (originAddress, sender, to, ids, amounts, data));
        }
        ERC1155PeggedToken(peggedToken).burn(sender, ids[0], amounts[0]);
        return abi.encodeCall(IERC1155Gateway.receiveOriginToken, (originAddress, sender, to, ids[0], amounts[0], data));
    }

    function receivePeggedToken(
        address originToken,
        address peggedToken,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data,
        bytes calldata tokenMetadata
    ) external onlyFluentBridge nonReentrant {
        _requireReceivePegged(originToken, peggedToken, to, tokenMetadata);
        _consumeLimit(originToken, amount);
        ERC1155PeggedToken(peggedToken).mint(to, id, amount, data);
        emit ReceivedTokens(from, to, amount);
    }

    function receivePeggedBatch(
        address originToken,
        address peggedToken,
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data,
        bytes calldata tokenMetadata
    ) external onlyFluentBridge nonReentrant {
        require(ids.length == amounts.length && ids.length != 0, InvalidArrayLength());
        _requireReceivePegged(originToken, peggedToken, to, tokenMetadata);
        uint256 total = _sum(amounts);
        _consumeLimit(originToken, total);
        ERC1155PeggedToken(peggedToken).mintBatch(to, ids, amounts, data);
        emit ReceivedTokens(from, to, total);
    }

    function _requireReceivePegged(address originToken, address peggedToken, address to, bytes calldata tokenMetadata)
        internal
    {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(originToken != address(0), OriginTokenZero());
        require(to != address(0), InvalidRecipient());

        if (peggedToken.code.length == 0) {
            address newPeggedToken = _deployPeggedToken(tokenMetadata, originToken);
            require(newPeggedToken == peggedToken, WrongPeggedToken());
            _getERC1155GatewayStorage()._tokenMapping[peggedToken] = originToken;
        } else {
            require(getTokenMapping(peggedToken) == originToken, TokenMappingCheckFailed());
        }
    }

    function receiveOriginToken(
        address originToken,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external onlyFluentBridge nonReentrant {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(originToken != address(0), OriginTokenZero());
        require(to != address(0), InvalidRecipient());
        _consumeLimit(originToken, amount);
        IERC1155(originToken).safeTransferFrom(address(this), to, id, amount, data);
        emit ReceivedTokens(from, to, amount);
    }

    function receiveOriginBatch(
        address originToken,
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external onlyFluentBridge nonReentrant {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(originToken != address(0), OriginTokenZero());
        require(to != address(0), InvalidRecipient());
        require(ids.length == amounts.length && ids.length != 0, InvalidArrayLength());
        uint256 total = _sum(amounts);
        _consumeLimit(originToken, total);
        IERC1155(originToken).safeBatchTransferFrom(address(this), to, ids, amounts, data);
        emit ReceivedTokens(from, to, total);
    }

    function _deployPeggedToken(bytes calldata tokenMetadata, address originToken) internal returns (address) {
        string memory uri_ = abi.decode(tokenMetadata, (string));
        address peggedToken = IGenericTokenFactory(getTokenFactory()).deployToken(address(this), originToken, bytes(""));
        ERC1155PeggedToken(peggedToken).initialize(uri_, originToken);
        return peggedToken;
    }

    function getTokenFactory() public view returns (address) {
        return _getERC1155GatewayStorage()._tokenFactory;
    }

    function getOtherSideFactory() public view returns (address) {
        return _getERC1155GatewayStorage()._otherSideFactory;
    }

    function getOtherSideBeacon() public view returns (address) {
        return _getERC1155GatewayStorage()._otherSideBeacon;
    }

    function getTokenMapping(address peggedToken) public view returns (address) {
        return _getERC1155GatewayStorage()._tokenMapping[peggedToken];
    }

    function computeTokenAddress(address gateway, address originToken) external view returns (address) {
        return IGenericTokenFactory(getTokenFactory()).computeTokenAddress(gateway, originToken, bytes(""));
    }

    function computeOtherSidePeggedTokenAddress(address gateway, address originToken) external view returns (address) {
        address cached = _getERC1155GatewayStorage()._otherSidePeggedForOrigin[originToken];
        if (cached != address(0)) return cached;
        return _computeOtherSidePeggedTokenAddressWithGateway(gateway, originToken);
    }

    function setTokenFactory(address tokenFactory) external onlyOwner {
        _setTokenFactory(tokenFactory);
    }

    function _setTokenFactory(address tokenFactory) internal {
        require(tokenFactory != address(0), ZeroAddressNotAllowed("tokenFactory"));
        _getERC1155GatewayStorage()._tokenFactory = tokenFactory;
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
        ERC1155GatewayStorage storage $ = _getERC1155GatewayStorage();
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

    function _safeURI(address token, uint256 id) internal view returns (string memory) {
        try IERC1155MetadataURI(token).uri(id) returns (string memory value) {
            return value;
        } catch {
            return "";
        }
    }

    function _singleton(uint256 value) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _sum(uint256[] calldata values) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < values.length; ++i) {
            total += values[i];
        }
    }

    function _requireNonZeroAmounts(uint256[] calldata values) internal pure {
        for (uint256 i = 0; i < values.length; ++i) {
            require(values[i] > 0, ZeroValueNotAllowed("amount"));
        }
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}
