// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {RunehoodZap, IRuneLaunchpad} from "../src/RunehoodZap.sol";

/// Fork test on live Robinhood Chain: buy and sell the SPY-paired Rune RUNI with native ETH through the zap.
contract RunehoodZapForkTest is Test {
    address constant PAD = 0x0A1Ff578b7D1Fa9844E26DE415dF7319447bc4Ce;
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant RUNI = 0x0e64EF7A59e51f7074E03D26e4148EF23E28C133;
    RunehoodZap zap;
    address alice = makeAddr("zap-alice");

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_ROBINHOOD", string("https://rpc.mainnet.chain.robinhood.com")));
        zap = new RunehoodZap(PM, IRuneLaunchpad(PAD));
        vm.deal(alice, 10 ether);
    }

    function _buyPath() internal pure returns (PoolKey[] memory p) {
        p = new PoolKey[](2);
        p[0] = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), 500, 10, IHooks(address(0)));
        (address a, address b) = USDG < SPY ? (USDG, SPY) : (SPY, USDG);
        p[1] = PoolKey(Currency.wrap(a), Currency.wrap(b), 100, 1, IHooks(address(0)));
    }

    function _sellPath() internal pure returns (PoolKey[] memory p) {
        PoolKey[] memory b = _buyPath();
        p = new PoolKey[](2);
        p[0] = b[1];
        p[1] = b[0];
    }

    function test_buyAndSellWithEth() public {
        vm.prank(alice);
        uint256 out = zap.buyWithEth{value: 0.05 ether}(RUNI, _buyPath(), 0, 0);
        assertGt(out, 0);
        assertEq(IERC20(RUNI).balanceOf(alice), out);
        assertEq(IERC20(RUNI).balanceOf(address(zap)), 0);
        assertEq(IERC20(SPY).balanceOf(address(zap)), 0);
        assertEq(address(zap).balance, 0);
        console2.log("RUNI bought for 0.05 ETH", out / 1e18);

        uint256 e0 = alice.balance;
        vm.startPrank(alice);
        IERC20(RUNI).approve(address(zap), out);
        uint256 eth = zap.sellForEth(RUNI, out, SPY, _sellPath(), 0);
        vm.stopPrank();
        assertEq(alice.balance - e0, eth);
        assertGt(eth, 0.045 ether); // round trip: 2x1% curve fee + pool fees
        assertEq(address(zap).balance, 0);
        console2.log("ETH back (wei)", eth);
    }

    function test_badPathReverts() public {
        PoolKey[] memory p = _buyPath();
        p[1].fee = 3000; // a pool that does not settle into SPY at the expected tier still must end in a token
        p[0].currency1 = Currency.wrap(SPY); // break continuity
        vm.prank(alice);
        vm.expectRevert();
        zap.buyWithEth{value: 0.01 ether}(RUNI, p, 0, 0);
    }
}
