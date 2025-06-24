// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IBridge} from "./interfaces/IBridge.sol";
import {ERC20PeggedToken} from "./ERC20PeggedToken.sol";
import {ERC20TokenFactory} from "./ERC20TokenFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRestakingPool} from "./restaker/interfaces/IRestakingPool.sol";
import {ILiquidityToken} from "./restaker/interfaces/ILiquidityToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20Gateway} from "./ERC20Gateway.sol";

contract RestakerGateway is Ownable, ERC20Gateway {
    address public restakerPool;
    address public liquidityToken;

    event TokensRestaked(
        address _staker,
        uint256 _stakedAmount,
        uint256 _mintedLiqudityToken
    );

    event TokensUnstaked(
        address _staker,
        //        uint256 _stakedAmount,
        uint256 _mintedLiqudityToken
    );

    constructor(
        address _bridgeContract,
        address payable _restakerPoolContract,
        address _tokenFactory
    ) payable ERC20Gateway(_bridgeContract, _tokenFactory) {
        restakerPool = _restakerPoolContract;
    }

    function setRestakerPool(address _restakerPool) external payable onlyOwner {
        restakerPool = _restakerPool;
    }

    function setLiquidityToken(
        address _liquidityToken
    ) external payable onlyOwner {
        liquidityToken = _liquidityToken;
    }

    function sendRestakedTokens(address to) external payable {
        address tokenContract = IRestakingPool(restakerPool)
            .getLiquidityToken();

        IERC20 token = IERC20(tokenContract);

        uint256 stakedAmount = msg.value;

        uint256 balanceBefore = token.balanceOf(address(this));

        IRestakingPool(restakerPool).stake{value: stakedAmount}();

        uint256 mintedTokens = token.balanceOf(address(this)) - balanceBefore;

        sendTokensFrom(
            tokenContract,
            msg.sender,
            address(this),
            to,
            mintedTokens,
            0
        );

        emit TokensRestaked(msg.sender, stakedAmount, mintedTokens);
    }

    function sendUnstakingTokens(address to, uint256 _amount) external payable {
        address pegged_token = ERC20TokenFactory(tokenFactory)
            .computePeggedTokenAddress(address(this), liquidityToken);

        (address originGateway, address originAddress) = ERC20PeggedToken(
            pegged_token
        ).getOrigin();

        require(
            originAddress == liquidityToken,
            "wrong pegged token calculation"
        );

        ERC20PeggedToken(pegged_token).burn(msg.sender, _amount);

        bytes memory _message = abi.encodeCall(
            RestakerGateway.receiveUnstakingTokens,
            (msg.sender, to, _amount)
        );

        IBridge(bridgeContract).sendMessage{value: msg.value}(
            otherSide,
            _message
        );
    }

    function receiveUnstakingTokens(
        address _from,
        address _to,
        uint256 _shares
    ) external payable onlyBridgeSender {
        address tokenContract = IRestakingPool(restakerPool)
            .getLiquidityToken();
        ILiquidityToken token = ILiquidityToken(tokenContract);

        uint256 amount = token.convertToAmount(_shares);

        IRestakingPool(restakerPool).unstakeFrom(address(this), _to, _shares);

        emit TokensUnstaked(_to, _shares);
    }
}
