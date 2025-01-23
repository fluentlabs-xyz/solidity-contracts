// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {WasmDeployerLib} from "./WasmDeployerLib.sol";

/**
 * @dev An example contract demonstrating the usage of the WasmDeployerLib for deploying WASM bytecode with constructor parameters.
 */
contract WasmDeployer {
    event Deployed(address addr);

    function deploy(bytes memory wasmBytecode, bytes memory constructorParams) public {
        address newContract = WasmDeployerLib.deploy(wasmBytecode, constructorParams);
        emit Deployed(newContract);
    }
}
