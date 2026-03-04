// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IRestakerFacets.sol";

interface IRestaker {
    error RestakerCannotClaim();

    event Claimed(address indexed recipient, uint256 amount);

    function initialize(address owner, IRestakerFacets facets) external;
    function __claim() external;
}
