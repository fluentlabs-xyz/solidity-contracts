// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IGenericTokenFactory} from "../interfaces/IGenericTokenFactory.sol";

/**
 * @title GenericTokenFactory
 * @notice Base contract for upgradeable token factories used by the bridge
 * @dev Provides common storage (ERC-7201), events, and IGenericTokenFactory delegation.
 *      Subclasses implement _computeTokenAddressView and deployToken; base exposes computeTokenAddress.
 */
abstract contract GenericTokenFactory is Initializable, Ownable2StepUpgradeable, IGenericTokenFactory {
    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.GenericTokenFactoryStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GENERIC_TOKEN_FACTORY_STORAGE_LOCATION = 0x2e7141bc12ac0a34646003e28ce36e2b4a5ec6dcb16986fae278c46570192200;

    function _getGenericTokenFactoryStorage() private pure returns (GenericTokenFactoryStorage storage $) {
        assembly {
            $.slot := GENERIC_TOKEN_FACTORY_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the upgradeable base (call from subclass initialize).
    function __GenericTokenFactory_init(address initialOwner) internal onlyInitializing {
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
    }

    /// @notice Mapping from L1 token address to L2 token address (forwarder for ERC-7201 storage)
    function bridgedTokens(address key) public view returns (address) {
        return _getGenericTokenFactoryStorage().bridgedTokens[key];
    }

    /// @notice Mapping from token address to deployment info (forwarder for ERC-7201 storage)
    function tokenInfo(address key) public view returns (TokenInfo memory) {
        return _getGenericTokenFactoryStorage().tokenInfo[key];
    }

    /// @inheritdoc IGenericTokenFactory
    function computeTokenAddress(bytes calldata keyData, bytes calldata deployArgs) external view virtual override returns (address) {
        return _computeTokenAddressView(keyData, deployArgs);
    }

    /// @inheritdoc IGenericTokenFactory
    function deployToken(bytes calldata keyData, bytes calldata deployArgs) external virtual override returns (address);

    /// @dev Subclasses implement: decode keyData/deployArgs and return predicted token address.
    function _computeTokenAddressView(bytes calldata keyData, bytes calldata deployArgs) internal view virtual returns (address);

    /// @dev Subclasses use this to update bridged token storage (ERC-7201).
    function _setBridgedToken(address l1Token, address l2Token) internal {
        _getGenericTokenFactoryStorage().bridgedTokens[l1Token] = l2Token;
    }

    /// @dev Subclasses use this to update token info storage (ERC-7201).
    function _setTokenInfo(address tokenAddress, TokenInfo memory info) internal {
        _getGenericTokenFactoryStorage().tokenInfo[tokenAddress] = info;
    }
}
