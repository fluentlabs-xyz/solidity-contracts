# Deployed Bridge Addresses

Current deployment: **Sepolia (L1)** ↔ **Fluent testnet (L2)**.

Source: `deployments/testnet/l1.json`, `deployments/testnet/l2.json`.

---

## Sepolia (L1)

| Contract | Address |
|----------|---------|
| **NitroVerifier** | `0x31b6A225FD96770a59b9d6A63973DE1C881B393d` |
| **Rollup** (proxy) | `0x30998EE150e669ed3761F80dda435CaaA6bf5032` |
| Rollup (impl) | `0xaA2a73D5158aCdFbd73c6A26f286a8E9a9c0766a` |
| **L1FluentBridge** (proxy) | `0x94A1454943FCf5C88C270F7B7cE3D2F23fc84FCf` |
| L1FluentBridge (impl) | `0x7CB564503A7445e8C24D8495c141E8dB18f9b556` |
| **ERC20TokenFactory** (proxy) | `0x72ef90575Dd90b6f22e3faED2CFA0AA8e8Ee7DBa` |
| ERC20TokenFactory (impl) | `0xBa2D7Ac3D0bC97F38Fa6a8119845c1F20F41E45e` |
| UpgradeableBeacon | `0x0749709b37FDE16B8eAB94e247F76E30c58AC72b` |
| ERC20PeggedToken (impl) | `0x8B149688869e25d713A8f409DB62dDC0b7a2FF88` |
| **ERC20Gateway** (proxy) | `0xbA1d2D76184127fD289D46bB2a721B8D6339372D` |
| ERC20Gateway (impl) | `0x3F17fC9C8a7FDd92dbDBF821a651EBcfffA6ddaB` |
| **NativeGateway** (proxy) | `0x1a2B1cCb1bE6789eF5878f8d65998e5CA7e0393F` |
| NativeGateway (impl) | `0x7A18D9d23b4316EAD042cbDDca92fDf4a8D09B6F` |
| MockERC20 (test token) | `0xE47b61EeFa9a4019b2CE699920BE91092b5bda39` |

- **Chain ID:** 11155111
- **RPC:** https://ethereum-sepolia-rpc.publicnode.com
- **Explorer:** https://sepolia.etherscan.io

---

## Fluent testnet (L2)

| Contract | Address |
|----------|---------|
| **L1BlockOracle** | `0xBFbeEC28d16c227453dEc576120F006c258FDDaC` |
| **L2FluentBridge** (proxy) | `0x22BC1D0b22CD5C2696c4a05Deaeb18c91226B37A` |
| L2FluentBridge (impl) | `0x6317faa6389184308903A81b4989F88aBB044A4F` |
| **UniversalTokenFactory** (proxy) | `0x67AF4912A5A8f8ec31D840bdE9E76276DDEFAD6b` |
| UniversalTokenFactory (impl) | `0x7FaE25a23237C2B6e28b02Cf8567982a6503e528` |
| **ERC20Gateway** (proxy) | `0xEd7E1E435B64f61FBD975e1e909aB37a6d3c2092` |
| ERC20Gateway (impl) | `0xeDeA99d586a5d536d3a64e491FCc58ed65E37F5B` |
| **NativeGateway** (proxy) | `0x990568FfaDddBDBF614ff1EA0eF5630BD8957Ddc` |
| NativeGateway (impl) | `0x5d88CD642b160477A2A7B121edF8338dff6B59b3` |
| Pegged token (precompile) | `0x0000000000000000000000000000000000520008` |

- **Chain ID:** 20994
- **RPC:** https://rpc.testnet.fluent.xyz/
- **Explorer:** https://testnet.fluentscan.xyz/

---

## JSON sources

- **L1:** `deployments/testnet/l1.json`
- **L2:** `deployments/testnet/l2.json`

---

## Governance (per chain)

| Contract | L1 Address | L2 Address |
|----------|-----------|-----------|
| Gnosis Safe | TBD | TBD |
| Normal Timelock (24h) | TBD | TBD |
| Emergency Timelock (1min) | TBD | TBD |
