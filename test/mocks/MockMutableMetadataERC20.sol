// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC20 whose `name` and `symbol` can be changed in tests (OZ `ERC20` stores them privately).
contract MockMutableMetadataERC20 is ERC20 {
    string private _tokenName;
    string private _tokenSymbol;

    constructor(string memory name_, string memory symbol_, uint256 initialSupply, address supplyTarget) ERC20(name_, symbol_) {
        _tokenName = name_;
        _tokenSymbol = symbol_;
        _mint(supplyTarget, initialSupply);
    }

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    function setMetadata(string memory newName, string memory newSymbol) external {
        _tokenName = newName;
        _tokenSymbol = newSymbol;
    }
}
