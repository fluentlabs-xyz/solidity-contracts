// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {L1HypNativeGateway} from "../../contracts/gateways/L1HypNativeGateway.sol";

/**
 * @notice Admin op: set the Hyperlane warp route on L1HypNativeGateway. Single source of
 *         truth — same address is used for outbound dispatch AND inbound caller-auth.
 * @dev Required env: GATEWAY (L1HypNativeGateway proxy), WARP_ROUTE (the L1FluentHypNative
 *      proxy address). Zero address is rejected on-chain (`ZeroAddressNotAllowed`).
 */
contract SetHypWarpRoute is Script {
    function run() external {
        address gateway = vm.envAddress("GATEWAY");
        address warpRoute = vm.envAddress("WARP_ROUTE");

        require(gateway.code.length > 0, "GATEWAY has no code");
        require(warpRoute.code.length > 0, "WARP_ROUTE has no code");

        console2.log("Setting warp route");
        console2.log("  gateway:", gateway);
        console2.log("  warpRoute:", warpRoute);

        vm.startBroadcast();
        L1HypNativeGateway(payable(gateway)).setWarpRoute(warpRoute);
        vm.stopBroadcast();

        console2.log("Warp route updated");
    }
}
