// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Deploys a standalone Universal (UST) token on Fluent L2 by sending a
///         CREATE transaction with the magic prefix (0x45524320, "ERC ") that the
///         L2 precompile at 0x520008 interprets as an ERC20 token spec. No factory.
///
/// @dev    Edit the constants below. The broadcast account becomes the receiver
///         of `INITIAL_SUPPLY` and the `MINTER`/`PAUSER` if set to msg.sender
///         via `address(0)` placeholder resolution at runtime.
///
///         Name / symbol are truncated to 32 bytes by the precompile.
contract DeployTestUST is Script {
    // ─── Edit these ─────────────────────────────────────────────────────
    string constant NAME = "Test UST";
    string constant SYMBOL = "tUST";
    uint8 constant DECIMALS = 18;
    uint256 constant INITIAL_SUPPLY = 1_000_000_000_000 ether; // minted to broadcaster
    // address(0) here means "resolve to tx.origin (broadcast account) at run()".
    // Use a concrete address to hard-pin minter/pauser to someone else.
    address constant MINTER = address(0);
    address constant PAUSER = address(0);
    // ────────────────────────────────────────────────────────────────────

    bytes4 constant UST_MAGIC_PREFIX = 0x45524320; // "ERC "

    function run() external returns (address token) {
        address minter = MINTER == address(0) ? msg.sender : MINTER;
        address pauser = PAUSER == address(0) ? msg.sender : PAUSER;

        bytes memory initCode = abi.encodePacked(
            UST_MAGIC_PREFIX,
            abi.encode(_toBytes32(NAME), _toBytes32(SYMBOL), DECIMALS, INITIAL_SUPPLY, minter, pauser)
        );

        console2.log("=== DeployTestUST ===");
        console2.log("  name:         ", NAME);
        console2.log("  symbol:       ", SYMBOL);
        console2.log("  decimals:     ", DECIMALS);
        console2.log("  initialSupply:", INITIAL_SUPPLY);
        console2.log("  minter:       ", minter);
        console2.log("  pauser:       ", pauser);
        console2.log("  initCode size:", initCode.length);

        vm.startBroadcast();
        assembly {
            token := create(0, add(initCode, 0x20), mload(initCode))
        }
        vm.stopBroadcast();

        require(token != address(0), "CREATE failed");

        console2.log("UST token deployed:", token);
    }

    function _toBytes32(string memory s) internal pure returns (bytes32 b) {
        bytes memory raw = bytes(s);
        require(raw.length <= 32, "string > 32 bytes");
        assembly {
            b := mload(add(raw, 32))
        }
    }
}
