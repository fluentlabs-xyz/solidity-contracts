// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {IBlacklist} from "../interfaces/IBlacklist.sol";

/**
 * @title Blacklist
 * @author Fluent Labs
 * @notice On-chain denylist for addresses that must not initiate bridge deposits on this chain.
 * @dev UUPS-upgradeable; storage is ERC-7201 namespaced. Deploy one instance per chain (L1 and L2)
 *      and configure each token gateway's `GatewayBase.setBlacklistRegistry` when enforcement is desired.
 */
contract Blacklist is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, IBlacklist {
    // ============ Constants ============

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.BlacklistStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BLACKLIST_STORAGE_LOCATION = 0x26698338709d046d57ff3f8225220f7106e4ab33e623ea73fdda921318dfe600;

    /// @custom:storage-location erc7201:Fluent.storage.BlacklistStorage
    struct BlacklistStorage {
        mapping(address => bool) _blacklisted;
        uint256[50] __gap;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the blacklist contract.
     * @param initialOwner The initial owner of the contract.
     */
    function initialize(address initialOwner) external initializer {
        require(initialOwner != address(0), ZeroOwner());
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    /// @inheritdoc IBlacklist
    function isBlacklisted(address account) external view override returns (bool) {
        return _getBlacklistStorage()._blacklisted[account];
    }

    /**
     * @notice Sets or clears the blacklist flag for a single address.
     */
    function setBlacklisted(address account, bool status) external onlyOwner {
        _getBlacklistStorage()._blacklisted[account] = status;
        emit BlacklistStatusUpdated(account, status);
    }

    /**
     * @notice Batch variant of {setBlacklisted} to reduce governance transaction count.
     */
    function setBlacklistedBatch(address[] calldata accounts, bool status) external onlyOwner {
        BlacklistStorage storage $ = _getBlacklistStorage();
        uint256 len = accounts.length;
        for (uint256 i; i < len; ) {
            $._blacklisted[accounts[i]] = status;
            emit BlacklistStatusUpdated(accounts[i], status);
            unchecked {
                ++i;
            }
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _getBlacklistStorage() private pure returns (BlacklistStorage storage $) {
        assembly ("memory-safe") {
            $.slot := BLACKLIST_STORAGE_LOCATION
        }
    }
}
