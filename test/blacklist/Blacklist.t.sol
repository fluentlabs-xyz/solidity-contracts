// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Blacklist} from "../../contracts/blacklist/Blacklist.sol";
import {IBlacklist} from "../../contracts/interfaces/IBlacklist.sol";

contract BlacklistTest is Test {
    address internal admin = makeAddr("admin");
    address internal user = makeAddr("user");
    address internal other = makeAddr("other");

    Blacklist internal blacklist;

    function setUp() public {
        Blacklist impl = new Blacklist();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Blacklist.initialize, (admin)));
        blacklist = Blacklist(address(proxy));
    }

    function test_setBlacklisted_emitsEventAndStoresStatus() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true, address(blacklist));
        emit IBlacklist.BlacklistStatusUpdated(_toKey(user), true);
        blacklist.setBlacklisted(user, true);

        assertTrue(blacklist.isBlacklisted(user));
        assertTrue(blacklist.isBlacklisted(_toKey(user)));
    }

    function test_setBlacklistedBatch_emitsPerAccountAndStoresStatus() public {
        address[] memory accounts = new address[](2);
        accounts[0] = user;
        accounts[1] = other;

        vm.prank(admin);
        vm.expectEmit(true, false, false, true, address(blacklist));
        emit IBlacklist.BlacklistStatusUpdated(_toKey(user), true);
        vm.expectEmit(true, false, false, true, address(blacklist));
        emit IBlacklist.BlacklistStatusUpdated(_toKey(other), true);
        blacklist.setBlacklistedBatch(accounts, true);

        assertTrue(blacklist.isBlacklisted(user));
        assertTrue(blacklist.isBlacklisted(other));
    }

    function test_setBlacklistedBatch_bytes32_emitsPerAccountAndStoresStatus() public {
        bytes32[] memory accounts = new bytes32[](2);
        accounts[0] = _toKey(user);
        // Non-EVM key: high bits set so this cannot be expressed as an EVM address.
        accounts[1] = bytes32(type(uint256).max);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true, address(blacklist));
        emit IBlacklist.BlacklistStatusUpdated(accounts[0], true);
        vm.expectEmit(true, false, false, true, address(blacklist));
        emit IBlacklist.BlacklistStatusUpdated(accounts[1], true);
        blacklist.setBlacklistedBatch(accounts, true);

        assertTrue(blacklist.isBlacklisted(user));
        assertTrue(blacklist.isBlacklisted(accounts[1]));
    }

    /// @dev Locks the storage-layout backwards-compat invariant: a slot written under the
    ///      previous `mapping(address => bool) _blacklisted` layout must remain readable via
    ///      both overloads after the in-place upgrade to `mapping(bytes32 => bool)`.
    function test_isBlacklisted_readsLegacyAddressSlotAfterMigration() public {
        // Mirrors `Blacklist.BLACKLIST_STORAGE_LOCATION`; `_blacklisted` is field 0 so its slot equals the base.
        bytes32 base = 0x26698338709d046d57ff3f8225220f7106e4ab33e623ea73fdda921318dfe600;

        // `abi.encode(address, bytes32)` left-pads the address — identical to the current
        // `mapping(bytes32 => bool)` formula when keyed by `bytes32(uint256(uint160(addr)))`.
        bytes32 legacySlot = keccak256(abi.encode(user, base));
        vm.store(address(blacklist), legacySlot, bytes32(uint256(1)));

        assertTrue(blacklist.isBlacklisted(user), "legacy address slot must be readable via address overload");
        assertTrue(blacklist.isBlacklisted(_toKey(user)), "legacy address slot must be readable via bytes32 overload");
    }

    function test_RevertIf_setBlacklisted_notOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        blacklist.setBlacklisted(user, true);
    }

    function _toKey(address account) private pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}
