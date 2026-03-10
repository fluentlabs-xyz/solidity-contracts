// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title UniversalTokenSDK
 * @author Fluent Labs
 * @notice Solidity library for deploying and addressing Universal Tokens (L2 precompile-backed tokens) in a bridge-compatible way.
 * @dev Universal Tokens use a runtime at a fixed precompile (UNIVERSAL_TOKEN_RUNTIME) and deployment payload prefixed with
 *      UNIVERSAL_TOKEN_MAGIC_BYTES ("ERC "). Encoding (createDeploymentData / _encodeInitialSettingsRustCompatible) matches
 *      the Rust SDK exactly for cross-tooling compatibility.
 * @notice Main flows:
 * 1. Create deployment data:
 *    - createDeploymentData(name, symbol, decimals, initialSupply, minter, pauser) returns ABI-compatible bytes (magic + InitialSettings).
 *    - Used by UniversalTokenFactory for CREATE2 deployment; layout must match Rust SolidityABI::encode(InitialSettings).
 * 2. Deterministic address (CREATE2):
 *    - computeBridgeTokenSalt(originToken) = keccak256(BRIDGE_TOKEN_PREFIX, originToken). No chainId: same origin token => same pegged address per factory.
 *    - computeTokenAddress(factory, originToken, name, symbol, decimals, initialSupply, minter, pauser) returns the
 *      CREATE2 address for the token when deployed by `factory` with the above salt and init code hash from createDeploymentData.
 * 3. Helpers:
 *    - stringToBytes32 / bytes32ToString for name/symbol; createDeploymentDataBytes32 for bytes32 name/symbol.
 *    - deployToken (CREATE) and deployTokenCreate2 (CREATE2) for direct deployment outside factory.
 */
library UniversalTokenSDK {
    /// @notice Prefix for bridge token deployment
    string public constant BRIDGE_TOKEN_PREFIX = "BRIDGE_TOKEN";

    /// @notice Magic bytes prefix for Universal Token deployment (4 bytes: "ERC" + 0x20)
    bytes4 public constant UNIVERSAL_TOKEN_MAGIC_BYTES = bytes4(0x45524320); // "ERC "

    /// @notice Address of the Universal Token runtime precompile
    address public constant UNIVERSAL_TOKEN_RUNTIME = address(0x0000000000000000000000000000000000520008);

    /**
     * @notice Structure for Universal Token initial settings
     * @param tokenName Token name (max 32 bytes)
     * @param tokenSymbol Token symbol (max 32 bytes)
     * @param decimals Number of decimals (typically 18)
     * @param initialSupply Initial supply to mint to deployer
     * @param minter Optional minter address (zero address if not mintable)
     * @param pauser Optional pauser address (zero address if not pausable)
     */
    struct InitialSettings {
        bytes32 tokenName;
        bytes32 tokenSymbol;
        uint8 decimals;
        uint256 initialSupply;
        address minter;
        address pauser;
    }

    /**
     * @notice Creates deployment transaction data for a Universal Token
     * @param name Token name (will be truncated to 32 bytes)
     * @param symbol Token symbol (will be truncated to 32 bytes)
     * @param decimals Number of decimals
     * @param initialSupply Initial supply to mint
     * @param minter Minter address (address(0) if not mintable)
     * @param pauser Pauser address (address(0) if not pausable)
     * @return deploymentData Complete deployment data with magic bytes prefix
     * @dev Format matches Rust SDK exactly:
     *      UNIVERSAL_TOKEN_MAGIC_BYTES (4 bytes) +
     *      SolidityABI::encode(InitialSettings{TokenNameOrSymbol, TokenNameOrSymbol, u8, U256, Address, Address})
     *      where TokenNameOrSymbol is a transparent wrapper over [u8; 32].
     *
     *      Layout (after the 4-byte magic):
     *      - token_name: 32 * 32-byte words, one word per byte of the 32-byte name
     *      - token_symbol: 32 * 32-byte words
     *      - decimals: u8 stored in the last byte of a 32-byte word
     *      - initial_supply: uint256 as 32-byte big-endian
     *      - minter: address right-aligned in 32 bytes
     *      - pauser: address right-aligned in 32 bytes
     */
    function createDeploymentData(
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) public pure returns (bytes memory deploymentData) {
        bytes32 nameBytes = _stringToBytes32(name);
        bytes32 symbolBytes = _stringToBytes32(symbol);
        deploymentData = _encodeInitialSettingsRustCompatible(nameBytes, symbolBytes, decimals, initialSupply, minter, pauser);
    }

    /**
     * @notice Computes a salt for bridge token deployment from origin token address.
     * @param originToken Origin (e.g. L1) token address. No chainId: same origin => same pegged address per factory across chains.
     * @return salt Deterministic salt for CREATE2
     */
    function _computeBridgeTokenSalt(address originToken) internal pure returns (bytes32 salt) {
        return keccak256(abi.encodePacked(BRIDGE_TOKEN_PREFIX, originToken));
    }

    /**
     * @notice Computes the deterministic Universal token address for a given deploying factory.
     * @param factory The factory address that will execute CREATE2
     * @param originToken The bridged origin token
     * @param name Token name
     * @param symbol Token symbol
     * @param decimals Token decimals
     * @param initialSupply Initial supply
     * @param minter Minter address (for remote prediction use the other-side gateway)
     * @param pauser Pauser address (for remote prediction use the other-side gateway)
     * @return predicted The predicted token address
     */
    function computeTokenAddress(
        address factory,
        address originToken,
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) public pure returns (address predicted) {
        bytes memory deploymentData = createDeploymentData(name, symbol, decimals, initialSupply, minter, pauser);
        bytes32 salt = _computeBridgeTokenSalt(originToken);
        bytes32 initCodeHash = keccak256(deploymentData);
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash));
        return address(uint160(uint256(hash)));
    }

    /**
     * @notice Converts a string to bytes32 (truncates if longer than 32 bytes)
     * @param str Input string
     * @return result bytes32 representation
     */
    function _stringToBytes32(string memory str) internal pure returns (bytes32 result) {
        bytes memory tempBytes = bytes(str);
        if (tempBytes.length == 0) {
            return 0x0;
        }

        if (tempBytes.length <= 32) {
            assembly {
                result := mload(add(tempBytes, 32))
            }
        } else {
            // Truncate to 32 bytes
            assembly {
                result := mload(add(tempBytes, 32))
            }
        }
    }

    /**
     * @notice Internal helper that encodes InitialSettings using the same layout
     *         as Rust's SolidityABI::encode(InitialSettings), including magic prefix.
     */
    function _encodeInitialSettingsRustCompatible(
        bytes32 name,
        bytes32 symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) internal pure returns (bytes memory deploymentData) {
        // 4 bytes magic + 2 * 32 (bytes) * 32 (per-byte words) + 4 * 32 (decimals, supply, minter, pauser)
        uint256 TOTAL_LEN = 4 + 2 * 32 * 32 + 4 * 32; // 2180
        deploymentData = new bytes(TOTAL_LEN);

        uint256 offset = 0;

        // Magic bytes "ERC "
        deploymentData[0] = 0x45; // 'E'
        deploymentData[1] = 0x52; // 'R'
        deploymentData[2] = 0x43; // 'C'
        deploymentData[3] = 0x20; // ' '
        offset = 4;

        // Encode token_name: 32 bytes, each as a 32-byte word with the byte in the last position
        for (uint256 i = 0; i < 32; i++) {
            bytes1 b = name[i];
            uint256 wordStart = offset + i * 32;
            deploymentData[wordStart + 31] = b;
        }
        offset += 32 * 32; // 1024

        // Encode token_symbol: same pattern
        for (uint256 i = 0; i < 32; i++) {
            bytes1 b = symbol[i];
            uint256 wordStart = offset + i * 32;
            deploymentData[wordStart + 31] = b;
        }
        offset += 32 * 32; // +1024 => 2048 after magic

        // Encode decimals: u8 stored in the last byte of a 32-byte word
        deploymentData[offset + 31] = bytes1(decimals);
        offset += 32;

        // Encode initialSupply: uint256 as 32-byte big-endian word
        bytes32 supplyBE = bytes32(initialSupply);
        for (uint256 i = 0; i < 32; i++) {
            deploymentData[offset + i] = supplyBE[i];
        }
        offset += 32;

        // Encode minter: address right-aligned in 32 bytes
        bytes32 minterBE = bytes32(uint256(uint160(minter)));
        for (uint256 i = 0; i < 32; i++) {
            deploymentData[offset + i] = minterBE[i];
        }
        offset += 32;

        // Encode pauser: address right-aligned in 32 bytes
        bytes32 pauserBE = bytes32(uint256(uint160(pauser)));
        for (uint256 i = 0; i < 32; i++) {
            deploymentData[offset + i] = pauserBE[i];
        }
    }
}
