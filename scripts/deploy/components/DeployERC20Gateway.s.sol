// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {DeployLib} from "./DeployLib.s.sol";
import {ERC20TokenFactory} from "../../../contracts/factories/ERC20TokenFactory.sol";
import {UniversalTokenFactory} from "../../../contracts/factories/UniversalTokenFactory.sol";

/**
 * @notice Deployment script for ERC20Gateway (impl + proxy). Links gateway to factory via setPaymentGateway.
 * @dev Environment: INITIAL_OWNER (address), BRIDGE_ADDRESS (address), FACTORY_ADDRESS (address), OUTPUT_PATH (string, optional).
 *      FACTORY_ADDRESS can be ERC20TokenFactory or UniversalTokenFactory proxy.
 */
contract DeployERC20Gateway is DeployLib {
    function run() external returns (address gateway) {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address bridgeAddress = vm.envAddress("BRIDGE_ADDRESS");
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        vm.startBroadcast();
        ERC20GatewayResult memory r = _deployERC20Gateway(initialOwner, bridgeAddress, factoryAddress);
        _setPaymentGatewayOnFactory(factoryAddress, r.gateway);
        vm.stopBroadcast();

        gateway = r.gateway;
        if (bytes(outputPath).length != 0) {
            string memory json = vm.serializeAddress("deployment", "gateway_impl", r.gatewayImpl);
            json = vm.serializeAddress("deployment", "gateway", r.gateway);
            vm.writeJson(json, outputPath);
        }
    }

    function _setPaymentGatewayOnFactory(address factoryAddress, address gateway) internal {
        if (factoryAddress.code.length == 0) return; // skip when factory is EOA or not deployed (e.g. random params)
        try ERC20TokenFactory(factoryAddress).setPaymentGateway(gateway) {} catch {}
        try UniversalTokenFactory(factoryAddress).setPaymentGateway(gateway) {} catch {}
    }
}
