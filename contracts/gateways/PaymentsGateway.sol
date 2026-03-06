// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20PeggedToken} from "../tokens/ERC20PeggedToken.sol";
import {ERC20TokenFactory} from "../factories/ERC20TokenFactory.sol";
import {GenericTokenFactory} from "../factories/GenericTokenFactory.sol";
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

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public constant DEFAULT_GAS_LIMIT = 50_000;

    /// @custom:storage-location erc7201:fluent.storage.PaymentsGatewayStorage
    struct PaymentsGatewayStorage {
        uint256 gasLimit;
        address bridgeContract;
        address tokenFactory;
        address otherSide;
        address otherSideTokenImplementation;
        address otherSideFactory;
        address otherSideBeacon;
        mapping(address => address) tokenMapping;
        uint256[49] __gap;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.PaymentsGatewayStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PAYMENTS_GATEWAY_STORAGE_LOCATION = 0x56fcd3a376ece74d8548f8eb9ad3e4b76412a278066173b6106c2bf8de8e3d00;
    /// @dev returns the storage pointer for the PaymentsGatewayStorage struct.
    function _getPaymentsGatewayStorage() private pure returns (PaymentsGatewayStorage storage $) {
        assembly {
            $.slot := PAYMENTS_GATEWAY_STORAGE_LOCATION
        }
    }

    modifier onlyBridgeSender() {
        require(msg.sender == _getPaymentsGatewayStorage().bridgeContract, OnlyBridgeSender());
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

        // ============ Storage ============
        _setGasLimit(DEFAULT_GAS_LIMIT);
        _setBridgeContract(_bridgeContract);
        _setTokenFactory(_tokenFactory);
    }

    /// @inheritdoc IGateway
    function sendNativeTokens(address _to, uint256 _amount) external payable nonReentrant {
        PaymentsGatewayStorage storage $ = _getPaymentsGatewayStorage();
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
        require(_getPaymentsGatewayStorage().otherSide != address(0), ZeroAddress());
        require(_to != address(0), InvalidRecipient());
        _sendTokensFrom(_token, msg.sender, msg.sender, _to, _amount);
    }

    function _sendTokensFrom(address _token, address _sender, address _from, address _to, uint256 _amount) internal {
        PaymentsGatewayStorage storage $ = _getPaymentsGatewayStorage();
        bytes memory _message;

        if ($.tokenMapping[_token] == address(0)) {
            if (_from != address(this)) {
                IERC20(_token).safeTransferFrom(_from, address(this), _amount);
            }

            bytes memory rawTokenMetadata = abi.encode(ERC20(_token).symbol(), ERC20(_token).name(), ERC20(_token).decimals());
            address peggedToken = ERC20TokenFactory($.tokenFactory).computeOtherSidePeggedTokenAddress(
                $.otherSide,
                _token,
                $.otherSideBeacon,
                $.otherSideFactory
            );
            _message = abi.encodeCall(PaymentsGateway.receivePeggedTokens, (_token, peggedToken, _sender, _to, _amount, rawTokenMetadata));
        } else {
            (, address originAddress) = ERC20PeggedToken(_token).getOrigin();
            require($.tokenMapping[_token] == originAddress, TokenMappingCheckFailed());

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
        PaymentsGatewayStorage storage $ = _getPaymentsGatewayStorage();
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
        require(FluentBridge(msg.sender).nativeSender() == _getPaymentsGatewayStorage().otherSide, MessageFromWrongGateway());
        require(msg.value == 0, MessageValueMustBeZero());
        require(_to != address(0), InvalidRecipient());

        IERC20(_originToken).safeTransfer(_to, _amount);

        emit ReceivedTokens(_from, _to, _amount);
    }

    /// @inheritdoc IGateway
    function receiveNativeTokens(address _from, address _to, uint256 _amount) external payable onlyBridgeSender nonReentrant {
        require(FluentBridge(msg.sender).nativeSender() == _getPaymentsGatewayStorage().otherSide, MessageFromWrongGateway());
        require(msg.value == _amount, InvalidNativeAmount());
        require(_to != address(0), InvalidRecipient());

        (bool success, ) = payable(_to).call{gas: gasLimit(), value: _amount}("");
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
        address _peggedToken = GenericTokenFactory(_getPaymentsGatewayStorage().tokenFactory).deployToken(keyData, "");

        (string memory _symbol, string memory _name, uint8 _decimals) = abi.decode(_tokenMetadata, (string, string, uint8));
        ERC20PeggedToken(_peggedToken).initialize(_name, _symbol, _decimals, address(this), _originToken);

        return _peggedToken;
    }

    // ============ Public getters ============

    function bridgeContract() public view returns (address) {
        return _getPaymentsGatewayStorage().bridgeContract;
    }

    function tokenFactory() public view returns (address) {
        return _getPaymentsGatewayStorage().tokenFactory;
    }

    function otherSide() public view returns (address) {
        return _getPaymentsGatewayStorage().otherSide;
    }

    function otherSideTokenImplementation() public view returns (address) {
        return _getPaymentsGatewayStorage().otherSideTokenImplementation;
    }

    function otherSideFactory() public view returns (address) {
        return _getPaymentsGatewayStorage().otherSideFactory;
    }

    function tokenMapping(address key) public view returns (address) {
        return _getPaymentsGatewayStorage().tokenMapping[key];
    }

    /// @inheritdoc IGateway
    function computePeggedTokenAddress(address _token) external view returns (address) {
        bytes memory keyData = abi.encode(address(this), _token);
        return GenericTokenFactory(_getPaymentsGatewayStorage().tokenFactory).computeTokenAddress(keyData, "");
    }

    /// @inheritdoc IGateway
    function computeOtherSidePeggedTokenAddress(address _token) external view returns (address) {
        PaymentsGatewayStorage storage $ = _getPaymentsGatewayStorage();
        return ERC20TokenFactory($.tokenFactory).computeOtherSidePeggedTokenAddress($.otherSide, _token, $.otherSideBeacon, $.otherSideFactory);
    }

    function gasLimit() public view returns (uint256) {
        return _getPaymentsGatewayStorage().gasLimit;
    }

    // ============ Admin functions ============

    /**
     * @notice Accepts ownership of the token factory for this gateway.
     */
    function acceptTokenFactory() external onlyOwner {
        GenericTokenFactory(_getPaymentsGatewayStorage().tokenFactory).acceptOwnership();
    }

    /**
     * @notice Updates the bridge contract address used for sending and receiving messages.
     * @param _bridgeContract The address of the bridge contract.
     */
    function setBridgeContract(address _bridgeContract) external onlyOwner {
        _setBridgeContract(_bridgeContract);
    }

    function _setBridgeContract(address _bridgeContract) internal {
        require(_bridgeContract != address(0), ZeroAddress());
        PaymentsGatewayStorage storage $ = _getPaymentsGatewayStorage();
        emit BridgeContractUpdated($.bridgeContract, _bridgeContract);
        $.bridgeContract = _bridgeContract;
    }

    /**
     * @notice Updates the local token factory used for pegged token deployment and address computation.
     * @param _tokenFactory The address of the token factory.
     */
    function setTokenFactory(address _tokenFactory) external onlyOwner {
        _setTokenFactory(_tokenFactory);
    }

    function _setTokenFactory(address _tokenFactory) internal {
        require(_tokenFactory != address(0), ZeroAddress());
        PaymentsGatewayStorage storage $ = _getPaymentsGatewayStorage();
        emit TokenFactoryUpdated($.tokenFactory, _tokenFactory);
        $.tokenFactory = _tokenFactory;
    }

    /**
     * @notice Updates the remote gateway address used as message destination.
     * @param _otherSide The address of the other side gateway.
     */
    function setOtherSideGateway(address _otherSide) external onlyOwner {
        _setOtherSideGateway(_otherSide);
    }

    function _setOtherSideGateway(address _otherSide) internal {
        require(_otherSide != address(0), ZeroAddress());
        PaymentsGatewayStorage storage $ = _getPaymentsGatewayStorage();
        emit OtherSideGatewayUpdated($.otherSide, _otherSide);
        $.otherSide = _otherSide;
    }

    /**
     * @notice Updates remote token implementation used in deterministic pegged token address computation.
     * @param _otherSideTokenImplementation The address of the other side token implementation.
     */
    function setOtherSideTokenImplementation(address _otherSideTokenImplementation) external onlyOwner {
        _setOtherSideTokenImplementation(_otherSideTokenImplementation);
    }

    function _setOtherSideTokenImplementation(address _otherSideTokenImplementation) internal {
        require(_otherSideTokenImplementation != address(0), ZeroAddress());
        PaymentsGatewayStorage storage $ = _getPaymentsGatewayStorage();
        emit OtherSideTokenImplementationUpdated($.otherSideTokenImplementation, _otherSideTokenImplementation);
        $.otherSideTokenImplementation = _otherSideTokenImplementation;
    }

    /**
     * @notice Sets remote gateway/factory configuration used for cross-chain token routing.
     * @param _otherSide The address of the other side gateway.
     * @dev High-trust admin action; should be controlled by multisig governance.
     * @param _otherSideTokenImplementation The address of the other side token implementation.
     * @param _otherSideFactory The address of the other side factory.
     * @param _otherSideBeacon The address of the other side beacon.
     */
    function setOtherSide(
        address _otherSide,
        address _otherSideTokenImplementation,
        address _otherSideFactory,
        address _otherSideBeacon
    ) external onlyOwner {
        _setOtherSide(_otherSide, _otherSideTokenImplementation, _otherSideFactory, _otherSideBeacon);
    }

    function _setOtherSide(
        address _otherSide,
        address _otherSideTokenImplementation,
        address _otherSideFactory,
        address _otherSideBeacon
    ) internal {
        require(
            _otherSide != address(0) &&
                _otherSideTokenImplementation != address(0) &&
                _otherSideFactory != address(0) &&
                _otherSideBeacon != address(0),
            ZeroAddress()
        );
        PaymentsGatewayStorage storage $ = _getPaymentsGatewayStorage();

        emit OtherSideUpdated(
            $.otherSide,
            _otherSide,
            $.otherSideTokenImplementation,
            _otherSideTokenImplementation,
            $.otherSideFactory,
            _otherSideFactory
        );

        $.otherSide = _otherSide;
        $.otherSideTokenImplementation = _otherSideTokenImplementation;
        $.otherSideFactory = _otherSideFactory;
        $.otherSideBeacon = _otherSideBeacon;
    }

    /**
     * @notice Updates local peggedToken => originToken mapping used for burn/unlock flows.
     * @dev High-trust admin action; incorrect mapping can misroute user withdrawals.
     * @param _originToken The address of the origin token.
     * @param _peggedToken The address of the pegged token.
     */
    function updateTokenMapping(address _originToken, address _peggedToken) external onlyOwner {
        _updateTokenMapping(_originToken, _peggedToken);
    }

    function _updateTokenMapping(address _originToken, address _peggedToken) internal {
        require(_originToken != address(0), TokenAddressZero());
        require(_peggedToken != address(0), TokenAddressZero());
        PaymentsGatewayStorage storage $ = _getPaymentsGatewayStorage();
        address _oldOriginToken = $.tokenMapping[_peggedToken];
        $.tokenMapping[_peggedToken] = _originToken;
        emit UpdateTokenMapping(_peggedToken, _oldOriginToken, _originToken);
    }

    /**
     * @notice Recovers ETH accidentally sent or force-sent to this contract.
     * @param _to The address to send the ETH to.
     * @param _amount The amount of ETH to send.
     */
    function rescueNative(address payable _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), InvalidRecipient());
        (bool success, ) = _to.call{value: _amount}("");
        require(success, NativeTransferFailed());
    }

    /**
     * @notice Sets the gas limit for the bridge.
     * @param _gasLimit The new gas limit.
     */
    function setGasLimit(uint256 _gasLimit) external onlyOwner {
        require(_gasLimit > 0, InvalidGasLimit());
        _setGasLimit(_gasLimit);
    }

    function _setGasLimit(uint256 _gasLimit) internal {
        PaymentsGatewayStorage storage $ = _getPaymentsGatewayStorage();
        emit GasLimitUpdated($.gasLimit, _gasLimit);
        $.gasLimit = _gasLimit;
    }

    /// @notice Receives ETH (e.g. forced transfers). Prefer bridge entrypoints for normal flow.
    receive() external payable {}
}
