// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, stdJson, console2} from "forge-std/Script.sol";

/**
 * @notice Sends native from L1 gateway and relays it to L2 bridge in one run.
 * @dev Uses cast via FFI for cross-chain execution (same pattern as SetupBridge.s.sol).
 *
 * Required env:
 * - PRIVATE_KEY   : relayer/sender private key (must have L2 bridge RELAYER_ROLE)
 * - L1_RPC_URL    : source RPC (e.g. Sepolia)
 * - L2_RPC_URL    : destination RPC (e.g. Fluent Devnet)
 * - L1_GATEWAY    : PaymentGateway on source chain
 * - L2_BRIDGE     : FluentBridge on destination chain
 * - RECIPIENT     : recipient address on destination chain
 *
 * Optional env:
 * - AMOUNT_WEI    : transfer amount in wei (default: 1e15 = 0.001 ETH)
 */
contract SendAndReceiveNative is Script {
    using stdJson for string;

    struct FlowConfig {
        string privateKey;
        string l1Rpc;
        string l2Rpc;
        address l1Gateway;
        address l2Bridge;
        address recipient;
        uint256 amountWei;
        address sender;
        address l1Bridge;
        address l2Gateway;
        uint256 l1ChainId;
    }

    function run() external {
        FlowConfig memory cfg = _loadConfig();
        uint256 nonceBefore = _callUint(cfg.l1Rpc, cfg.l1Bridge, "nonce()(uint256)");
        uint256 beforeL2 = _balance(cfg.l2Rpc, cfg.recipient);

        console2.log("sender", cfg.sender);
        console2.log("recipient", cfg.recipient);
        console2.log("nonce", nonceBefore);

        uint256 sourceBlockNumber = _sendNativeAndGetBlock(cfg);
        string memory message = _calldataReceiveNative(cfg.sender, cfg.recipient, cfg.amountWei);
        _relayL2(
            cfg.l2Rpc,
            cfg.privateKey,
            cfg.l2Bridge,
            cfg.l1Gateway,
            cfg.l2Gateway,
            cfg.amountWei,
            cfg.l1ChainId,
            sourceBlockNumber,
            nonceBefore,
            message
        );

        uint256 afterL2 = _balance(cfg.l2Rpc, cfg.recipient);
        uint256 delta = afterL2 >= beforeL2 ? afterL2 - beforeL2 : 0;
        console2.log("before_l2", beforeL2);
        console2.log("after_l2", afterL2);
        console2.log("delta", delta);

        // If recipient differs from sender, destination balance should increase exactly by amount.
        if (cfg.recipient != cfg.sender) {
            require(afterL2 >= beforeL2, "recipient balance decreased");
            require(delta == cfg.amountWei, "recipient delta mismatch");
        } else {
            // When recipient is sender, L2 relay gas can offset the credited amount.
            require(afterL2 >= beforeL2, "recipient balance did not increase");
        }
    }

    function _loadConfig() internal returns (FlowConfig memory cfg) {
        cfg.privateKey = vm.envString("PRIVATE_KEY");
        cfg.l1Rpc = vm.envString("L1_RPC_URL");
        cfg.l2Rpc = vm.envString("L2_RPC_URL");
        cfg.l1Gateway = vm.envAddress("L1_GATEWAY");
        cfg.l2Bridge = vm.envAddress("L2_BRIDGE");
        cfg.recipient = vm.envAddress("RECIPIENT");
        cfg.amountWei = vm.envOr("AMOUNT_WEI", uint256(1e15));

        require(bytes(cfg.privateKey).length != 0, "PRIVATE_KEY required");
        require(bytes(cfg.l1Rpc).length != 0 && bytes(cfg.l2Rpc).length != 0, "RPC required");
        require(cfg.l1Gateway != address(0) && cfg.l2Bridge != address(0) && cfg.recipient != address(0), "address required");
        require(cfg.amountWei > 0, "AMOUNT_WEI must be > 0");

        cfg.sender = _walletAddress(cfg.privateKey);
        cfg.l1Bridge = _callAddress(cfg.l1Rpc, cfg.l1Gateway, "bridgeContract()(address)");
        cfg.l2Gateway = _callAddress(cfg.l1Rpc, cfg.l1Gateway, "otherSide()(address)");
        cfg.l1ChainId = _chainId(cfg.l1Rpc);
    }

    function _sendNativeAndGetBlock(FlowConfig memory cfg) internal returns (uint256) {
        string memory sendReceipt = _sendL1(cfg.l1Rpc, cfg.privateKey, cfg.l1Gateway, cfg.recipient, cfg.amountWei);
        return _jsonUint(sendReceipt, ".blockNumber");
    }

    function _sendL1(string memory rpc, string memory pk, address gateway, address recipient, uint256 amount) internal returns (string memory) {
        string[] memory cmd = new string[](13);
        cmd[0] = "cast";
        cmd[1] = "send";
        cmd[2] = vm.toString(gateway);
        cmd[3] = "sendNativeTokens(address)";
        cmd[4] = vm.toString(recipient);
        cmd[5] = "--value";
        cmd[6] = vm.toString(amount);
        cmd[7] = "--rpc-url";
        cmd[8] = rpc;
        cmd[9] = "--private-key";
        cmd[10] = pk;
        cmd[11] = "--legacy";
        cmd[12] = "--json";
        return string(vm.ffi(cmd));
    }

    function _relayL2(
        string memory rpc,
        string memory pk,
        address bridge,
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 nonce,
        string memory message
    ) internal {
        string[] memory cmd = new string[](19);
        cmd[0] = "cast";
        cmd[1] = "send";
        cmd[2] = vm.toString(bridge);
        cmd[3] = "receiveMessage(address,address,uint256,uint256,uint256,uint256,bytes)";
        cmd[4] = vm.toString(from);
        cmd[5] = vm.toString(to);
        cmd[6] = vm.toString(value);
        cmd[7] = vm.toString(chainId);
        cmd[8] = vm.toString(blockNumber);
        cmd[9] = vm.toString(nonce);
        cmd[10] = message;
        cmd[11] = "--rpc-url";
        cmd[12] = rpc;
        cmd[13] = "--private-key";
        cmd[14] = pk;
        cmd[15] = "--legacy";
        cmd[16] = "--json";
        cmd[17] = "--gas-limit";
        cmd[18] = "500000";
        vm.ffi(cmd);
    }

    function _callAddress(string memory rpc, address to, string memory sig) internal returns (address) {
        string[] memory cmd = new string[](6);
        cmd[0] = "cast";
        cmd[1] = "call";
        cmd[2] = vm.toString(to);
        cmd[3] = sig;
        cmd[4] = "--rpc-url";
        cmd[5] = rpc;
        return _stringToAddress(string(vm.ffi(cmd)));
    }

    function _callUint(string memory rpc, address to, string memory sig) internal returns (uint256) {
        string[] memory cmd = new string[](6);
        cmd[0] = "cast";
        cmd[1] = "call";
        cmd[2] = vm.toString(to);
        cmd[3] = sig;
        cmd[4] = "--rpc-url";
        cmd[5] = rpc;
        return vm.parseUint(_trim(string(vm.ffi(cmd))));
    }

    function _walletAddress(string memory /*pk*/ ) internal returns (address) {
        return _stringToAddress(_bash("cast wallet address --private-key \"$PRIVATE_KEY\""));
    }

    function _balance(string memory rpc, address who) internal returns (uint256) {
        string[] memory cmd = new string[](5);
        cmd[0] = "cast";
        cmd[1] = "balance";
        cmd[2] = vm.toString(who);
        cmd[3] = "--rpc-url";
        cmd[4] = rpc;
        return vm.parseUint(_trim(string(vm.ffi(cmd))));
    }

    function _chainId(string memory rpc) internal returns (uint256) {
        string[] memory cmd = new string[](4);
        cmd[0] = "cast";
        cmd[1] = "chain-id";
        cmd[2] = "--rpc-url";
        cmd[3] = rpc;
        return vm.parseUint(_trim(string(vm.ffi(cmd))));
    }

    function _calldataReceiveNative(address from, address to, uint256 amount) internal returns (string memory) {
        string[] memory cmd = new string[](6);
        cmd[0] = "cast";
        cmd[1] = "calldata";
        cmd[2] = "receiveNativeTokens(address,address,uint256)";
        cmd[3] = vm.toString(from);
        cmd[4] = vm.toString(to);
        cmd[5] = vm.toString(amount);
        return string(vm.ffi(cmd));
    }

    function _jsonUint(string memory json, string memory path) internal view returns (uint256) {
        return json.readUint(path);
    }

    function _trim(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 start = 0;
        while (start < b.length && (b[start] == 0x20 || b[start] == 0x0a || b[start] == 0x09 || b[start] == 0x0d)) start++;
        uint256 end = b.length;
        while (end > start && (b[end - 1] == 0x20 || b[end - 1] == 0x0a || b[end - 1] == 0x09 || b[end - 1] == 0x0d)) end--;
        bytes memory out = new bytes(end - start);
        for (uint256 i = 0; i < out.length; i++) out[i] = b[start + i];
        return string(out);
    }

    function _bash(string memory command) internal returns (string memory) {
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-lc";
        cmd[2] = command;
        return string(vm.ffi(cmd));
    }

    function _stringToAddress(string memory s) internal view returns (address) {
        return vm.parseAddress(_extractHexAddress(s));
    }

    function _extractHexAddress(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 i = 0;
        bool found = false;
        while (i + 1 < b.length) {
            if (b[i] == 0x30 && (b[i + 1] == 0x78 || b[i + 1] == 0x58)) {
                found = true;
                break;
            }
            i++;
        }
        require(found && i + 41 < b.length, "address parse failed");
        bytes memory out = new bytes(42);
        for (uint256 j = 0; j < 42; j++) {
            out[j] = b[i + j];
        }
        return string(out);
    }
}
