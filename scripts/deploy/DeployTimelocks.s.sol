// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {FluentTimeLock} from "../../contracts/governance/FluentTimeLock.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys two FluentTimeLock instances: normal (long delay) + emergency (short delay).
/// @dev Both timelocks are deployed with minDelay=0 for migration. Use MigrateRoles to set target delays.
contract DeployTimelocks is DeployBase {
    using stdJson for string;

    struct TimelockResult {
        address normalTimelock;
        address emergencyTimelock;
    }

    function _deployTimelocks(address safe) internal returns (TimelockResult memory r) {
        require(safe != address(0), "SAFE address required");

        address[] memory operators = new address[](1);
        operators[0] = safe;

        r.normalTimelock = address(new FluentTimeLock(0, operators, operators));
        r.emergencyTimelock = address(new FluentTimeLock(0, operators, operators));
    }

    function run() external virtual {
        string memory json = _readConfig(vm.envOr("NETWORK", string("testnet/l1")));
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));
        address safe = vm.envOr("SAFE_ADDRESS", json.readAddress(".timelock.safe"));

        require(safe != address(0), "SAFE_ADDRESS required");

        console2.log("Deploying timelocks");
        console2.log("  safe:", safe);

        vm.startBroadcast();
        TimelockResult memory r = _deployTimelocks(safe);
        vm.stopBroadcast();

        console2.log("Normal timelock:", r.normalTimelock);
        console2.log("Emergency timelock:", r.emergencyTimelock);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "normal_timelock", r.normalTimelock);
            out = vm.serializeAddress("deployment", "emergency_timelock", r.emergencyTimelock);
            vm.writeJson(out, outputPath);
        }
    }
}
