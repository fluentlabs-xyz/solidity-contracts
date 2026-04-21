// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IWETH} from "../interfaces/IWETH.sol";

/**
 * @title MockWETH
 * @dev WETH9-shaped mock for Sepolia test deployments and Foundry tests.
 */
contract MockWETH is ERC20, IWETH {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    /// @inheritdoc IWETH
    function deposit() public payable override {
        _mint(msg.sender, msg.value);
    }

    /// @inheritdoc IWETH
    function withdraw(uint256 amount) external override {
        _burn(msg.sender, amount);
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "MockWETH: withdraw failed");
    }

    receive() external payable {
        deposit();
    }
}

/**
 * @title BadWrapMockWETH
 * @dev Test-only broken WETH for gateway negative tests.
 */
contract BadWrapMockWETH is ERC20, IWETH {
    constructor() ERC20("Bad Wrap WETH", "bwWETH") {}

    function deposit() public payable override {
        _mint(msg.sender, msg.value / 2);
    }

    function withdraw(uint256 amount) external override {
        _burn(msg.sender, amount);
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "withdraw failed");
    }

    receive() external payable {
        deposit();
    }
}

/**
 * @title BadUnwrapMockWETH
 * @dev Test-only broken WETH for gateway negative tests.
 */
contract BadUnwrapMockWETH is ERC20, IWETH {
    constructor() ERC20("Bad Unwrap WETH", "buWETH") {}

    function deposit() public payable override {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external override {
        _burn(msg.sender, amount);
        (bool ok, ) = payable(msg.sender).call{value: amount / 2}("");
        require(ok, "withdraw failed");
    }

    receive() external payable {
        deposit();
    }
}

/**
 * @title FeeOnTransferMockWETH
 * @dev Test-only non-canonical WETH: transfer charges 50% fee.
 */
contract FeeOnTransferMockWETH is ERC20, IWETH {
    constructor() ERC20("Fee-on-transfer WETH", "ftWETH") {}

    function deposit() public payable override {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external override {
        _burn(msg.sender, amount);
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "withdraw failed");
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        if (from != address(0) && to != address(0) && value > 0) {
            uint256 fee = value / 2;
            uint256 sendAmount = value - fee;
            super._update(from, address(this), fee);
            super._update(from, to, sendAmount);
            return;
        }
        super._update(from, to, value);
    }

    receive() external payable {
        deposit();
    }
}

/**
 * @title MockUniversalWETH
 * @dev Test double for Universal-WETH precompile: `deposit`/`withdraw` plus owner-gated `mint`/`burn`.
 */
contract MockUniversalWETH is ERC20, IWETH {
    error OnlyOwner();

    address public immutable owner;

    uint256 public mintCalls;
    uint256 public burnCalls;

    constructor(address owner_) ERC20("Universal Wrapped Ether", "WETH") {
        owner = owner_;
    }

    function deposit() public payable override {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external override {
        _burn(msg.sender, amount);
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "MockUniversalWETH: withdraw failed");
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != owner) revert OnlyOwner();
        unchecked {
            mintCalls += 1;
        }
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != owner) revert OnlyOwner();
        unchecked {
            burnCalls += 1;
        }
        _burn(from, amount);
    }

    receive() external payable {
        deposit();
    }
}
