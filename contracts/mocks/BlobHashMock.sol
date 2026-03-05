// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import {BlobHashGetterDeployer, BlobHashGetter} from "../libraries/BlobHashGetter.sol";

contract BlobHashMock is BlobHashGetterDeployer {
    address public blobHashGetter;

    event BlobHash(bytes32 blobHash, bytes32 hash);

    constructor() {
        blobHashGetter = BlobHashGetterDeployer.deploy();
    }

    function CheckBlobHash(bytes memory commitment) public {
        bytes32 hash = sha256(commitment);

        hash &= 0x00ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
        hash |= 0x0100000000000000000000000000000000000000000000000000000000000000;

        bytes32 blob = BlobHashGetter.getBlobHash(blobHashGetter, 0);

        emit BlobHash(blob, hash);
    }
}
