# Runehood contracts

Solidity sources for the Runehood launchpad (shared engine): bonding-curve launchpads, Uniswap V4 tax hook, PancakeSwap variant, Bitcoin bridge and holder rewards.

- `src/CarvyLaunchpadV2.sol` – bonding curve, graduation into a Uniswap V4 pool with locked LP (ETH, Base, Robinhood Chain)
- `src/CarvyHook.sol` – V4 hook for the creator buy/sell tax (max 5%)
- `src/CarvyLaunchpadPancake.sol`, `src/CarvyRuneTokenTax.sol` – BNB Chain variant graduating into PancakeSwap V2
- `src/CarvyBridge.sol` – 1:1 bridge between the chain token and the Bitcoin Rune
- `src/CarvyHolderRewards.sol` – Merkle cumulative claims for Holders fee mode
- `stock-quotes-rh.json` – Robinhood Stock Tokens enabled as pairs on the Robinhood Chain launchpad

## Build

```bash
forge install Uniswap/v4-periphery@9969eec --no-git
forge build
forge test --no-match-contract Fork        # unit tests
RPC_ROBINHOOD=<rpc> forge test --match-contract StockQuoteForkTest   # fork test on live Robinhood Chain contracts
```

Deploy scripts read the deployer key from a local, git-ignored file. Never commit keys.

## Live deployments (Robinhood Chain)

- Launchpad: `0x0A1Ff578b7D1Fa9844E26DE415dF7319447bc4Ce`
- Bridge: `0x48C106bd1CB291e952937053e590D0B318F3Ad85`
- Holder rewards: `0xb1b47F59EE240e45f980098d56Db30FeFce21EF2`
- RunehoodZap (buy/sell stock-paired Runes with ETH): `0xdF14e44557a6DBF4f7856a952872B30aB7541FfD`
