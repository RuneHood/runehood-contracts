// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CarvyLaunchpadPancake, IPancakeFactory} from "../src/CarvyLaunchpadPancake.sol";
import {CarvyBridge} from "../src/CarvyBridge.sol";

/// BNB Chain launchpad that graduates into PancakeSwap V2.
/// Env: PRIVATE_KEY, OWNER, BRIDGE_SIGNER, TREASURY, BUYBACK, HOLDERS
contract DeployPancake is Script {
    address constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        vm.startBroadcast(pk);
        CarvyBridge bridge = new CarvyBridge(vm.envAddress("BRIDGE_SIGNER"), me);
        CarvyLaunchpadPancake pad =
            new CarvyLaunchpadPancake(bridge, IPancakeFactory(FACTORY), WBNB, me, vm.envAddress("TREASURY"), vm.envAddress("BUYBACK"), vm.envAddress("HOLDERS"));
        bridge.setFactory(address(pad));
        pad.configureQuote(address(0), 3 ether); // BNB
        pad.configureQuote(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c, 0.04 ether); // BTCB (18 decimals)
        pad.configureQuote(0x55d398326f99059fF775485246999027B3197955, 4_000 ether); // USDT (18 decimals)
        address owner = vm.envAddress("OWNER");
        pad.transferOwnership(owner);
        bridge.transferOwnership(owner);
        vm.stopBroadcast();
        console2.log("CarvyBridge", address(bridge));
        console2.log("CarvyLaunchpadPancake", address(pad));
    }
}
