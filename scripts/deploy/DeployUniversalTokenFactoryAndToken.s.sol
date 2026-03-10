// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseScript} from "../Base.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deploys a UniversalTokenFactory behind an ERC1967 proxy on Fluent Testnet and deploys a single Universal token via deployToken().
/// @dev Environment (required unless noted otherwise):
/// - INITIAL_OWNER           (address): owner of the UniversalTokenFactory
/// - ORIGIN_TOKEN            (address): L1 origin token address
/// - TOKEN_NAME              (string):  ERC20 name
/// - TOKEN_SYMBOL            (string):  ERC20 symbol
/// - TOKEN_DECIMALS          (uint256): decimals (e.g. 18)
/// - TOKEN_INITIAL_SUPPLY    (uint256): initial supply (in token units)
/// - MINTER                  (address): minter role for the Universal token
/// - PAUSER                  (address): pauser role for the Universal token
/// - OUTPUT_PATH             (string, optional): JSON path for deployment metadata
contract DeployUniversalTokenFactoryAndToken is BaseScript {
    struct Deployment {
        address factoryImpl;
        address factory;
        address token;
    }

    event UniversalTokenFactoryAndTokenDeployed(address indexed factoryImpl, address indexed factory, address indexed token);

    function run() external returns (Deployment memory deployed) {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address originToken = vm.envAddress("ORIGIN_TOKEN");

        string memory name = vm.envOr("TOKEN_NAME", string("Bridged Token"));
        string memory symbol = vm.envOr("TOKEN_SYMBOL", string("BRIDGE"));
        uint256 decimals = vm.envOr("TOKEN_DECIMALS", uint256(18));
        uint256 initialSupply = vm.envOr("TOKEN_INITIAL_SUPPLY", uint256(0));
        address minter = vm.envOr("MINTER", address(0));
        address pauser = vm.envOr("PAUSER", address(0));

        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        deployed = _deployAll(initialOwner, originToken, name, symbol, uint8(decimals), initialSupply, minter, pauser);

        emit UniversalTokenFactoryAndTokenDeployed(deployed.factoryImpl, deployed.factory, deployed.token);

        if (bytes(outputPath).length != 0) {
            _writeOutput(outputPath, deployed);
        }
    }

    function _deployAll(
        address initialOwner,
        address originToken,
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) internal returns (Deployment memory deployed) {
        vm.startBroadcast();

        // Deploy factory implementation + proxy (UUPS)
        UniversalTokenFactory factoryImpl = new UniversalTokenFactory();
        ERC1967Proxy factoryProxyContract = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(UniversalTokenFactory.initialize, (initialOwner))
        );

        UniversalTokenFactory factory = UniversalTokenFactory(address(factoryProxyContract));

        // Build keyData and deployArgs for deployToken()
        bytes memory keyData = abi.encode(originToken);
        bytes memory deployArgs =
            abi.encode(name, symbol, decimals, initialSupply, minter, pauser);

        address token = factory.deployToken(keyData, deployArgs);

        vm.stopBroadcast();

        deployed = Deployment({factoryImpl: address(factoryImpl), factory: address(factory), token: token});
    }

    function _writeOutput(string memory outputPath, Deployment memory deployed) internal {
        string memory json = vm.serializeAddress("deployment", "factory_impl", deployed.factoryImpl);
        json = vm.serializeAddress("deployment", "factory", deployed.factory);
        json = vm.serializeAddress("deployment", "token", deployed.token);
        vm.writeJson(json, outputPath);
    }
}

