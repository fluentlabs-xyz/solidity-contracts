// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {DeployStaking} from "../deploy/DeployStaking.s.sol";

/// @notice Migration entrypoint for deploying staking contracts behind owner-controlled UUPS proxies.
contract MigrateStaking is DeployStaking {}
