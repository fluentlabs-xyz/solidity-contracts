// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {FluentBridge} from "../FluentBridge.sol";
import {ERC20PeggedToken} from "../tokens/ERC20PeggedToken.sol";
import {UniversalTokenSDK} from "../libraries/UniversalTokenSDK.sol";

import {IGateway} from "../interfaces/IGateway.sol";
import {IGenericTokenFactory} from "../interfaces/IGenericTokenFactory.sol";

/**
 * @title PaymentGateway
 * @author Fluent Labs
 * @notice Gateway for bridging native (ETH) and ERC20 tokens between two chains via FluentBridge.
 * @dev Upgradeable via transparent proxy; state in PaymentGatewayStorage (ERC-7201). Only the configured bridge
 *      may call receive* entrypoints; native receive requires msg.value == amount (bridge forwards value from its receive caller).
 *      Token mapping (peggedToken => originToken) is set on first receive of a pegged token and can be updated by owner.
 * @notice Workflows:
 * 1. Send native tokens (this chain -> other chain):
 *    - User calls sendNativeTokens(to, amount) with msg.value == amount.
 *    - Gateway forwards value to FluentBridge.sendMessage{value: amount}(otherSide, receiveNativeTokens(sender, to, amount)).
 *    - Native is locked in the bridge on this chain; relayer must supply same amount when executing receive on the other chain.
 * 2. Send ERC20 — origin token (this chain -> other chain, first time):
 *    - User calls sendTokens(originToken, to, amount); gateway pulls tokens and encodes receivePeggedTokens(origin, pegged, from, to, amount, metadata).
 *    - Other side gateway deploys pegged token (via factory) and mints to recipient.
 * 3. Send ERC20 — pegged token (this chain -> other chain, return flow):
 *    - User calls sendTokens(peggedToken, to, amount); gateway burns pegged and encodes receiveOriginTokens(origin, from, to, amount).
 *    - Other side gateway transfers origin token from this gateway’s reserve to recipient.
 * 4. Receive native tokens (other chain -> this chain):
 *    - Only callable by bridge; bridge must call with msg.value == amount. Gateway forwards amount to recipient via call with gasLimit().
 * 5. Receive pegged tokens (other chain -> this chain):
 *    - Bridge calls receivePeggedTokens(origin, pegged, from, to, amount, metadata); gateway deploys token if needed, sets mapping, mints to recipient.
 * 6. Receive origin tokens (other chain -> this chain):
 *    - Bridge calls receiveOriginTokens(origin, from, to, amount); gateway safeTransfers origin token to recipient.
 * Admin: setOtherSide, setTokenFactory, setGasLimit, updateTokenMapping, rescueNative (recover stuck ETH).
 */
contract PaymentGateway is Initializable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable, IGateway {
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public constant DEFAULT_GAS_LIMIT = 50_000;

    /// @custom:storage-location erc7201:fluent.storage.PaymentGateway
    struct PaymentGatewayStorage {
        uint256 gasLimit;
        address bridgeContract;
        address tokenFactory;
        address otherSide;
        address otherSideTokenImplementation;
        address otherSideFactory;
        address otherSideBeacon;
        uint256 otherSideChainId;
        mapping(address => address) tokenMapping;
        uint256[50] __gap;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.PaymentGatewayStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PAYMENT_GATEWAY_STORAGE_LOCATION = 0xcaa08bf2435fec1ef38988227447dbd9b56d025c40329ce35d36c83ed0b9cf00;
    /// @dev returns the storage pointer for the PaymentGatewayStorage struct.
    function _getPaymentGatewayStorage() private pure returns (PaymentGatewayStorage storage $) {
        assembly {
            $.slot := PAYMENT_GATEWAY_STORAGE_LOCATION
        }
    }

    modifier onlyBridgeSender() {
        require(msg.sender == _getPaymentGatewayStorage().bridgeContract, OnlyBridgeSender());
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
        PaymentGatewayStorage storage $ = _getPaymentGatewayStorage();
        require(_to != address(0), InvalidRecipient());
        require($.otherSide != address(0), ZeroAddress());
        require(msg.value == _amount, InvalidNativeAmount());

        FluentBridge($.bridgeContract).sendMessage{value: _amount}(
            $.otherSide,
            abi.encodeCall(PaymentGateway.receiveNativeTokens, (msg.sender, _to, _amount))
        );
    }

    /// @inheritdoc IGateway
    function sendTokens(address _token, address _to, uint256 _amount) external nonReentrant {
        require(_getPaymentGatewayStorage().otherSide != address(0), ZeroAddress());
        require(_to != address(0), InvalidRecipient());
        _sendTokensFrom(_token, msg.sender, msg.sender, _to, _amount);
    }

    function _sendTokensFrom(address _token, address _sender, address _from, address _to, uint256 _amount) internal {
        PaymentGatewayStorage storage $ = _getPaymentGatewayStorage();
        bytes memory _message;

        if ($.tokenMapping[_token] == address(0)) {
            require($.otherSide != address(0) && $.otherSideFactory != address(0), ZeroAddress());
            require($.otherSideChainId != 0 || $.otherSideBeacon != address(0), ZeroAddress());
            if (_from != address(this)) {
                IERC20(_token).safeTransferFrom(_from, address(this), _amount);
            }

            string memory symbol = ERC20(_token).symbol();
            string memory name = ERC20(_token).name();
            uint8 decimals = ERC20(_token).decimals();
            bytes memory rawTokenMetadata = abi.encode(symbol, name, decimals);
            address peggedToken = _computeOtherSidePeggedTokenAddress(_token, name, symbol, decimals);
            _message = abi.encodeCall(PaymentGateway.receivePeggedTokens, (_token, peggedToken, _sender, _to, _amount, rawTokenMetadata));
        } else {
            (, address originAddress) = ERC20PeggedToken(_token).getOrigin();
            require($.tokenMapping[_token] == originAddress, TokenMappingCheckFailed());

            ERC20PeggedToken(_token).burn(_from, _amount);

            _message = abi.encodeCall(PaymentGateway.receiveOriginTokens, (originAddress, _sender, _to, _amount));
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
        PaymentGatewayStorage storage $ = _getPaymentGatewayStorage();
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
        require(FluentBridge(msg.sender).nativeSender() == _getPaymentGatewayStorage().otherSide, MessageFromWrongGateway());
        require(msg.value == 0, MessageValueMustBeZero());
        require(_to != address(0), InvalidRecipient());

        IERC20(_originToken).safeTransfer(_to, _amount);

        emit ReceivedTokens(_from, _to, _amount);
    }

    /// @inheritdoc IGateway
    function receiveNativeTokens(address _from, address _to, uint256 _amount) external payable onlyBridgeSender nonReentrant {
        require(FluentBridge(msg.sender).nativeSender() == _getPaymentGatewayStorage().otherSide, MessageFromWrongGateway());
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
        (string memory _symbol, string memory _name, uint8 _decimals) = abi.decode(_tokenMetadata, (string, string, uint8));
        PaymentGatewayStorage storage $ = _getPaymentGatewayStorage();
        bytes memory deployArgs = IGenericTokenFactory($.tokenFactory).getDeployArgs(_name, _symbol, _decimals);

        bytes memory keyData;
        if (IGenericTokenFactory($.tokenFactory).beacon() != address(0)) {
            keyData = abi.encode(address(this), _originToken);
        } else {
            keyData = abi.encode(_originToken, block.chainid);
        }

        address _peggedToken = IGenericTokenFactory($.tokenFactory).deployToken(keyData, deployArgs);

        try ERC20PeggedToken(_peggedToken).initialize(_name, _symbol, _decimals, address(this), _originToken) {
            // ERC20PeggedToken (beacon proxy) needs one-time initialize; success path.
        } catch {
            // Token already initialized (e.g. Universal token from UniversalTokenFactory); skip.
        }
        return _peggedToken;
    }

    function _computeOtherSidePeggedTokenAddress(
        address _originToken,
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) internal view returns (address) {
        PaymentGatewayStorage storage $ = _getPaymentGatewayStorage();

        if ($.otherSideChainId != 0) {
            return
                UniversalTokenSDK.computeTokenAddress(
                    $.otherSideFactory,
                    _originToken,
                    $.otherSideChainId,
                    _name,
                    _symbol,
                    _decimals,
                    0,
                    $.otherSide,
                    $.otherSide
                );
        }

        bytes32 salt = keccak256(abi.encodePacked($.otherSide, _originToken));
        bytes memory bytecode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode($.otherSideBeacon, ""));
        return Create2.computeAddress(salt, keccak256(bytecode), $.otherSideFactory);
    }

    // ============ Public getters ============

    function bridgeContract() public view returns (address) {
        return _getPaymentGatewayStorage().bridgeContract;
    }

    function tokenFactory() public view returns (address) {
        return _getPaymentGatewayStorage().tokenFactory;
    }

    function otherSide() public view returns (address) {
        return _getPaymentGatewayStorage().otherSide;
    }

    function otherSideTokenImplementation() public view returns (address) {
        return _getPaymentGatewayStorage().otherSideTokenImplementation;
    }

    function otherSideFactory() public view returns (address) {
        return _getPaymentGatewayStorage().otherSideFactory;
    }

    function otherSideBeacon() public view returns (address) {
        return _getPaymentGatewayStorage().otherSideBeacon;
    }

    function otherSideChainId() public view returns (uint256) {
        return _getPaymentGatewayStorage().otherSideChainId;
    }

    function tokenMapping(address key) public view returns (address) {
        return _getPaymentGatewayStorage().tokenMapping[key];
    }

    /// @inheritdoc IGateway
    function computePeggedTokenAddress(address _token) external view returns (address) {
        PaymentGatewayStorage storage $ = _getPaymentGatewayStorage();
        bytes memory deployArgs;
        bytes memory keyData;

        if (IGenericTokenFactory($.tokenFactory).beacon() != address(0)) {
            keyData = abi.encode(address(this), _token);
            deployArgs = "";
        } else {
            string memory symbol = ERC20(_token).symbol();
            string memory name = ERC20(_token).name();
            uint8 decimals = ERC20(_token).decimals();
            deployArgs = IGenericTokenFactory($.tokenFactory).getDeployArgs(name, symbol, decimals);
            keyData = abi.encode(_token, block.chainid);
        }

        return IGenericTokenFactory($.tokenFactory).computePeggedTokenAddress(keyData, deployArgs);
    }

    /// @inheritdoc IGateway
    function computeOtherSidePeggedTokenAddress(address _token) external view returns (address) {
        return _computeOtherSidePeggedTokenAddress(_token, ERC20(_token).name(), ERC20(_token).symbol(), ERC20(_token).decimals());
    }

    function gasLimit() public view returns (uint256) {
        return _getPaymentGatewayStorage().gasLimit;
    }

    // ============ Admin functions ============

    /**
     * @notice Updates the bridge contract address used for sending and receiving messages.
     * @param _bridgeContract The address of the bridge contract.
     */
    function setBridgeContract(address _bridgeContract) external onlyOwner {
        _setBridgeContract(_bridgeContract);
    }

    function _setBridgeContract(address _bridgeContract) internal {
        require(_bridgeContract != address(0), ZeroAddress());
        PaymentGatewayStorage storage $ = _getPaymentGatewayStorage();
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
        PaymentGatewayStorage storage $ = _getPaymentGatewayStorage();
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
        PaymentGatewayStorage storage $ = _getPaymentGatewayStorage();
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
        PaymentGatewayStorage storage $ = _getPaymentGatewayStorage();
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
        PaymentGatewayStorage storage $ = _getPaymentGatewayStorage();

        emit OtherSideUpdated(
            $.otherSide,
            _otherSide,
            $.otherSideTokenImplementation,
            _otherSideTokenImplementation,
            $.otherSideFactory,
            _otherSideFactory,
            $.otherSideBeacon,
            _otherSideBeacon
        );

        $.otherSide = _otherSide;
        $.otherSideTokenImplementation = _otherSideTokenImplementation;
        $.otherSideFactory = _otherSideFactory;
        $.otherSideBeacon = _otherSideBeacon;
        $.otherSideChainId = 0;
    }

    /**
     * @notice Sets remote gateway/factory configuration for a Universal-token destination chain.
     * @param _otherSide The remote gateway address.
     * @param _otherSideTokenImplementation The remote token implementation/runtime identifier.
     * @param _otherSideFactory The remote UniversalTokenFactory proxy address.
     * @param _otherSideChainId The remote chain id used for Universal CREATE2 salt derivation.
     */
    function setOtherSideUniversal(
        address _otherSide,
        address _otherSideTokenImplementation,
        address _otherSideFactory,
        uint256 _otherSideChainId
    ) external onlyOwner {
        require(
            _otherSide != address(0) && _otherSideTokenImplementation != address(0) && _otherSideFactory != address(0) && _otherSideChainId != 0,
            ZeroAddress()
        );

        PaymentGatewayStorage storage $ = _getPaymentGatewayStorage();
        emit OtherSideUpdated(
            $.otherSide,
            _otherSide,
            $.otherSideTokenImplementation,
            _otherSideTokenImplementation,
            $.otherSideFactory,
            _otherSideFactory,
            $.otherSideBeacon,
            address(0)
        );

        $.otherSide = _otherSide;
        $.otherSideTokenImplementation = _otherSideTokenImplementation;
        $.otherSideFactory = _otherSideFactory;
        $.otherSideBeacon = address(0);
        $.otherSideChainId = _otherSideChainId;
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
        PaymentGatewayStorage storage $ = _getPaymentGatewayStorage();
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
        _setGasLimit(_gasLimit);
    }

    function _setGasLimit(uint256 _gasLimit) internal {
        PaymentGatewayStorage storage $ = _getPaymentGatewayStorage();
        require(_gasLimit > 0, InvalidGasLimit());
        emit GasLimitUpdated($.gasLimit, _gasLimit);
        $.gasLimit = _gasLimit;
    }

    /// @notice Receives ETH (e.g. forced transfers). Prefer bridge entrypoints for normal flow.
    receive() external payable {}
}
