// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20PeggedToken} from "./tokens/ERC20PeggedToken.sol";
import {ERC20TokenFactory} from "./factories/ERC20TokenFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {FluentBridge} from "./FluentBridge.sol";

/**
 * @title ERC20Gateway
 * @author Fluent Labs
 * @notice Gateway contract for ERC20 tokens.
 * @dev Upgradeable via transparent proxy; state in ERC20GatewayStorage (ERC-7201).
 */
contract ERC20Gateway is Initializable, Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:fluent.storage.ERC20GatewayStorage
    struct ERC20GatewayStorage {
        address bridgeContract;
        address tokenFactory;
        address otherSide;
        address otherSideTokenImplementation;
        address otherSideFactory;
        mapping(address => address) tokenMapping;
        uint256[50] __gap;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.ERC20GatewayStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC20_GATEWAY_STORAGE_LOCATION =
        0xe252cab26214ab2f0e4d4e6f063d78ba24b618cf5f8fd25d1b9aef671b7f9100;

    function _getERC20GatewayStorage() private pure returns (ERC20GatewayStorage storage $) {
        assembly {
            $.slot := ERC20_GATEWAY_STORAGE_LOCATION
        }
    }

    // ---------- Public getters ----------
    function bridgeContract() public view returns (address) { return _getERC20GatewayStorage().bridgeContract; }
    function tokenFactory() public view returns (address) { return _getERC20GatewayStorage().tokenFactory; }
    function otherSide() public view returns (address) { return _getERC20GatewayStorage().otherSide; }
    function otherSideTokenImplementation() public view returns (address) { return _getERC20GatewayStorage().otherSideTokenImplementation; }
    function otherSideFactory() public view returns (address) { return _getERC20GatewayStorage().otherSideFactory; }
    function tokenMapping(address key) public view returns (address) { return _getERC20GatewayStorage().tokenMapping[key]; }

    error OnlyBridgeSender();
    error MessageFromWrongGateway();
    error MessageValueMustBeZero();
    error OriginTokenZero();
    error WrongPeggedToken();
    error TokenMappingCheckFailed();
    error TokenAddressZero();

    modifier onlyBridgeSender() {
        require(msg.sender == _getERC20GatewayStorage().bridgeContract, OnlyBridgeSender());
        _;
    }

    event ReceivedTokens(address source, address target, uint256 amount);
    event UpdateTokenMapping(address indexed _peggedToken, address indexed _oldOriginToken, address indexed _newOriginToken);
    event OtherSideUpdated(
        address indexed _oldOtherSide,
        address indexed _newOtherSide,
        address indexed _oldImplementation,
        address _newImplementation,
        address _oldFactory,
        address _newFactory
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    /// @notice Initializes the upgradeable gateway (replaces constructor when used behind a proxy).
    function initialize(address _initialOwner, address _bridgeContract, address _tokenFactory) public payable initializer {
        __Ownable_init(_initialOwner);
        __Ownable2Step_init();
        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        $.bridgeContract = _bridgeContract;
        $.tokenFactory = _tokenFactory;
    }

    function setOtherSide(address _otherSide, address _otherSideTokenImplementation, address _otherSideFactory) external payable onlyOwner {
        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        address oldOtherSide = $.otherSide;
        address oldImplementation = $.otherSideTokenImplementation;
        address oldFactory = $.otherSideFactory;

        $.otherSide = _otherSide;
        $.otherSideTokenImplementation = _otherSideTokenImplementation;
        $.otherSideFactory = _otherSideFactory;

        emit OtherSideUpdated(oldOtherSide, _otherSide, oldImplementation, _otherSideTokenImplementation, oldFactory, _otherSideFactory);
    }

    function computePeggedTokenAddress(address _token) external view returns (address) {
        return ERC20TokenFactory(_getERC20GatewayStorage().tokenFactory).computePeggedTokenAddress(address(this), _token);
    }

    function computeOtherSidePeggedTokenAddress(address _token) external view returns (address) {
        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        return
            ERC20TokenFactory($.tokenFactory).computeOtherSidePeggedTokenAddress(
                $.otherSide,
                _token,
                $.otherSideTokenImplementation,
                $.otherSideFactory
            );
    }

    function sendTokens(address _token, address _to, uint256 _amount) external payable {
        sendTokensFrom(_token, msg.sender, msg.sender, _to, _amount, msg.value);
    }

    function sendTokensFrom(address _token, address _sender, address _from, address _to, uint256 _amount, uint256 _value) internal {
        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        bytes memory _message;

        if ($.tokenMapping[_token] == address(0)) {
            if (_from != address(this)) {
                IERC20(_token).safeTransferFrom(_from, address(this), _amount);
            }

            bytes memory rawTokenMetadata = abi.encode(ERC20(_token).symbol(), ERC20(_token).name(), ERC20(_token).decimals());

            address peggedToken = ERC20TokenFactory($.tokenFactory).computeOtherSidePeggedTokenAddress(
                $.otherSide,
                _token,
                $.otherSideTokenImplementation,
                $.otherSideFactory
            );
            _message = abi.encodeCall(ERC20Gateway.receivePeggedTokens, (_token, peggedToken, _sender, _to, _amount, rawTokenMetadata));
        } else {
            (, address originAddress) = ERC20PeggedToken(_token).getOrigin();
            require($.tokenMapping[_token] == originAddress);

            ERC20PeggedToken(_token).burn(_from, _amount);

            _message = abi.encodeCall(ERC20Gateway.receiveNativeTokens, (originAddress, _sender, _to, _amount));
        }

        FluentBridge($.bridgeContract).sendMessage{value: _value}($.otherSide, _message);
    }

    function receivePeggedTokens(
        address _originToken,
        address _peggedToken,
        address _from,
        address _to,
        uint256 _amount,
        bytes calldata _tokenMetadata
    ) external payable onlyBridgeSender {
        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        require(FluentBridge(msg.sender).nativeSender() == $.otherSide, MessageFromWrongGateway());
        require(msg.value == 0, MessageValueMustBeZero());
        require(_originToken != address(0), OriginTokenZero());

        if (_peggedToken.code.length == 0) {
            address new_pegged_token = _deployL2Token(_tokenMetadata, _originToken);
            require(new_pegged_token == _peggedToken, WrongPeggedToken());
            $.tokenMapping[_peggedToken] = _originToken;
        } else {
            require($.tokenMapping[_peggedToken] == _originToken, TokenMappingCheckFailed());
        }

        ERC20PeggedToken(_peggedToken).mint(_to, _amount);
        emit ReceivedTokens(_from, _to, _amount);
    }

    function receiveNativeTokens(address _nativeToken, address _from, address _to, uint256 _amount) external payable onlyBridgeSender {
        require(FluentBridge(msg.sender).nativeSender() == _getERC20GatewayStorage().otherSide, MessageFromWrongGateway());
        _receiveNativeTokens(_nativeToken, _from, _to, _amount);
    }

    function _receiveNativeTokens(address _nativeToken, address _from, address _to, uint256 _amount) internal {
        require(msg.value == 0, MessageValueMustBeZero());
        IERC20(_nativeToken).safeTransfer(_to, _amount);
        emit ReceivedTokens(_from, _to, _amount);
    }

    function updateTokenMapping(address _originToken, address _peggedToken) external onlyOwner {
        require(_originToken != address(0), TokenAddressZero());
        require(_peggedToken != address(0), TokenAddressZero());
        ERC20GatewayStorage storage $ = _getERC20GatewayStorage();
        address _oldOriginToken = $.tokenMapping[_peggedToken];
        $.tokenMapping[_peggedToken] = _originToken;
        emit UpdateTokenMapping(_peggedToken, _oldOriginToken, _originToken);
    }

    function acceptTokenFactory() external onlyOwner {
        ERC20TokenFactory(_getERC20GatewayStorage().tokenFactory).acceptOwnership();
    }

    function _deployL2Token(bytes memory _tokenMetadata, address _originToken) internal returns (address) {
        address _peggedToken = ERC20TokenFactory(_getERC20GatewayStorage().tokenFactory).deployToken(address(this), _originToken);

        (string memory _symbol, string memory _name, uint8 _decimals) = abi.decode(_tokenMetadata, (string, string, uint8));

        ERC20PeggedToken(_peggedToken).initialize(_name, _symbol, _decimals, address(this), _originToken);

        return _peggedToken;
    }
}
