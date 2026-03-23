// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IGenericTokenFactoryErrors
 * @author Fluent Labs
 */
interface IGenericTokenFactoryErrors {
    /**
     * @dev Thrown when the address is zero.
     * @dev selector: 0x44034241
     */
    error ZeroAddressNotAllowed(string field);

    /**
     * @dev Thrown when the origin token is invalid.
     * @dev selector: 0x0e695881
     */
    error InvalidOriginToken();

    /**
     * @dev Thrown when the token is already deployed.
     * @dev selector: 0x6474d0da
     */
    error TokenAlreadyDeployed();

    /**
     * @dev Thrown when the chain ID is invalid.
     * @dev selector: 0x7a47c9a2
     */
    error InvalidChainId();

    /**
     * @dev Thrown when the chain ID is not the same as the block chain ID.
     * @dev selector: 0x5f87bc00
     */
    error WrongChainId();

    /**
     * @dev Thrown when the token deployment fails.
     * @dev selector: 0xd0a30aa6
     */
    error TokenDeploymentFailed();

    /**
     * @dev Thrown when the caller is not the payments gateway or the owner.
     * @dev selector: 0x5d7ca671
     */
    error OnlyPaymentGatewayOrOwner();

    /**
     * @dev Thrown when the value is zero.
     * @dev selector: 0x78bcc63a
     */
    error ZeroValueNotAllowed(string field);
}

/**
 * @title IGenericTokenFactoryEvents
 * @dev Events emitted by token factory contracts.
 */
interface IGenericTokenFactoryEvents {
    /**
     * @notice Emitted when a token is deployed
     * @param originToken The origin token address
     * @param peggedToken The pegged token address
     */
    event TokenDeployed(address indexed originToken, address indexed peggedToken);

    /**
     * @notice Emitted when the payment gateway is set
     * @param prevValue The previous payment gateway address
     * @param newValue The new payment gateway address
     */
    event PaymentGatewaySet(address indexed prevValue, address indexed newValue);

    /**
     * @notice Emitted when the beacon is set
     * @param prevValue The previous beacon address
     * @param newValue The new beacon address
     */
    event BeaconSet(address indexed prevValue, address indexed newValue);
}

/**
 * @title IGenericTokenFactory
 * @author Fluent Labs
 * @notice Single interface for all token factories (ERC20 pegged, Universal, etc.)
 * @dev Two external functions only. Use keyData + deployArgs so different factory types share one interface:
 *      - ERC20/gateway: keyData = abi.encode(gateway, originToken), deployArgs = ""
 *      - Universal: keyData = abi.encode(gateway, originToken), deployArgs = abi.encode(name, symbol, decimals, initialSupply, minter, pauser)
 */
interface IGenericTokenFactory is IGenericTokenFactoryErrors, IGenericTokenFactoryEvents {
    /**
     * @notice Deploys a bridged/pegged token
     * @param gateway The gateway address
     * @param originToken The origin token address
     * @param deployArgs Optional deployment params (empty for ERC20; for Universal: name, symbol, decimals, initialSupply, minter, pauser)
     * @return Address of the deployed token
     */
    function deployToken(address gateway, address originToken, bytes calldata deployArgs) external returns (address);

    /**
     * @notice Returns the deployment arguments for a token
     * @param tokenName The name of the token
     * @param tokenSymbol The symbol of the token
     * @param decimals The decimals of the token
     * @return Deployment arguments
     */
    function getDeployArgs(string memory tokenName, string memory tokenSymbol, uint8 decimals) external view returns (bytes memory);

    /**
     * @notice Computes the address of a token
     * @param gateway The gateway address
     * @param originToken The origin token address
     * @param deployArgs Optional deployment params (empty for ERC20; for Universal: name, symbol, decimals, initialSupply, minter, pauser)
     * @return Predicted token address
     */
    function computeTokenAddress(address gateway, address originToken, bytes calldata deployArgs) external view returns (address);

    /**
     * @notice Computes the address of a bridged/pegged token for the other side.
     * @param gateway The gateway address
     * @param originToken The origin token address
     * @param deployArgs Optional deployment params (empty for ERC20; for Universal: name, symbol, decimals, initialSupply, minter, pauser)
     * @return Predicted token address
     */
    function computeOtherSidePeggedTokenAddress(address gateway, address originToken, bytes calldata deployArgs) external view returns (address);

    /**
     * @notice Returns the beacon address
     * @return The beacon address
     */
    function beacon() external view returns (address);
}
