// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {HookMiner} from "v4-periphery-test/shared/HookMiner.sol";

import {CarvyLaunchpadV2} from "../src/CarvyLaunchpadV2.sol";
import {CarvyHook} from "../src/CarvyHook.sol";
import {CarvyBridge} from "../src/CarvyBridge.sol";

/// Env: PRIVATE_KEY, WBTC/WBTC_VIRTUAL, USDC/USDC_VIRTUAL (optional), OWNER/TREASURY/BUYBACK/HOLDERS (default deployer)
contract DeployV2 is Script {
    address constant CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function v4() internal view returns (IPoolManager, IPositionManager) {
        if (block.chainid == 1) return (IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90), IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e));
        if (block.chainid == 8453) return (IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b), IPositionManager(0x7C5f5A4bBd8fD63184577525326123B519429bDc));
        if (block.chainid == 56) return (IPoolManager(0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF), IPositionManager(0x7A4a5c919aE2541AeD11041A1AEeE68f1287f95b));
        if (block.chainid == 4663) return (IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951), IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7));
        revert("chain");
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        (IPoolManager pm, IPositionManager posm) = v4();
        vm.startBroadcast(pk);
        CarvyBridge bridge = new CarvyBridge(vm.envOr("BRIDGE_SIGNER", me), me);
        CarvyLaunchpadV2 pad = new CarvyLaunchpadV2(bridge, pm, posm, me, vm.envOr("TREASURY", me), vm.envOr("BUYBACK", me), vm.envOr("HOLDERS", me));
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        (address hookAddr, bytes32 salt) = HookMiner.find(CREATE2, flags, type(CarvyHook).creationCode, abi.encode(pm, address(pad)));
        CarvyHook hook = new CarvyHook{salt: salt}(pm, address(pad));
        require(address(hook) == hookAddr, "hook address");
        bridge.setFactory(address(pad));
        pad.setHook(hook);
        pad.configureQuote(address(0), vm.envOr("NATIVE_VIRTUAL", uint256(1 ether)));
        address wbtc = vm.envOr("WBTC", address(0));
        if (wbtc != address(0)) pad.configureQuote(wbtc, vm.envOr("WBTC_VIRTUAL", uint256(4_000_000)));
        address usdc = vm.envOr("USDC", address(0));
        if (usdc != address(0)) pad.configureQuote(usdc, vm.envOr("USDC_VIRTUAL", uint256(4_000e6)));
        address owner = vm.envOr("OWNER", me);
        if (owner != me) {
            pad.transferOwnership(owner);
            bridge.transferOwnership(owner);
        }
        vm.stopBroadcast();
        console2.log("CarvyBridge", address(bridge));
        console2.log("CarvyLaunchpadV2", address(pad));
        console2.log("CarvyHook", address(hook));
    }
}
