// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20PeggedToken} from "../tokens/ERC20PeggedToken.sol";
import {ERC20TokenFactory} from "../factories/ERC20TokenFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {FluentBridge} from "../FluentBridge.sol";
import {IGateway} from "../interfaces/IGateway.sol";

/**
 * @title PaymentsGateway
 * @author Fluent Labs
 * @notice Gateway contract for Native and ERC20 tokens.
 * @dev Upgradeable via transparent proxy; state in PaymentsGatewayStorage (ERC-7201).
 *      Uses ReentrancyGuardUpgradeable to protect token-bridging entrypoints.
 */
contract PaymentsGateway is Initializable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable, IGateway {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:fluent.storage.PaymentsGatewayStorage
    struct PaymentsGatewayStorage {
        address bridgeContract;
        address tokenFactory;
        address otherSide;
        address otherSideTokenImplementation;
        address otherSideFactory;
        mapping(address => address) tokenMapping;
        uint256[50] __gap;
    }

    /// @dev Storage slot is intentionally preserved from the legacy ERC20 gateway
    ///      for upgrade-safe layout compatibility.

    bytes32 private constant PAYMENTS_GATEWAY_STORAGE_LOCATION = 0xe252cab26214ab2f0e4d4e6f063d78ba24b618cf5f8fd25d1b9aef671b7f9100;
    /// @dev returns the storage pointer for the PaymentsGatewayStorage struct.
    function _getERC20GatewayStorage() private pure returns (PaymentsGatewayStorage storage $) {
        assembly {
            $.slot := PAYMENTS_GATEWAY_STORAGE_LOCATION
        }
    }

    modifier onlyBridgeSender() {
        require(msg.sender == _getERC20GatewayStorage().bridgeContract, OnlyBridgeSender());
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the upgradeable gateway (replaces constructor when used behind a proxy).
    function initialize(address _initialOwner, address _bridgeContract, address _tokenFactory) public initializer {
        require(_initialOwner != address(0) && _bridgeContract != address(0) && _tokenFactory != address(0), ZeroAddress());

        __Ownable_init(_initialOwner);
        __Ownable2Step_init();
        __ReentrancyGuard_init();

        PaymentsGatewayStorage storage $ = _getERC20GatewayStorage();
        $.bridgeContract = _bridgeContract;
        $.tokenFactory = _tokenFactory;
    }

    /// @inheritdoc IGateway
    function sendNativeTokens(address _to, uint256 _amount) external payable nonReentrant {
        PaymentsGatewayStorage storage $ = _getERC20GatewayStorage();
        require(_to != address(0), InvalidRecipient());
        require($.otherSide != address(0), ZeroAddress());
        require(msg.value == _amount, InvalidNativeAmount());

        FluentBridge($.bridgeContract).sendMessage{value: _amount}(
            $.otherSide,
            abi.encodeCall(PaymentsGateway.receiveNativeTokens, (msg.sender, _to, _amount))
        );
    }

    /// @inheritdoc IGateway
    function sendTokens(address _token, address _to, uint256 _amount) external nonReentrant {
        require(_getERC20GatewayStorage().otherSide != address(0), ZeroAddress());
        require(_to != address(0), InvalidRecipient());
        _sendTokensFrom(_token, msg.sender, msg.sender, _to, _amount);
    }

    function _sendTokensFrom(address _token, address _sender, address _from, address _to, uint256 _amount) internal {
        PaymentsGatewayStorage storage $ = _getERC20GatewayStorage();
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
            _message = abi.encodeCall(PaymentsGateway.receivePeggedTokens, (_token, peggedToken, _sender, _to, _amount, rawTokenMetadata));
        } else {
            (, address originAddress) = ERC20PeggedToken(_token).getOrigin();
            require($.tokenMapping[_token] == originAddress);

            ERC20PeggedToken(_token).burn(_from, _amount);

            _message = abi.encodeCall(PaymentsGateway.receiveOriginTokens, (originAddress, _sender, _to, _amount));
        }

        FluentBridge($.bridgeContract).sendMessage($.otherSide, _message);
    }

    /// @inheritdoc IGateway
    function receivePeggedTokens(
        address _originToken,
        address _peggedToken,
        address _from,
        address _to,
        uint256 _amount,
        bytes calldata _tokenMetadata
    ) external payable onlyBridgeSender nonReentrant {
        PaymentsGatewayStorage storage $ = _getERC20GatewayStorage();
        require(FluentBridge(msg.sender).nativeSender() == $.otherSide, MessageFromWrongGateway());
        require(msg.value == 0, MessageValueMustBeZero());
        require(_originToken != address(0), OriginTokenZero());
        require(_to != address(0), InvalidRecipient());

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

    /// @inheritdoc IGateway
    function receiveOriginTokens(
        address _originToken,
        address _from,
        address _to,
        uint256 _amount
    ) external payable onlyBridgeSender nonReentrant {
        require(FluentBridge(msg.sender).nativeSender() == _getERC20GatewayStorage().otherSide, MessageFromWrongGateway());
        require(msg.value == 0, MessageValueMustBeZero());
        require(_to != address(0), InvalidRecipient());

        IERC20(_originToken).safeTransfer(_to, _amount);

        emit ReceivedTokens(_from, _to, _amount);
    }

    /// @inheritdoc IGateway
    function receiveNativeTokens(address _from, address _to, uint256 _amount) external payable onlyBridgeSender nonReentrant {
        require(FluentBridge(msg.sender).nativeSender() == _getERC20GatewayStorage().otherSide, MessageFromWrongGateway());
        require(msg.value == _amount, InvalidNativeAmount());
        require(_to != address(0), InvalidRecipient());

        (bool success, ) = payable(_to).call{value: _amount}("");
        require(success, NativeTransferFailed());

        emit ReceivedTokens(_from, _to, _amount);
    }

    /**
     * @notice Deploys a new pegged token.
     * @param _tokenMetadata The metadata of the token (symbol, name, decimals)
     * @param _originToken The origin token address.
     * @return The address of the pegged token.
     */
    function _deployL2Token(bytes memory _tokenMetadata, address _originToken) internal returns (address) {
        bytes memory keyData = abi.encode(address(this), _originToken);
        address _peggedToken = ERC20TokenFactory(_getERC20GatewayStorage().tokenFactory).deployToken(keyData, "");

        (string memory _symbol, string memory _name, uint8 _decimals) = abi.decode(_tokenMetadata, (string, string, uint8));
        ERC20PeggedToken(_peggedToken).initialize(_name, _symbol, _decimals, address(this), _originToken);

        return _peggedToken;
    }

    // ---------- Public getters ----------

    function bridgeContract() public view returns (address) {
        return _getERC20GatewayStorage().bridgeContract;
    }

    function tokenFactory() public view returns (address) {
        return _getERC20GatewayStorage().tokenFactory;
    }

    function otherSide() public view returns (address) {
        return _getERC20GatewayStorage().otherSide;
    }

    function otherSideTokenImplementation() public view returns (address) {
        return _getERC20GatewayStorage().otherSideTokenImplementation;
    }

    function otherSideFactory() public view returns (address) {
        return _getERC20GatewayStorage().otherSideFactory;
    }

    function tokenMapping(address key) public view returns (address) {
        return _getERC20GatewayStorage().tokenMapping[key];
    }

    /// @inheritdoc IGateway
    function computePeggedTokenAddress(address _token) external view returns (address) {
        return ERC20TokenFactory(_getERC20GatewayStorage().tokenFactory).computePeggedTokenAddress(address(this), _token);
    }

    /// @inheritdoc IGateway
    function computeOtherSidePeggedTokenAddress(address _token) external view returns (address) {
        PaymentsGatewayStorage storage $ = _getERC20GatewayStorage();
        return
            ERC20TokenFactory($.tokenFactory).computeOtherSidePeggedTokenAddress(
                $.otherSide,
                _token,
                $.otherSideTokenImplementation,
                $.otherSideFactory
            );
    }

    /*******
     * Admin functions
     *****************/

    /// @notice Accepts ownership of the token factory for this gateway.
    function acceptTokenFactory() external onlyOwner {
        ERC20TokenFactory(_getERC20GatewayStorage().tokenFactory).acceptOwnership();
    }

    /// @notice Updates the local token factory used for pegged token deployment and address computation.
    function setTokenFactory(address _tokenFactory) external onlyOwner {
        require(_tokenFactory != address(0), ZeroAddress());
        PaymentsGatewayStorage storage $ = _getERC20GatewayStorage();
        address oldTokenFactory = $.tokenFactory;
        $.tokenFactory = _tokenFactory;
        emit TokenFactoryUpdated(oldTokenFactory, _tokenFactory);
    }

    /// @notice Updates the remote gateway address used as message destination.
    function setOtherSideGateway(address _otherSide) external onlyOwner {
        require(_otherSide != address(0), ZeroAddress());
        PaymentsGatewayStorage storage $ = _getERC20GatewayStorage();
        address oldOtherSide = $.otherSide;
        $.otherSide = _otherSide;
        emit OtherSideGatewayUpdated(oldOtherSide, _otherSide);
    }

    /// @notice Updates remote token implementation used in deterministic pegged token address computation.
    function setOtherSideTokenImplementation(address _otherSideTokenImplementation) external onlyOwner {
        require(_otherSideTokenImplementation != address(0), ZeroAddress());
        PaymentsGatewayStorage storage $ = _getERC20GatewayStorage();
        address oldImplementation = $.otherSideTokenImplementation;
        $.otherSideTokenImplementation = _otherSideTokenImplementation;
        emit OtherSideTokenImplementationUpdated(oldImplementation, _otherSideTokenImplementation);
    }

    /// @notice Sets remote gateway/factory configuration used for cross-chain token routing.
    /// @dev High-trust admin action; should be controlled by multisig governance.
    function setOtherSide(address _otherSide, address _otherSideTokenImplementation, address _otherSideFactory) external onlyOwner {
        require(_otherSide != address(0) && _otherSideTokenImplementation != address(0) && _otherSideFactory != address(0), ZeroAddress());
        PaymentsGatewayStorage storage $ = _getERC20GatewayStorage();
        address oldOtherSide = $.otherSide;
        address oldImplementation = $.otherSideTokenImplementation;
        address oldFactory = $.otherSideFactory;

        $.otherSide = _otherSide;
        $.otherSideTokenImplementation = _otherSideTokenImplementation;
        $.otherSideFactory = _otherSideFactory;

        emit OtherSideUpdated(oldOtherSide, _otherSide, oldImplementation, _otherSideTokenImplementation, oldFactory, _otherSideFactory);
    }

    /// @notice Updates local peggedToken => originToken mapping used for burn/unlock flows.
    /// @dev High-trust admin action; incorrect mapping can misroute user withdrawals.
    function updateTokenMapping(address _originToken, address _peggedToken) external onlyOwner {
        require(_originToken != address(0), TokenAddressZero());
        require(_peggedToken != address(0), TokenAddressZero());

        PaymentsGatewayStorage storage $ = _getERC20GatewayStorage();
        address _oldOriginToken = $.tokenMapping[_peggedToken];
        $.tokenMapping[_peggedToken] = _originToken;

        emit UpdateTokenMapping(_peggedToken, _oldOriginToken, _originToken);
    }

    /// @notice Recovers ETH accidentally sent or force-sent to this contract.
    /// @dev Owner-only emergency path; use operational controls to avoid draining owed funds.
    function rescueNative(address payable _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), InvalidRecipient());
        (bool success, ) = _to.call{value: _amount}("");
        require(success, NativeTransferFailed());
    }

    /// @notice Receives ETH (e.g. forced transfers). Prefer bridge entrypoints for normal flow.
    receive() external payable {}
}
