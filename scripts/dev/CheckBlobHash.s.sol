// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseScript} from "../Base.sol";
import {BlobHashMock} from "../../contracts/mocks/BlobHashMock.sol";

/// @notice Calls BlobHashMock.CheckBlobHash with a provided commitment to emit the blob/hash pair.
/// @dev Environment:
/// - BLOB_HASH_CONTRACT (address, required): BlobHashMock contract address
/// - COMMITMENT        (bytes, required): blob commitment bytes (e.g. KZG commitment)
contract CheckBlobHash is BaseScript {
    event Checked(bytes commitment);

    function run() external {
        address blobHashContract = vm.envAddress("BLOB_HASH_CONTRACT");
        bytes memory commitment = bytes(vm.envOr("COMMITMENT", string("")));
        require(commitment.length != 0, "COMMITMENT must be non-empty");

        BlobHashMock checker = BlobHashMock(blobHashContract);

        vm.startBroadcast();
        checker.CheckBlobHash(commitment);
        vm.stopBroadcast();

        emit Checked(commitment);
    }
}
