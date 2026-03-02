// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {GenericTokenFactory} from "./GenericTokenFactory.sol";
import {IGenericTokenFactory} from "../interfaces/IGenericTokenFactory.sol";
import {UniversalTokenSDK} from "../libraries/UniversalTokenSDK.sol";

/**
 * @title UniversalTokenFactory
 * @notice Factory for Universal Tokens. Only two external functions: computeTokenAddress + deployToken.
 * @dev Uses UniversalTokenSDK under the hood.
 *      keyData = abi.encode(l1Token, chainId), deployArgs = abi.encode(name, symbol, decimals, initialSupply, minter, pauser).
 *      chainId in keyData must match block.chainid for canonical per-chain deployment.
 */
contract UniversalTokenFactory is GenericTokenFactory {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the factory when used behind a proxy.
    function initialize(address initialOwner) external initializer {
        __GenericTokenFactory_init(initialOwner);
    }

    /// @inheritdoc IGenericTokenFactory
    function deployToken(bytes calldata keyData, bytes calldata deployArgs) external override onlyOwner returns (address tokenAddress) {
        (address originToken, uint256 chainId) = _decodeKeyData(keyData);
        (string memory name, string memory symbol, uint8 decimals, uint256 initialSupply, address minter, address pauser) = _decodeDeployArgs(
            deployArgs
        );

        tokenAddress = _deployWithSDK(originToken, chainId, name, symbol, decimals, initialSupply, minter, pauser);
        emit TokenDeployed(originToken, tokenAddress);

        return tokenAddress;
    }

    // /// @dev Subclasses implement: decode keyData/deployArgs and return predicted token address (via SDK).
    // function _computeTokenAddressView(bytes calldata keyData, bytes calldata deployArgs) internal view override returns (address) {
    //     (address originToken, uint256 chainId) = _decodeKeyData(keyData);
    //     (string memory name, string memory symbol, uint8 decimals, uint256 initialSupply, address minter, address pauser) = _decodeDeployArgs(
    //         deployArgs
    //     );
    //     return _computeAddressWithSDK(originToken, chainId, name, symbol, decimals, initialSupply, minter, pauser);
    // }

    /// @dev Salt for CREATE2 (must match SDK: keccak256(BRIDGE_TOKEN_PREFIX ++ originToken ++ chainId))
    function _bridgeTokenSalt(address originToken, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(UniversalTokenSDK.BRIDGE_TOKEN_PREFIX, originToken, chainId));
    }

    /// @dev Uses UniversalTokenSDK to compute CREATE2 address (internal only).
    function _computeAddressWithSDK(
        address originToken,
        uint256 chainId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) internal view returns (address) {
        bytes memory deploymentData = UniversalTokenSDK.createDeploymentData(name, symbol, decimals, initialSupply, minter, pauser);
        bytes32 salt = _bridgeTokenSalt(originToken, chainId);
        bytes32 initCodeHash = keccak256(deploymentData);
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash));
        return address(uint160(uint256(hash)));
    }

    /// @dev Uses UniversalTokenSDK to deploy with CREATE2 and updates base storage (internal only).
    function _deployWithSDK(
        address _originToken,
        uint256 chainId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) internal returns (address tokenAddress) {
        require(_originToken != address(0), InvalidOriginToken());
        require(chainId > 0, InvalidChainId());
        require(chainId == block.chainid, WrongChainId());
        require(bridgedTokens(_originToken) == address(0), TokenAlreadyDeployed());

        bytes memory deploymentData = UniversalTokenSDK.createDeploymentData(name, symbol, decimals, initialSupply, minter, pauser);
        bytes32 salt = _bridgeTokenSalt(_originToken, chainId);

        assembly {
            tokenAddress := create2(0, add(deploymentData, 0x20), mload(deploymentData), salt)
            if iszero(tokenAddress) {
                revert(0, 0)
            }
        }

        _setBridgedToken(_originToken, tokenAddress);
        _setTokenInfo(tokenAddress, TokenInfo({originToken: _originToken, chainId: chainId, deployed: true}));
    }

    function _decodeKeyData(bytes calldata keyData) internal pure returns (address originToken, uint256 chainId) {
        return abi.decode(keyData, (address, uint256));
    }

    function _decodeDeployArgs(
        bytes calldata deployArgs
    ) internal pure returns (string memory name, string memory symbol, uint8 decimals, uint256 initialSupply, address minter, address pauser) {
        return abi.decode(deployArgs, (string, string, uint8, uint256, address, address));
    }
}
