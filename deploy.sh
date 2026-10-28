#!/bin/bash
# Deploy Carvy launchpad + bridge to one network.  Usage: bash deploy.sh <sepolia|basesep|rhtest|eth|base|rh>
set -e
cd "$(dirname "$0")"
export PATH=$HOME/.foundry/bin:$PATH
export PRIVATE_KEY=$(cat .deployer.key)
case "$1" in
  sepolia) RPC=https://ethereum-sepolia-rpc.publicnode.com; export ROUTER=0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3 ;;
  basesep) RPC=https://sepolia.base.org; export ROUTER=0x1689E7B1F10000AE47eBfE339a4f69dECd19F602 ;;
  rhtest)  RPC=https://rpc.testnet.chain.robinhood.com; export ROUTER=0x0000000000000000000000000000000000000000 ;;
  eth)     RPC=https://ethereum-rpc.publicnode.com; export ROUTER=0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
           export WBTC=0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 ;;
  base)    RPC=https://mainnet.base.org; export ROUTER=0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24
           export WBTC=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 ;;
  rh)      RPC=https://rpc.mainnet.chain.robinhood.com; export ROUTER=0x0000000000000000000000000000000000000000 ;;
  *) echo "network?"; exit 1 ;;
esac
forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast --slow 2>&1 | tee "deploy-$1.log" | grep -E "CarvyBridge|CarvyLaunchpad|Error|error" || true
