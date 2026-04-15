// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2, stdJson} from "forge-std/Script.sol";

import {DeployBase} from "../deploy/DeployBase.s.sol";

import {IFluentBridge, IFluentBridgeRead} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IL1FluentBridge} from "../../contracts/interfaces/bridge/IL1FluentBridge.sol";
import {IL2FluentBridge} from "../../contracts/interfaces/bridge/IL2FluentBridge.sol";
import {IGenericTokenFactory} from "../../contracts/interfaces/IGenericTokenFactory.sol";
import {IGatewayBase} from "../../contracts/interfaces/gateways/IGatewayBase.sol";
import {GenericTokenFactory} from "../../contracts/factories/GenericTokenFactory.sol";

/// @notice L2 bridge views not declared on {IL2FluentBridge}.
interface IL2FluentBridgeSnapshot is IL2FluentBridge {
    function getL1GasPriceOracle() external view returns (address);

    function getGasPriceConfig() external view returns (uint256 overhead, uint256 scalar, uint256 l1GasLimit);

    function getL1GasLimit() external view returns (uint256);
}

/// @notice ERC20 gateway layout views (token factory + remote CREATE2 params).
interface IERC20GatewaySnapshot {
    function getTokenFactory() external view returns (address);

    function getOtherSideTokenImplementation() external view returns (address);

    function getOtherSideFactory() external view returns (address);

    function getOtherSideBeacon() external view returns (address);

    function getBridgeContract() external view returns (address);
}

interface IOwnableSnapshot {
    function owner() external view returns (address);

    function pendingOwner() external view returns (address);
}

interface IPausableSnapshot {
    function paused() external view returns (bool);
}

/// @notice Prints a logical “storage snapshot” via public getters for Fluent bridge, gateways, and token factory.
/// @dev Run against the target chain (live RPC or fork). No transactions are broadcast.
///      Uses try/catch so an ABI mismatch on one getter still prints the rest.
///
/// Environment:
/// - `ENV` (default `testnet`) + `LAYER` (`l1` or `l2`) → `deployments/<ENV>/<LAYER>.json`
/// - or `MANIFEST_PATH` to override the JSON path
/// - optional `SNAPSHOT_SCOPE`: `all` | `bridge` | `gateways` | `factories` (default `all`)
contract SnapshotFluentStorage is DeployBase {
    using stdJson for string;

    function run() external {
        string memory path = _manifestPath();
        string memory json = vm.readFile(path);
        string memory scope = vm.envOr("SNAPSHOT_SCOPE", string("all"));

        console2.log("SnapshotFluentStorage");
        console2.log("  manifest:", path);
        console2.log("  scope:", scope);

        if (_eq(scope, "all") || _eq(scope, "bridge")) {
            _snapshotBridge(json, path);
        }
        if (_eq(scope, "all") || _eq(scope, "gateways")) {
            _snapshotGateways(json, _readAddr(json, "bridge"));
        }
        if (_eq(scope, "all") || _eq(scope, "factories")) {
            _snapshotFactories(json);
        }
    }

    function _snapshotBridge(string memory json, string memory path) internal {
        address bridge = _readAddr(json, "bridge");
        console2.log("");
        console2.log("=== FluentBridge (proxy) ===");
        console2.log("  address:", bridge);
        if (bridge.code.length == 0) {
            console2.log("  SKIP: no code at bridge");
            return;
        }

        try IPausableSnapshot(bridge).paused() returns (bool p) {
            console2.log("  paused:", p);
        } catch {
            console2.log("  paused: <reverted>");
        }

        try IFluentBridgeRead(bridge).getExecuteGasLimit() returns (uint256 v) {
            console2.log("  getExecuteGasLimit:", v);
        } catch {
            console2.log("  getExecuteGasLimit: <reverted>");
        }

        try IFluentBridgeRead(bridge).getOtherBridge() returns (address v) {
            console2.log("  getOtherBridge:", v);
        } catch {
            console2.log("  getOtherBridge: <reverted>");
        }

        try IFluentBridgeRead(bridge).getFeeTreasury() returns (address v) {
            console2.log("  getFeeTreasury:", v);
        } catch {
            console2.log("  getFeeTreasury: <reverted>");
        }

        try IFluentBridgeRead(bridge).getSentMessageFee() returns (uint256 v) {
            console2.log("  getSentMessageFee:", v);
        } catch {
            console2.log("  getSentMessageFee: <reverted>");
        }

        try IFluentBridge(bridge).getNonce() returns (uint256 v) {
            console2.log("  getNonce:", v);
        } catch {
            console2.log("  getNonce: <reverted>");
        }

        try IFluentBridge(bridge).getReceivedNonce() returns (uint256 v) {
            console2.log("  getReceivedNonce:", v);
        } catch {
            console2.log("  getReceivedNonce: <reverted>");
        }

        try IFluentBridge(bridge).getNativeSender() returns (address v) {
            console2.log("  getNativeSender:", v);
        } catch {
            console2.log("  getNativeSender: <reverted>");
        }

        if (_manifestIsL2(path)) {
            IL2FluentBridgeSnapshot l2b = IL2FluentBridgeSnapshot(bridge);

            try l2b.getL1BlockOracle() returns (address v) {
                console2.log("  [L2] getL1BlockOracle:", v);
            } catch {
                console2.log("  [L2] getL1BlockOracle: <reverted>");
            }

            try l2b.getL1GasPriceOracle() returns (address v) {
                console2.log("  [L2] getL1GasPriceOracle:", v);
            } catch {
                console2.log("  [L2] getL1GasPriceOracle: <reverted>");
            }

            try l2b.getGasPriceConfig() returns (uint256 oh, uint256 sc, uint256 lim) {
                console2.log("  [L2] gasPriceConfig overhead:", oh);
                console2.log("  [L2] gasPriceConfig scalar:", sc);
                console2.log("  [L2] gasPriceConfig l1GasLimit:", lim);
            } catch {
                console2.log("  [L2] getGasPriceConfig: <reverted>");
            }

            try l2b.getL1GasLimit() returns (uint256 v) {
                console2.log("  [L2] getL1GasLimit:", v);
            } catch {
                console2.log("  [L2] getL1GasLimit: <reverted>");
            }

            address manifestL1Block = _readAddr(json, "l1_block_oracle");
            address manifestL1Gas = _readAddr(json, "l1_gas_oracle");
            if (manifestL1Block != address(0)) {
                console2.log("  manifest l1_block_oracle:", manifestL1Block);
                try l2b.getL1BlockOracle() returns (address onChain) {
                    if (onChain != manifestL1Block) {
                        console2.log("  WARN: manifest l1_block_oracle != on-chain getL1BlockOracle");
                    }
                } catch {}
            }
            if (manifestL1Gas != address(0)) {
                console2.log("  manifest l1_gas_oracle:", manifestL1Gas);
                try l2b.getL1GasPriceOracle() returns (address onChain) {
                    if (onChain != manifestL1Gas) {
                        console2.log("  WARN: manifest l1_gas_oracle != on-chain getL1GasPriceOracle");
                    }
                } catch {}
            }
        } else {
            IL1FluentBridge l1b = IL1FluentBridge(bridge);

            try l1b.getRollup() returns (address v) {
                console2.log("  [L1] getRollup:", v);
            } catch {
                console2.log("  [L1] getRollup: <reverted>");
            }

            try l1b.getReceiveMessageDeadline() returns (uint256 v) {
                console2.log("  [L1] getReceiveMessageDeadline:", v);
            } catch {
                console2.log("  [L1] getReceiveMessageDeadline: <reverted>");
            }

            try l1b.getDepositProcessingWindow() returns (uint64 v) {
                console2.log("  [L1] getDepositProcessingWindow:", uint256(v));
            } catch {
                console2.log("  [L1] getDepositProcessingWindow: <reverted>");
            }

            try l1b.getSentMessageCursor() returns (uint64 v) {
                console2.log("  [L1] getSentMessageCursor:", uint256(v));
            } catch {
                console2.log("  [L1] getSentMessageCursor: <reverted>");
            }

            try l1b.getSentMessageQueueSize() returns (uint64 v) {
                console2.log("  [L1] getSentMessageQueueSize:", uint256(v));
            } catch {
                console2.log("  [L1] getSentMessageQueueSize: <reverted>");
            }

            address manifestRollup = _readAddr(json, "rollup");
            if (manifestRollup != address(0)) {
                try l1b.getRollup() returns (address onChain) {
                    if (onChain != manifestRollup) {
                        console2.log("  WARN: manifest rollup != on-chain getRollup");
                    }
                } catch {}
            }
        }
    }

    function _snapshotGateways(string memory json, address manifestBridge) internal {
        console2.log("");
        console2.log("=== Gateways ===");

        _snapshotOneGateway("native_gateway", _readAddr(json, "native_gateway"), manifestBridge);
        address erc20 = _readAddr(json, "erc20_gateway");
        _snapshotOneGateway("erc20_gateway", erc20, manifestBridge);
        _snapshotErc20GatewayExtras("erc20_gateway", erc20);
    }

    function _snapshotOneGateway(string memory label, address gw, address manifestBridge) internal {
        console2.log("");
        console2.log("---", label, "---");
        console2.log("  address:", gw);
        if (gw.code.length == 0) {
            console2.log("  SKIP: no code");
            return;
        }

        IGatewayBase g = IGatewayBase(gw);

        try IOwnableSnapshot(gw).owner() returns (address v) {
            console2.log("  owner:", v);
        } catch {
            console2.log("  owner: <reverted>");
        }

        try IOwnableSnapshot(gw).pendingOwner() returns (address v) {
            console2.log("  pendingOwner:", v);
        } catch {
            console2.log("  pendingOwner: <reverted>");
        }

        try g.getBridgeContract() returns (address v) {
            console2.log("  getBridgeContract:", v);
        } catch {
            console2.log("  getBridgeContract: <reverted>");
        }

        try g.getOtherSideGateway() returns (address v) {
            console2.log("  getOtherSideGateway:", v);
        } catch {
            console2.log("  getOtherSideGateway: <reverted>");
        }

        try g.getOtherSideChainId() returns (uint256 v) {
            console2.log("  getOtherSideChainId:", v);
        } catch {
            console2.log("  getOtherSideChainId: <reverted>");
        }

        try g.getBlacklistRegistry() returns (address v) {
            console2.log("  getBlacklistRegistry:", v);
        } catch {
            console2.log("  getBlacklistRegistry: <reverted>");
        }

        if (manifestBridge != address(0)) {
            try g.getBridgeContract() returns (address onChain) {
                if (onChain != manifestBridge) {
                    console2.log("  WARN: manifest bridge != gateway getBridgeContract");
                }
            } catch {}
        }
    }

    function _snapshotErc20GatewayExtras(string memory label, address gw) internal {
        console2.log("");
        console2.log("---", label, "(ERC20-specific) ---");
        console2.log("  address:", gw);
        if (gw.code.length == 0) {
            console2.log("  SKIP: no code");
            return;
        }

        IERC20GatewaySnapshot e = IERC20GatewaySnapshot(gw);

        try e.getTokenFactory() returns (address v) {
            console2.log("  getTokenFactory:", v);
        } catch {
            console2.log("  getTokenFactory: <reverted>");
        }

        try e.getOtherSideTokenImplementation() returns (address v) {
            console2.log("  getOtherSideTokenImplementation:", v);
        } catch {
            console2.log("  getOtherSideTokenImplementation: <reverted>");
        }

        try e.getOtherSideFactory() returns (address v) {
            console2.log("  getOtherSideFactory:", v);
        } catch {
            console2.log("  getOtherSideFactory: <reverted>");
        }

        try e.getOtherSideBeacon() returns (address v) {
            console2.log("  getOtherSideBeacon:", v);
        } catch {
            console2.log("  getOtherSideBeacon: <reverted>");
        }
    }

    function _snapshotFactories(string memory json) internal {
        address factory = _readAddr(json, "factory");
        console2.log("");
        console2.log("=== Generic token factory (proxy) ===");
        console2.log("  address:", factory);
        if (factory.code.length == 0) {
            console2.log("  SKIP: no code");
            return;
        }

        GenericTokenFactory f = GenericTokenFactory(factory);
        IGenericTokenFactory ig = IGenericTokenFactory(factory);

        try IOwnableSnapshot(factory).owner() returns (address v) {
            console2.log("  owner:", v);
        } catch {
            console2.log("  owner: <reverted>");
        }

        try IOwnableSnapshot(factory).pendingOwner() returns (address v) {
            console2.log("  pendingOwner:", v);
        } catch {
            console2.log("  pendingOwner: <reverted>");
        }

        try ig.beacon() returns (address v) {
            console2.log("  beacon:", v);
        } catch {
            console2.log("  beacon: <reverted>");
        }

        try f.paymentGateway() returns (address v) {
            console2.log("  paymentGateway:", v);
        } catch {
            console2.log("  paymentGateway: <reverted>");
        }

        try f.implementation() returns (address v) {
            console2.log("  implementation (beacon target):", v);
        } catch {
            console2.log("  implementation: <reverted>");
        }

        address manifestBeacon = _readAddr(json, "factory_beacon");
        if (manifestBeacon != address(0)) {
            try ig.beacon() returns (address onChain) {
                if (onChain != manifestBeacon) {
                    console2.log("  WARN: manifest factory_beacon != on-chain beacon()");
                }
            } catch {}
        }

        address manifestPegged = _readAddr(json, "pegged_impl");
        if (manifestPegged != address(0)) {
            try f.implementation() returns (address onChain) {
                if (onChain != manifestPegged) {
                    console2.log("  WARN: manifest pegged_impl != factory implementation()");
                }
            } catch {}
        }

        address manifestErc20Gw = _readAddr(json, "erc20_gateway");
        if (manifestErc20Gw != address(0)) {
            try f.paymentGateway() returns (address onChain) {
                if (onChain != manifestErc20Gw) {
                    console2.log("  NOTE: manifest erc20_gateway != factory paymentGateway (ok if intentional)");
                }
            } catch {}
        }
    }

    function _manifestPath() internal view returns (string memory) {
        string memory override_ = vm.envOr("MANIFEST_PATH", string(""));
        if (bytes(override_).length > 0) return override_;

        string memory env = vm.envOr("ENV", string("testnet"));
        string memory layer = vm.envString("LAYER");
        return string.concat("deployments/", env, "/", layer, ".json");
    }

    function _manifestIsL2(string memory path) internal pure returns (bool) {
        bytes memory b = bytes(path);
        if (b.length < 8) return false;
        return b[b.length - 8] == "/" && b[b.length - 7] == "l" && b[b.length - 6] == "2" && b[b.length - 5] == "."
            && b[b.length - 4] == "j" && b[b.length - 3] == "s" && b[b.length - 2] == "o" && b[b.length - 1] == "n";
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
