// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {CarvyLaunchpad, IUniswapV2Router02} from "../src/CarvyLaunchpad.sol";
import {CarvyBridge} from "../src/CarvyBridge.sol";

/// Env:
///  PRIVATE_KEY        deployer
///  OWNER              final owner (defaults to deployer; transfer later with Ownable2Step)
///  TREASURY / BUYBACK / HOLDERS   fee vaults (default deployer, changeable with setVaults)
///  BRIDGE_SIGNER      ICP canister threshold-ECDSA address (default deployer until the canister is live)
///  ROUTER             Uniswap V2 router (0x0 = manual migrateTo)
///  ETH_VIRTUAL        virtual ETH reserve in wei (default 1 ether)
///  WBTC, WBTC_VIRTUAL / USDC, USDC_VIRTUAL   optional ERC20 quotes (raw units)
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        address owner = vm.envOr("OWNER", me);
        address treasury = vm.envOr("TREASURY", me);
        address buyback = vm.envOr("BUYBACK", me);
        address holders = vm.envOr("HOLDERS", me);
        address signer = vm.envOr("BRIDGE_SIGNER", me);
        address router = vm.envOr("ROUTER", address(0));

        vm.startBroadcast(pk);
        CarvyBridge bridge = new CarvyBridge(signer, me);
        CarvyLaunchpad pad = new CarvyLaunchpad(bridge, me, treasury, buyback, holders, IUniswapV2Router02(router));
        bridge.setFactory(address(pad));
        pad.configureQuote(address(0), vm.envOr("ETH_VIRTUAL", uint256(1 ether)));
        address wbtc = vm.envOr("WBTC", address(0));
        if (wbtc != address(0)) pad.configureQuote(wbtc, vm.envOr("WBTC_VIRTUAL", uint256(4_000_000)));
        address usdc = vm.envOr("USDC", address(0));
        if (usdc != address(0)) pad.configureQuote(usdc, vm.envOr("USDC_VIRTUAL", uint256(4_000e6)));
        if (owner != me) {
            pad.transferOwnership(owner);
            bridge.transferOwnership(owner);
        }
        vm.stopBroadcast();

        console2.log("CarvyBridge", address(bridge));
        console2.log("CarvyLaunchpad", address(pad));
    }
}
