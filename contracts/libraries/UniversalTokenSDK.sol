// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title UniversalTokenSDK
 * @notice Solidity SDK for deploying and interacting with Universal Tokens
 * @dev Universal Tokens use a precompile/runtime pattern with magic bytes for deployment
 */
library UniversalTokenSDK {
    /// @notice Magic bytes prefix for Universal Token deployment (4 bytes: "ERC" + 0x20)
    bytes4 public constant UNIVERSAL_TOKEN_MAGIC_BYTES = bytes4(0x45524320); // "ERC "

    /// @notice Address of the Universal Token runtime precompile
    address public constant UNIVERSAL_TOKEN_RUNTIME =
        address(0x0000000000000000000000000000000000520008);

    /// @notice Fluent Developer Preview chain ID (0x5201 = "R" + version 1)
    uint256 public constant FLUENT_DEVNET_CHAIN_ID = 10993;

    /// @notice Error thrown when deployment is attempted on non-Fluent chain
    error NotFluentChain(uint256 chainId);

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
     */
    function createDeploymentData(
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) internal pure returns (bytes memory deploymentData) {
        // Convert strings to bytes32 (truncate if needed)
        bytes32 nameBytes = stringToBytes32(name);
        bytes32 symbolBytes = stringToBytes32(symbol);

        // Encode InitialSettings struct
        bytes memory encoded = abi.encode(
            nameBytes,
            symbolBytes,
            decimals,
            initialSupply,
            minter,
            pauser
        );

        // Prepend magic bytes
        deploymentData = abi.encodePacked(UNIVERSAL_TOKEN_MAGIC_BYTES, encoded);
    }

    /**
     * @notice Computes the deterministic address for a Universal Token using CREATE2
     * @param deployer Address that will deploy the token
     * @param salt Salt for CREATE2 (can be derived from L1 token address for bridges)
     * @param bytecodeHash Hash of the deployment bytecode (empty for Universal Tokens)
     * @return predictedAddress The predicted address where the token will be deployed
     */
    function computeTokenAddress(
        address deployer,
        bytes32 salt,
        bytes32 bytecodeHash
    ) internal pure returns (address predictedAddress) {
        // For Universal Tokens, bytecode is empty (precompile pattern)
        // But we can use CREATE2 with a salt for deterministic addresses
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), deployer, salt, bytecodeHash)
        );
        return address(uint160(uint256(hash)));
    }

    /**
     * @notice Computes a salt for bridge token deployment from L1 token address
     * @param l1Token L1 token address
     * @param chainId Chain ID to ensure uniqueness across chains
     * @return salt Deterministic salt for CREATE2
     */
    function computeBridgeTokenSalt(
        address l1Token,
        uint256 chainId
    ) internal pure returns (bytes32 salt) {
        return keccak256(abi.encodePacked("BRIDGE_TOKEN", l1Token, chainId));
    }

    /**
     * @notice Computes the address of a bridged Universal Token
     * @param bridge Bridge contract address (deployer)
     * @param l1Token Original L1 token address
     * @param chainId Chain ID
     * @return tokenAddress Predicted Universal Token address on L2
     */
    function computeBridgedTokenAddress(
        address bridge,
        address l1Token,
        uint256 chainId
    ) internal pure returns (address tokenAddress) {
        bytes32 salt = computeBridgeTokenSalt(l1Token, chainId);
        // Universal Tokens have no bytecode (precompile pattern)
        bytes32 bytecodeHash = keccak256("");
        return computeTokenAddress(bridge, salt, bytecodeHash);
    }

    /**
     * @notice Converts a string to bytes32 (truncates if longer than 32 bytes)
     * @param str Input string
     * @return result bytes32 representation
     */
    function stringToBytes32(
        string memory str
    ) internal pure returns (bytes32 result) {
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
     * @notice Checks if the current chain is a Fluent chain
     * @dev Universal Tokens only work on Fluent chains with the precompile runtime
     * @return isFluent True if current chain is a Fluent chain
     */
    function isFluentChain() internal view returns (bool isFluent) {
        uint256 chainId = block.chainid;
        // Check against known Fluent chain IDs
        // Add more chain IDs as they are deployed (testnet, mainnet, etc.)
        return chainId == FLUENT_DEVNET_CHAIN_ID;
    }

    /**
     * @notice Deploys a Universal Token using CREATE2
     * @param salt Salt for deterministic address
     * @param name Token name
     * @param symbol Token symbol
     * @param decimals Number of decimals
     * @param initialSupply Initial supply
     * @param minter Minter address
     * @param pauser Pauser address
     * @return tokenAddress Address of the deployed token
     * @dev Reverts if not deployed on a Fluent chain (where precompile runtime exists)
     */
    function deployToken(
        bytes32 salt,
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) internal returns (address tokenAddress) {
        bytes memory deploymentData = createDeploymentData(
            name,
            symbol,
            decimals,
            initialSupply,
            minter,
            pauser
        );

        assembly {
            tokenAddress := create2(
                0,
                add(deploymentData, 0x20),
                mload(deploymentData),
                salt
            )
        }

        require(
            tokenAddress != address(0),
            "UniversalTokenSDK: deployment failed"
        );
    }
}
