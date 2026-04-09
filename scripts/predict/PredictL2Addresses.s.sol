// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title PredictL2Addresses
 * @dev Computes deterministic contract addresses before deployment:
 *      - Shared proxy addresses from the target nonce map (deployer + nonce → CREATE)
 *      - L2 pegged token addresses via CREATE2 (UniversalTokenFactory magic bytes)
 *
 *      Usage:
 *        forge script scripts/predict/PredictL2Addresses.s.sol
 *
 *      Override deployer for testnet:
 *        DEPLOYER=0x1C92DffBCe76670F69007F22A54e31ff3Ab45d5E forge script scripts/predict/PredictL2Addresses.s.sol
 */
contract PredictL2Addresses is Script {
    /// @dev Mainnet deployer. For testnet use DEPLOYER=0x1C92DffBCe76670F69007F22A54e31ff3Ab45d5E
    address constant MAINNET_DEPLOYER = 0x482582979C9125abAb5a06F0E196E8F4015bF77A;

    /// @dev "ERC " magic prefix for the L2 precompile at 0x520008
    bytes4 constant UNIVERSAL_TOKEN_MAGIC_BYTES = bytes4(0x45524320);

    struct TokenConfig {
        address l1Address;
        string name;
        string symbol;
        uint8 decimals;
    }

    function run() external view {
        address deployer = vm.envOr("DEPLOYER", MAINNET_DEPLOYER);

        // ── Shared proxy addresses (target nonce map) ──
        address bridgeProxy = vm.computeCreateAddress(deployer, 1);
        address factoryProxy = vm.computeCreateAddress(deployer, 4);
        address erc20GatewayProxy = vm.computeCreateAddress(deployer, 6);
        address nativeGatewayProxy = vm.computeCreateAddress(deployer, 8);

        console2.log("=== Shared Proxy Addresses (deployer:", deployer, ") ===");
        console2.log("  Bridge proxy       (nonce 1):", bridgeProxy);
        console2.log("  Factory proxy      (nonce 4):", factoryProxy);
        console2.log("  ERC20Gateway proxy (nonce 6):", erc20GatewayProxy);
        console2.log("  NativeGateway proxy(nonce 8):", nativeGatewayProxy);

        // ── L2 pegged token addresses ──
        TokenConfig[] memory tokens = _tokenList();

        console2.log("");
        console2.log("=== L2 Pegged Token Addresses ===");
        for (uint256 i = 0; i < tokens.length; i++) {
            address pegged = _computeUniversalTokenAddress(
                factoryProxy,
                erc20GatewayProxy,
                tokens[i].l1Address,
                tokens[i].name,
                tokens[i].symbol,
                tokens[i].decimals
            );
            console2.log("  %s (L1: %s): %s", tokens[i].symbol, tokens[i].l1Address, pegged);
        }
    }

    // ============ Token List ============

    function _tokenList() internal pure returns (TokenConfig[] memory tokens) {
        tokens = new TokenConfig[](3);
        tokens[0] = TokenConfig({
            l1Address: 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599,
            name: "Wrapped BTC",
            symbol: "WBTC",
            decimals: 8
        });
        tokens[1] = TokenConfig({
            l1Address: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
            name: "USD Coin",
            symbol: "USDC",
            decimals: 6
        });
        tokens[2] = TokenConfig({
            l1Address: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            name: "Wrapped Ether",
            symbol: "WETH",
            decimals: 18
        });
    }

    // ============ CREATE2 Address Computation ============

    /**
     * @dev Computes the L2 pegged token address for a given L1 origin token.
     *      Matches the CREATE2 derivation in {UniversalTokenFactory._deployToken}
     *      and {ERC20Gateway._computeUniversalTokenAddress}.
     */
    function _computeUniversalTokenAddress(
        address factory,
        address gateway,
        address originToken,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal pure returns (address) {
        bytes memory deploymentData = _universalTokenDeploymentData(name, symbol, decimals, 0, gateway, gateway);
        bytes32 salt = keccak256(abi.encodePacked(gateway, originToken));
        bytes32 initCodeHash = keccak256(deploymentData);
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash));
        return address(uint160(uint256(hash)));
    }

    /**
     * @dev Constructs the UniversalToken init code with magic prefix.
     *      Matches {UniversalTokenFactory._deploymentData}.
     */
    function _universalTokenDeploymentData(
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            UNIVERSAL_TOKEN_MAGIC_BYTES,
            abi.encode(_stringToBytes32(name), _stringToBytes32(symbol), decimals, initialSupply, minter, pauser)
        );
    }

    function _stringToBytes32(string memory str) internal pure returns (bytes32 result) {
        bytes memory b = bytes(str);
        assembly {
            result := mload(add(b, 32))
        }
    }
}
