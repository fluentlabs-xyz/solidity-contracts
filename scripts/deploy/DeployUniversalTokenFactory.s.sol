// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseScript} from "../Base.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployUniversalTokenFactory is BaseScript {
    struct Deployment {
        address factoryImpl;
        address factory;
    }

    event UniversalTokenFactoryDeployed(address indexed implementation, address indexed proxy);

    function run() external returns (address factoryProxy) {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        vm.startBroadcast();

        UniversalTokenFactory factoryImpl = new UniversalTokenFactory();
        ERC1967Proxy factoryProxyContract =
            new ERC1967Proxy(address(factoryImpl), abi.encodeCall(UniversalTokenFactory.initialize, (initialOwner)));

        vm.stopBroadcast();

        factoryProxy = address(factoryProxyContract);
        emit UniversalTokenFactoryDeployed(address(factoryImpl), factoryProxy);

        if (bytes(outputPath).length != 0) {
            Deployment memory deployed = Deployment({factoryImpl: address(factoryImpl), factory: factoryProxy});
            _writeOutput(outputPath, deployed);
        }
    }

    function _writeOutput(string memory outputPath, Deployment memory deployed) internal {
        string memory json = vm.serializeAddress("deployment", "factory_impl", deployed.factoryImpl);
        json = vm.serializeAddress("deployment", "factory", deployed.factory);
        vm.writeJson(json, outputPath);
    }
}
