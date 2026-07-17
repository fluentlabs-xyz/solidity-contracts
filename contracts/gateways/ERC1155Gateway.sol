// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155MetadataURI} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {FluentBridge} from "../bridge/FluentBridge.sol";
import {IGenericTokenFactory} from "../interfaces/IGenericTokenFactory.sol";
import {IERC1155Gateway} from "../interfaces/gateways/IERC1155Gateway.sol";
import {ERC1155PeggedToken} from "../tokens/ERC1155PeggedToken.sol";
import {GatewayBase} from "./GatewayBase.sol";

/**
 * @title ERC1155Gateway
 * @notice Bridges ERC-1155 collections by escrowing origin tokens and minting pegged tokens.
 */
contract ERC1155Gateway is GatewayBase, ERC1155Holder, IERC1155Gateway {
    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.ERC1155GatewayStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC1155_GATEWAY_STORAGE_LOCATION =
        0xed1397fe0b9948d22bd54994c7ec90279149edc7f1f8d197548412e354426e00;

    /// @custom:storage-location erc7201:Fluent.storage.ERC1155GatewayStorage
    struct ERC1155GatewayStorage {
        address _tokenFactory;
        address _otherSideTokenImplementation;
        address _otherSideFactory;
        address _otherSideBeacon;
        mapping(address => address) _tokenMapping;
        mapping(address => address) _otherSidePeggedForOrigin;
        uint256[50] __gap;
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

    /// @inheritdoc IERC1155Gateway
    function sendToken(address token, address to, uint256 id, uint256 amount) external payable nonReentrant {
        require(amount > 0, ZeroValueNotAllowed("amount"));
        _send(token, to, _single(id), _single(amount), false);
    }

    /// @inheritdoc IERC1155Gateway
    function sendBatchTokens(address token, address to, uint256[] calldata ids, uint256[] calldata amounts)
        external
        payable
        nonReentrant
    {
        require(ids.length == amounts.length, ArrayLengthMismatch());
        require(ids.length > 0, ZeroValueNotAllowed("ids"));
        _send(token, to, ids, amounts, true);
    }

    function _send(address token, address to, uint256[] memory ids, uint256[] memory amounts, bool batch) internal {
        address sender = msg.sender;
        address otherSideGateway = getOtherSideGateway();
        address bridgeContract = getBridgeContract();
        require(otherSideGateway != address(0), ZeroAddressNotAllowed("getOtherSideGateway"));
        require(to != address(0), InvalidRecipient());
        require(msg.value == FluentBridge(bridgeContract).getSentMessageFee(), ExactFeeRequired());
        _requireAccountNotBlacklisted(sender);
        _requireAccountNotBlacklisted(to);

        bytes memory message = getTokenMapping(token) == address(0)
            ? _sendOriginTokens(token, sender, to, ids, amounts, batch, otherSideGateway)
            : _sendPeggedTokens(token, sender, to, ids, amounts, batch);

        FluentBridge(bridgeContract).sendMessage{value: msg.value}(otherSideGateway, message);
    }

    function _sendOriginTokens(
        address token,
        address sender,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bool batch,
        address otherSideGateway
    ) internal returns (bytes memory) {
        require(getOtherSideFactory() != address(0), ZeroAddressNotAllowed("getOtherSideFactory"));
        require(getOtherSideBeacon() != address(0), ZeroAddressNotAllowed("getOtherSideBeacon"));

        if (batch) IERC1155(token).safeBatchTransferFrom(sender, address(this), ids, amounts, "");
        else IERC1155(token).safeTransferFrom(sender, address(this), ids[0], amounts[0], "");

        ERC1155GatewayStorage storage $ = _getERC1155GatewayStorage();
        address peggedTokenOnOtherSide = $._otherSidePeggedForOrigin[token];
        if (peggedTokenOnOtherSide == address(0)) {
            peggedTokenOnOtherSide = _computeOtherSidePeggedTokenAddressWithGateway(otherSideGateway, token);
            $._otherSidePeggedForOrigin[token] = peggedTokenOnOtherSide;
        }

        if (batch) {
            string[] memory uris = new string[](ids.length);
            for (uint256 i = 0; i < ids.length; i++) {
                uris[i] = _readURI(token, ids[i]);
            }
            return abi.encodeCall(
                IERC1155Gateway.receivePeggedBatchTokens,
                (token, peggedTokenOnOtherSide, sender, to, ids, amounts, uris)
            );
        }
        return abi.encodeCall(
            IERC1155Gateway.receivePeggedTokens,
            (token, peggedTokenOnOtherSide, sender, to, ids[0], amounts[0], _readURI(token, ids[0]))
        );
    }

    function _sendPeggedTokens(
        address peggedToken,
        address sender,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bool batch
    ) internal returns (bytes memory) {
        address originAddress = getTokenMapping(peggedToken);
        require(originAddress != address(0), ZeroAddressNotAllowed("originAddress"));
        if (batch) {
            ERC1155PeggedToken(peggedToken).burnBatch(sender, ids, amounts);
            return abi.encodeCall(IERC1155Gateway.receiveOriginBatchTokens, (originAddress, sender, to, ids, amounts));
        }
        ERC1155PeggedToken(peggedToken).burn(sender, ids[0], amounts[0]);
        return abi.encodeCall(IERC1155Gateway.receiveOriginTokens, (originAddress, sender, to, ids[0], amounts[0]));
    }

    /// @inheritdoc IERC1155Gateway
    function receivePeggedTokens(
        address originToken,
        address peggedToken,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        string calldata uri
    ) external onlyFluentBridge nonReentrant {
        require(amount > 0, ZeroValueNotAllowed("amount"));
        string[] memory uris = new string[](1);
        uris[0] = uri;
        _receivePegged(originToken, peggedToken, from, to, _single(id), _single(amount), uris, false);
    }

    /// @inheritdoc IERC1155Gateway
    function receivePeggedBatchTokens(
        address originToken,
        address peggedToken,
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        string[] calldata uris
    ) external onlyFluentBridge nonReentrant {
        require(ids.length == amounts.length && ids.length == uris.length, ArrayLengthMismatch());
        require(ids.length > 0, ZeroValueNotAllowed("ids"));
        _receivePegged(originToken, peggedToken, from, to, ids, amounts, uris, true);
    }

    function _receivePegged(
        address originToken,
        address peggedToken,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        string[] memory uris,
        bool batch
    ) internal {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(originToken != address(0), ZeroAddressNotAllowed("originToken"));
        require(to != address(0), InvalidRecipient());

        if (peggedToken.code.length == 0) {
            address newPeggedToken = _deployPeggedToken(originToken);
            require(newPeggedToken == peggedToken, WrongPeggedToken());
            _getERC1155GatewayStorage()._tokenMapping[peggedToken] = originToken;
        } else {
            require(getTokenMapping(peggedToken) == originToken, TokenMappingCheckFailed());
        }

        if (batch) {
            ERC1155PeggedToken(peggedToken).mintBatch(to, ids, amounts, uris);
            emit ReceivedTokens(from, to, ids.length);
        } else {
            ERC1155PeggedToken(peggedToken).mint(to, ids[0], amounts[0], uris[0]);
            emit ReceivedTokens(from, to, amounts[0]);
        }
    }

    /// @inheritdoc IERC1155Gateway
    function receiveOriginTokens(address originToken, address from, address to, uint256 id, uint256 amount)
        external
        onlyFluentBridge
        nonReentrant
    {
        require(amount > 0, ZeroValueNotAllowed("amount"));
        _receiveOrigin(originToken, from, to, _single(id), _single(amount), false);
    }

    /// @inheritdoc IERC1155Gateway
    function receiveOriginBatchTokens(
        address originToken,
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external onlyFluentBridge nonReentrant {
        require(ids.length == amounts.length, ArrayLengthMismatch());
        require(ids.length > 0, ZeroValueNotAllowed("ids"));
        _receiveOrigin(originToken, from, to, ids, amounts, true);
    }

    function _receiveOrigin(
        address originToken,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bool batch
    ) internal {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(originToken != address(0), OriginTokenZero());
        require(to != address(0), InvalidRecipient());
        if (batch) {
            IERC1155(originToken).safeBatchTransferFrom(address(this), to, ids, amounts, "");
            emit ReceivedTokens(from, to, ids.length);
        } else {
            IERC1155(originToken).safeTransferFrom(address(this), to, ids[0], amounts[0], "");
            emit ReceivedTokens(from, to, amounts[0]);
        }
    }

    function _deployPeggedToken(address originToken) internal returns (address) {
        address peggedToken = IGenericTokenFactory(getTokenFactory()).deployToken(address(this), originToken, "");
        ERC1155PeggedToken(peggedToken).initialize(originToken);
        return peggedToken;
    }

    /// @inheritdoc IERC1155Gateway
    function getTokenFactory() public view returns (address) {
        return _getERC1155GatewayStorage()._tokenFactory;
    }

    function getOtherSideTokenImplementation() public view returns (address) {
        return _getERC1155GatewayStorage()._otherSideTokenImplementation;
    }

    function getOtherSideFactory() public view returns (address) {
        return _getERC1155GatewayStorage()._otherSideFactory;
    }

    function getOtherSideBeacon() public view returns (address) {
        return _getERC1155GatewayStorage()._otherSideBeacon;
    }

    /// @inheritdoc IERC1155Gateway
    function getTokenMapping(address key) public view returns (address) {
        return _getERC1155GatewayStorage()._tokenMapping[key];
    }

    /// @inheritdoc IERC1155Gateway
    function computeOtherSidePeggedTokenAddress(address, address originToken) external view returns (address) {
        address cached = _getERC1155GatewayStorage()._otherSidePeggedForOrigin[originToken];
        if (cached != address(0)) return cached;
        return _computeOtherSidePeggedTokenAddressWithGateway(getOtherSideGateway(), originToken);
    }

    /// @inheritdoc IERC1155Gateway
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
        ERC1155GatewayStorage storage $ = _getERC1155GatewayStorage();
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
        ERC1155GatewayStorage storage $ = _getERC1155GatewayStorage();
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

    function _readURI(address token, uint256 id) internal view returns (string memory) {
        try IERC1155MetadataURI(token).uri(id) returns (string memory uri_) {
            return uri_;
        } catch {
            return "";
        }
    }

    function _single(uint256 value) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }
}
