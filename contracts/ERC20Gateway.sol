// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {ERC20PeggedToken} from "./ERC20PeggedToken.sol";
import {ERC20TokenFactory} from "./ERC20TokenFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RestakingPool} from "./restaker/RestakingPool.sol";
import {IRestakingPool} from "./restaker/interfaces/IRestakingPool.sol";
import {Bridge} from "./Bridge.sol";

contract ERC20Gateway is Ownable2Step {
    using SafeERC20 for IERC20;

    struct TokenMetadata {
        string symbol;
        string name;
        uint8 decimals;
    }

    modifier onlyBridgeSender() {
        require(msg.sender == bridgeContract, "call only from bridge");
        _;
    }

    mapping(address => address) private tokenMapping;

    address public bridgeContract;
    address public tokenFactory;
    address public otherSide;
    address public otherSideTokenImplementation;
    address public otherSideFactory;

    event ReceivedTokens(address source, address target, uint256 amount);
    event UpdateTokenMapping(
        address indexed _peggedToken,
        address indexed _oldOriginToken,
        address indexed _newOriginToken
    );
    event OtherSideUpdated(
        address indexed _oldOtherSide,
        address indexed _newOtherSide,
        address indexed _oldImplementation,
        address _newImplementation,
        address _oldFactory,
        address _newFactory
    );

    constructor(
        address _bridgeContract,
        address _tokenFactory
    ) payable Ownable(msg.sender) {
        bridgeContract = _bridgeContract;
        tokenFactory = _tokenFactory;
    }

    function setOtherSide(
        address _otherSide,
        address _otherSideTokenImplementation,
        address _otherSideFactory
    ) external payable onlyOwner {
        address oldOtherSide = otherSide;
        address oldImplementation = otherSideTokenImplementation;
        address oldFactory = otherSideFactory;
        
        otherSide = _otherSide;
        otherSideTokenImplementation = _otherSideTokenImplementation;
        otherSideFactory = _otherSideFactory;

        emit OtherSideUpdated(
            oldOtherSide,
            _otherSide,
            oldImplementation,
            _otherSideTokenImplementation,
            oldFactory,
            _otherSideFactory
        );
    }

    function computePeggedTokenAddress(
        address _token
    ) external view returns (address) {
        return
            ERC20TokenFactory(tokenFactory).computePeggedTokenAddress(
                address(this),
                _token
            );
    }

    function computeOtherSidePeggedTokenAddress(
        address _token
    ) external view returns (address) {
        return
            ERC20TokenFactory(tokenFactory).computeOtherSidePeggedTokenAddress(
                otherSide,
                _token,
                otherSideTokenImplementation,
                otherSideFactory
            );
    }

    function sendTokens(
        address _token,
        address _to,
        uint256 _amount
    ) external payable {
        sendTokensFrom(_token, msg.sender, msg.sender, _to, _amount, msg.value);
    }

    function sendTokensFrom(
        address _token,
        address _sender,
        address _from,
        address _to,
        uint256 _amount,
        uint256 _value
    ) internal {
        bytes memory _message;

        if (tokenMapping[_token] == address(0)) {
            if (_from != address(this)) {
                IERC20(_token).safeTransferFrom(_from, address(this), _amount);
            }

            bytes memory rawTokenMetadata = abi.encode(
                ERC20(_token).symbol(),
                ERC20(_token).name(),
                ERC20(_token).decimals()
            );

            address peggedToken = ERC20TokenFactory(tokenFactory)
                .computeOtherSidePeggedTokenAddress(
                    otherSide,
                    _token,
                    otherSideTokenImplementation,
                    otherSideFactory
                );
            _message = abi.encodeCall(
                ERC20Gateway.receivePeggedTokens,
                (_token, peggedToken, _sender, _to, _amount, rawTokenMetadata)
            );
        } else {
            (, address originAddress) = ERC20PeggedToken(
                _token
            ).getOrigin();
            require(tokenMapping[_token] == originAddress);

            ERC20PeggedToken(_token).burn(_from, _amount);

            _message = abi.encodeCall(
                ERC20Gateway.receiveNativeTokens,
                (originAddress, _sender, _to, _amount)
            );
        }

        Bridge(bridgeContract).sendMessage{value: _value}(otherSide, _message);
    }

    function receivePeggedTokens(
        address _originToken,
        address _peggedToken,
        address _from,
        address _to,
        uint256 _amount,
        bytes calldata _tokenMetadata
    ) external payable onlyBridgeSender {

        require(Bridge(msg.sender).nativeSender() == otherSide, "Message provide from wrong gateway");

        require(msg.value == 0, "Message value have to equal zero");

        require(_originToken != address(0), "Origin token can't be equal zero");
        uint256 l = _peggedToken.code.length;

        if (_peggedToken.code.length == 0) {
            address new_pegged_token = _deployL2Token(
                _tokenMetadata,
                _originToken
            );

            require(
                new_pegged_token == _peggedToken,
                "321Wrong pegged token provided as argument"
            );

            tokenMapping[_peggedToken] = _originToken;
        } else {
            require(
                tokenMapping[_peggedToken] == _originToken,
                "123Failed while token mapping check. Origin or pegged token is wrong"
            );
        }

        ERC20PeggedToken(_peggedToken).mint(_to, _amount);

        emit ReceivedTokens(_from, _to, _amount);
    }

    function receiveNativeTokens(
        address _nativeToken,
        address _from,
        address _to,
        uint256 _amount
    ) external payable onlyBridgeSender {
        require(Bridge(msg.sender).nativeSender() == otherSide, "Message provide from wrong gateway");

        _receiveNativeTokens(_nativeToken, _from, _to, _amount);
    }

    function _receiveNativeTokens(
        address _nativeToken,
        address _from,
        address _to,
        uint256 _amount
    ) internal {
        require(msg.value == 0, "Message value have to equal zero");

        IERC20(_nativeToken).safeTransfer(_to, _amount);
        emit ReceivedTokens(_from, _to, _amount);
    }

    function updateTokenMapping(
        address _originToken,
        address _peggedToken
    ) external onlyOwner {
        require(_originToken != address(0), "token address cannot be 0");
        require(_peggedToken != address(0), "token address cannot be 0");

        address _oldOriginToken = tokenMapping[_peggedToken];
        tokenMapping[_peggedToken] = _originToken;

        emit UpdateTokenMapping(_peggedToken, _oldOriginToken, _originToken);
    }

    function acceptTokenFactory() external onlyOwner {
        ERC20TokenFactory(tokenFactory).acceptOwnership();
    }

    function _deployL2Token(
        bytes memory _tokenMetadata,
        address _originToken
    ) internal returns (address) {
        address _peggedToken = ERC20TokenFactory(tokenFactory)
            .deployPeggedToken(address(this), _originToken);

        (string memory _symbol, string memory _name, uint8 _decimals) = abi
            .decode(_tokenMetadata, (string, string, uint8));

        ERC20PeggedToken(_peggedToken).initialize(
            _name,
            _symbol,
            _decimals,
            address(this),
            _originToken
        );

        return _peggedToken;
    }
}
