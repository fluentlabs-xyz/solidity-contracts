// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {L1HypNativeGateway} from "../../contracts/gateways/L1HypNativeGateway.sol";

/**
 * @notice Admin op: register or update the per-domain Hyperlane warp route on L1HypNativeGateway.
 * @dev Required env: GATEWAY (L1HypNativeGateway proxy), DOMAIN (Hyperlane domain ID), WARP_ROUTE.
 *      Pass WARP_ROUTE=0x000...000 to clear the route (subsequent dispatches revert with UnsupportedDomain).
 */
contract SetHypWarpRoute is Script {
    function run() external {
        address gateway = vm.envAddress("GATEWAY");
        uint256 domainRaw = vm.envUint("DOMAIN");
        address warpRoute = vm.envAddress("WARP_ROUTE");

        require(gateway.code.length > 0, "GATEWAY has no code");
        require(domainRaw <= type(uint32).max, "DOMAIN exceeds uint32");
        uint32 domain = uint32(domainRaw);

        console2.log("Setting warp route");
        console2.log("  gateway:", gateway);
        console2.log("  domain:", domain);
        console2.log("  warpRoute:", warpRoute);

        vm.startBroadcast();
        L1HypNativeGateway(payable(gateway)).setWarpRoute(domain, warpRoute);
        vm.stopBroadcast();

        console2.log("Warp route updated");
    }
}
