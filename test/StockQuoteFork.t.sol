// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {CarvyLaunchpadV2} from "../src/CarvyLaunchpadV2.sol";

/// Fork test against the LIVE Robinhood Chain launchpad: a Rune paired with a Robinhood Stock Token (TSLA)
/// trades on the curve, graduates and migrates into a Uniswap V4 RUNE/TSLA pool with the creator tax working.
contract StockQuoteForkTest is Test {
    CarvyLaunchpadV2 constant PAD = CarvyLaunchpadV2(payable(0x0A1Ff578b7D1Fa9844E26DE415dF7319447bc4Ce));
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address creator = makeAddr("stock-creator");
    address alice = makeAddr("stock-alice");
    address bob = makeAddr("stock-bob");
    PoolSwapTest router;

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_ROBINHOOD", string("https://rpc.mainnet.chain.robinhood.com")));
        vm.prank(PAD.owner());
        PAD.configureQuote(TSLA, 5.8e18); // ~1 ETH worth of TSLA
        router = new PoolSwapTest(IPoolManager(address(PAD.poolManager())));
        deal(TSLA, alice, 100e18);
        deal(TSLA, bob, 200e18);
    }

    function test_stockPairedRuneGraduatesIntoV4() public {
        vm.prank(creator);
        address t = PAD.createRune(
            CarvyLaunchpadV2.CreateParams("Tesla Rune", "TRUNE", "TESLA.RUNE", "meta:x", TSLA, CarvyLaunchpadV2.FeeMode.Dev, address(0), 300, 300, 0, 0)
        );
        vm.startPrank(alice);
        IERC20(TSLA).approve(address(PAD), type(uint256).max);
        uint256 out = PAD.buy(t, 1e18, 0);
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(PAD.claimable(creator, TSLA), 0.035e18); // 0.5% creator share + 3% tax, in TSLA

        vm.startPrank(bob);
        IERC20(TSLA).approve(address(PAD), type(uint256).max);
        uint256 b0 = IERC20(TSLA).balanceOf(bob);
        PAD.buy(t, 150e18, 0);
        vm.stopPrank();
        console2.log("TSLA spent to graduate", (b0 - IERC20(TSLA).balanceOf(bob)) / 1e15);
        PAD.migrate(t);

        (,,,,,, bool graduated, bool migrated,,,,, uint256 lpId) = PAD.curves(t);
        assertTrue(graduated && migrated);
        assertEq(IERC721(address(PAD.positionManager())).ownerOf(lpId), address(PAD));

        (PoolKey memory key, bool quoteIs0) = PAD.poolKeyOf(t);
        // buy RUNE with TSLA in the V4 pool, 3% tax to creator in TSLA
        uint256 c0 = IERC20(TSLA).balanceOf(creator);
        vm.startPrank(alice);
        IERC20(TSLA).approve(address(router), type(uint256).max);
        router.swap(
            key,
            SwapParams({zeroForOne: quoteIs0, amountSpecified: -1e18, sqrtPriceLimitX96: quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 got = IERC20(t).balanceOf(alice);
        assertGt(got, out);
        assertEq(IERC20(TSLA).balanceOf(creator) - c0, 0.03e18);
        // sell back
        IERC20(t).approve(address(router), type(uint256).max);
        router.swap(
            key,
            SwapParams({zeroForOne: !quoteIs0, amountSpecified: -int256(got / 2), sqrtPriceLimitX96: !quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        assertGt(IERC20(TSLA).balanceOf(creator) - c0, 0.03e18);
    }
}
