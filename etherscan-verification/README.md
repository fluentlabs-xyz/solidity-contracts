# Manual Etherscan verification (Sepolia)

**Compiler:** Solidity 0.8.30, Optimization **Enabled**, **200** runs.

## Single-file (ready to paste)

- **L1BlockOracle** → use `SEPOLIA_L1BlockOracle.sol` in this folder.  
On [Sepolia Etherscan](https://sepolia.etherscan.io/address/0x49526bf0CD5aD66104d091Be707F7C22E361c6Bc#code): Verify & Publish → Solidity (Single file) → paste the file. Constructor arguments: none.

## Other contracts (flatten then paste)

Generate flattened source, then verify each contract on Sepolia with “Solidity (Single file)” and the listed constructor args.


| Contract                     | Address                                      | Flatten command                                                                                 | Constructor arguments (ABI-encoded if needed)                                                            |
| ---------------------------- | -------------------------------------------- | ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| **ERC20PeggedToken** (impl)  | `0x5c96D66842687EB3e3d9b658c8E0636F78DE7F66` | `npx hardhat flatten contracts/tokens/ERC20PeggedToken.sol 2>/dev/null | tail -n +2`            | None                                                                                                     |
| **MockERC20Token**           | `0xE09CAC803c4a99FB94C891f64663B5656b2F261d` | `npx hardhat flatten contracts/mocks/MockERC20.sol 2>/dev/null | tail -n +2`                    | `"Mock Deposit Token", "MDT", "1000000000000000000000000", "0x1C92DffBCe76670F69007F22A54e31ff3Ab45d5E"` |
| **ERC20TokenFactory** (impl) | `0x02fbb71ce3ae194029df08dc00b5dc974df01d4f` | `npx hardhat flatten contracts/factories/ERC20TokenFactory.sol 2>/dev/null | tail -n +2`        | None                                                                                                     |
| **FluentBridge** (impl)      | `0x09e3882a9d98967b8dfd007885530c8906e2aa0a` | Cyclic deps: use Standard JSON or try `npx hardhat flatten contracts/FluentBridge.sol`          | None                                                                                                     |
| **ERC20Gateway** (impl)      | `0x45cfcaeb9ef3876aa8dd9e7ae9098fe75c16c820` | Cyclic deps: use Standard JSON or try `npx hardhat flatten contracts/gateways/ERC20Gateway.sol` | None                                                                                                     |


**Proxy contracts** (verify implementation first, then use “Verify Proxy” on the proxy page):

- FluentBridge proxy: `0xe0Cf1dFAF870517876e48102A50248CcA8F6eA27` → impl above
- ERC20TokenFactory proxy: `0xD75dB0Dfac9Ca3B4aF7005220f1fDFC0daa960C9` → impl above
- ERC20Gateway proxy: `0xf4c45A9A69ebEC331b89a4d24b7903A8F2651F5B` → impl above

