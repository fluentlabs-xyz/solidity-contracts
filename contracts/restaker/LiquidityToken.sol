// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./Configurable.sol";
import "./interfaces/ILiquidityToken.sol";

contract LiquidityToken is Configurable, ERC20, ILiquidityToken {
    using Math for uint256;

    string private _name;
    string private _symbol;

    uint256[48] private __gap;

    /*******************************************************************************
                        EVENTS
    *******************************************************************************/

    event NameChanged(string newName);
    event SymbolChanged(string newSymbol);

    constructor(
        IProtocolConfig config,
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {
        __Configurable_init(config);
        __liquidityToken_init(name, symbol);
    }

    function __liquidityToken_init(
        string memory name,
        string memory symbol
    ) internal {
        _changeName(name);
        _changeSymbol(symbol);
    }

    function mint(
        address account,
        uint256 shares
    ) external override onlyRestakingPool {
        _mint(account, shares);
    }

    function burn(
        address account,
        uint256 shares
    ) external override onlyRestakingPool {
        _burn(account, shares);
    }

    function convertToAmount(
        uint256 shares
    ) public view override returns (uint256) {
        return shares.mulDiv(1 ether, ratio(), Math.Rounding.Ceil);
    }

    function convertToShares(
        uint256 amount
    ) public view override returns (uint256) {
        return amount.mulDiv(ratio(), 1 ether, Math.Rounding.Floor);
    }

    function ratio() public view override returns (uint256) {
        return config().getRatioFeed().getRatio(address(this));
    }

    function totalAssets()
        external
        view
        override
        returns (uint256 totalManagedEth)
    {
        return convertToAmount(totalSupply());
    }

    function changeName(string memory newName) external onlyGovernance {
        _changeName(newName);
    }

    function changeSymbol(string memory newSymbol) external onlyGovernance {
        _changeSymbol(newSymbol);
    }

    function _changeName(string memory newName) internal {
        _name = newName;
        emit NameChanged(newName);
    }

    function _changeSymbol(string memory newSymbol) internal {
        _symbol = newSymbol;
        emit SymbolChanged(newSymbol);
    }

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }
}
