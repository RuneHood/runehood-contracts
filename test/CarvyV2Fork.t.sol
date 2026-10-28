// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {HookMiner} from "v4-periphery-test/shared/HookMiner.sol";

import {CarvyLaunchpadV2} from "../src/CarvyLaunchpadV2.sol";
import {CarvyHook} from "../src/CarvyHook.sol";
import {CarvyBridge} from "../src/CarvyBridge.sol";
import {CarvyRuneToken} from "../src/CarvyRuneToken.sol";

abstract contract CarvyV2ForkBase is Test {
    CarvyLaunchpadV2 pad;
    CarvyHook hook;
    CarvyBridge bridge;
    IPoolManager pm;
    IPositionManager posm;
    PoolSwapTest router;
    address owner = makeAddr("v2-owner");
    address treasury = makeAddr("v2-treasury");
    address buyback = makeAddr("v2-buyback");
    address holders = makeAddr("v2-holders");
    address creator = makeAddr("v2-creator");
    address alice = makeAddr("v2-alice");
    address bob = makeAddr("v2-bob");

    function rpc() internal view virtual returns (string memory);
    function v4() internal pure virtual returns (IPoolManager, IPositionManager);

    function setUp() public virtual {
        vm.createSelectFork(rpc());
        (pm, posm) = v4();
        bridge = new CarvyBridge(owner, owner);
        pad = new CarvyLaunchpadV2(bridge, pm, posm, owner, treasury, buyback, holders);
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(pm, address(pad));
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), flags, type(CarvyHook).creationCode, args);
        hook = new CarvyHook{salt: salt}(pm, address(pad));
        assertEq(address(hook), hookAddr);
        vm.startPrank(owner);
        bridge.setFactory(address(pad));
        pad.setHook(hook);
        pad.configureQuote(address(0), 1 ether);
        vm.stopPrank();
        router = new PoolSwapTest(pm);
        vm.deal(creator, 100 ether);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function _p(address quote, uint16 bt, uint16 st, uint256 initialBuy) internal pure returns (CarvyLaunchpadV2.CreateParams memory) {
        return CarvyLaunchpadV2.CreateParams("Ruby Doge", "RDOGE", "RUBY.DOGE", "carvy:meta:x", quote, CarvyLaunchpadV2.FeeMode.Dev, address(0), bt, st, initialBuy, 0);
    }

    function _createEth(uint16 bt, uint16 st) internal returns (address t) {
        vm.prank(creator);
        t = pad.createRune(_p(address(0), bt, st, 0));
    }

    function _graduateAndMigrate(address t) internal {
        vm.prank(bob);
        pad.buy{value: 50 ether}(t, 50 ether, 0);
        pad.migrate(t);
    }

    function _swap(address who, PoolKey memory key, bool zeroForOne, int256 amount, uint256 value) internal returns (BalanceDelta) {
        vm.prank(who);
        return router.swap{value: value}(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ------------------------------------------------------------------ curve + tax

    function test_taxOnCurveGoesToCreator() public {
        address t = _createEth(300, 300);
        vm.prank(alice);
        pad.buy{value: 1 ether}(t, 1 ether, 0);
        // creator: 0.5% platform share + 3% tax = 0.035 ETH
        assertEq(pad.claimable(creator, address(0)), 0.035 ether);
        assertEq(pad.claimable(buyback, address(0)), 0.001 ether);
        assertEq(pad.claimable(treasury, address(0)), 0.004 ether);
        uint256 bal = CarvyRuneToken(t).balanceOf(alice);
        vm.startPrank(alice);
        CarvyRuneToken(t).approve(address(pad), bal);
        uint256 q = pad.quoteSell(t, bal);
        uint256 e0 = alice.balance;
        pad.sell(t, bal, q);
        vm.stopPrank();
        assertEq(alice.balance - e0, q);
        assertGt(pad.claimable(creator, address(0)), 0.035 ether);
    }

    function test_taxAbove5pctRejected() public {
        vm.prank(creator);
        vm.expectRevert(CarvyLaunchpadV2.BadParams.selector);
        pad.createRune(_p(address(0), 501, 0, 0));
    }

    function test_quoteBuyMatchesBuy() public {
        address t = _createEth(200, 100);
        uint256 q = pad.quoteBuy(t, 0.3 ether);
        vm.prank(alice);
        uint256 out = pad.buy{value: 0.3 ether}(t, 0.3 ether, q);
        assertEq(out, q);
    }

    // ------------------------------------------------------------------ graduation into V4

    function test_graduateMigrateIntoV4_withCreatorTax() public {
        address t = _createEth(300, 300);
        _graduateAndMigrate(t);
        (,,,,,, bool graduated, bool migrated,,, uint256 realQuote,, uint256 lpId) = pad.curves(t);
        assertTrue(graduated && migrated);
        assertEq(realQuote, 0);
        assertEq(IERC721(address(posm)).ownerOf(lpId), address(pad)); // LP locked in the launchpad
        assertEq(CarvyRuneToken(t).balanceOf(address(pad)), 0); // all tokens in the pool or burned
        (PoolKey memory key, bool quoteIs0) = pad.poolKeyOf(t);
        assertTrue(quoteIs0);

        // buy in the V4 pool: exact-in, 3% tax in ETH to the creator
        uint256 c0 = creator.balance;
        _swap(alice, key, true, -1 ether, 1 ether);
        assertEq(creator.balance - c0, 0.03 ether);
        uint256 got = IERC20(t).balanceOf(alice);
        assertGt(got, 0);

        // sell exact-in: ~3% of the ETH out goes to the creator
        vm.prank(alice);
        IERC20(t).approve(address(router), got);
        c0 = creator.balance;
        BalanceDelta d = _swap(alice, key, false, -int256(got), 0);
        uint256 out = uint256(int256(d.amount0()));
        uint256 tax = creator.balance - c0;
        assertApproxEqRel((tax * 10_000) / (out + tax), 300, 0.01e18);
    }

    function test_migrateOnlyOnceAndOnlyAfterGraduation() public {
        address t = _createEth(0, 0);
        vm.expectRevert(CarvyLaunchpadV2.NotGraduated.selector);
        pad.migrate(t);
        _graduateAndMigrate(t);
        vm.expectRevert(CarvyLaunchpadV2.CurveClosed.selector);
        pad.migrate(t);
    }

    function test_nobodyElseCanUseHook() public {
        address t = _createEth(300, 300);
        (PoolKey memory key,) = pad.poolKeyOf(t);
        vm.expectRevert();
        pm.initialize(key, TickMath.getSqrtPriceAtTick(0));
        vm.expectRevert(CarvyHook.NotLaunchpad.selector);
        hook.register(key, true, 0, 0, alice);
    }

    function test_noTaxPoolTradesClean() public {
        address t = _createEth(0, 0);
        _graduateAndMigrate(t);
        (PoolKey memory key,) = pad.poolKeyOf(t);
        uint256 c0 = creator.balance;
        _swap(alice, key, true, -1 ether, 1 ether);
        assertEq(creator.balance, c0);
        assertGt(IERC20(t).balanceOf(alice), 0);
    }

    function test_collectPoolFeesToTreasury() public {
        address t = _createEth(0, 0);
        _graduateAndMigrate(t);
        (PoolKey memory key,) = pad.poolKeyOf(t);
        _swap(alice, key, true, -2 ether, 2 ether);
        uint256 b0 = treasury.balance;
        pad.collectPoolFees(t);
        assertGt(treasury.balance - b0, 0.005 ether); // ~0.3% of 2 ETH
    }

    function test_walletTransferNotTaxed() public {
        address t = _createEth(500, 500);
        vm.prank(alice);
        pad.buy{value: 0.1 ether}(t, 0.1 ether, 0);
        uint256 b = IERC20(t).balanceOf(alice);
        vm.prank(alice);
        IERC20(t).transfer(bob, b);
        assertEq(IERC20(t).balanceOf(bob), b);
    }
}

contract CarvyV2BaseFork is CarvyV2ForkBase {
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    function rpc() internal view override returns (string memory) {
        return vm.envOr("RPC_BASE", string("https://mainnet.base.org"));
    }

    function v4() internal pure override returns (IPoolManager, IPositionManager) {
        return (IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b), IPositionManager(0x7C5f5A4bBd8fD63184577525326123B519429bDc));
    }

    function test_erc20QuoteGraduatesIntoV4() public {
        vm.prank(owner);
        pad.configureQuote(CBBTC, 4_000_000);
        deal(CBBTC, creator, 1e8);
        deal(CBBTC, bob, 10e8);
        deal(CBBTC, alice, 1e8);
        vm.startPrank(creator);
        IERC20(CBBTC).approve(address(pad), type(uint256).max);
        address t = pad.createRune(_p(CBBTC, 300, 300, 100_000));
        vm.stopPrank();
        vm.startPrank(bob);
        IERC20(CBBTC).approve(address(pad), type(uint256).max);
        pad.buy(t, 2e8, 0);
        vm.stopPrank();
        pad.migrate(t);
        (PoolKey memory key, bool quoteIs0) = pad.poolKeyOf(t);
        console2.log("cbBTC is currency0:", quoteIs0);
        // buy with cbBTC in the pool
        vm.startPrank(alice);
        IERC20(CBBTC).approve(address(router), type(uint256).max);
        vm.stopPrank();
        uint256 c0 = IERC20(CBBTC).balanceOf(creator);
        _swap(alice, key, quoteIs0, -1_000_000, 0);
        assertEq(IERC20(CBBTC).balanceOf(creator) - c0, 30_000); // 3% of 0.01 cbBTC
        assertGt(IERC20(t).balanceOf(alice), 0);
    }
}

contract CarvyV2RobinhoodFork is CarvyV2ForkBase {
    function rpc() internal view override returns (string memory) {
        return vm.envOr("RPC_ROBINHOOD", string("https://rpc.mainnet.chain.robinhood.com"));
    }

    function v4() internal pure override returns (IPoolManager, IPositionManager) {
        return (IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951), IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7));
    }
}

contract CarvyV2EthereumFork is CarvyV2ForkBase {
    function rpc() internal view override returns (string memory) {
        return vm.envOr("RPC_ETHEREUM", string("https://ethereum-rpc.publicnode.com"));
    }

    function v4() internal pure override returns (IPoolManager, IPositionManager) {
        return (IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90), IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e));
    }
}

contract CarvyV2BscFork is CarvyV2ForkBase {
    function rpc() internal view override returns (string memory) {
        return "https://bsc-dataseed.bnbchain.org";
    }

    function v4() internal pure override returns (IPoolManager, IPositionManager) {
        return (IPoolManager(0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF), IPositionManager(0x7A4a5c919aE2541AeD11041A1AEeE68f1287f95b));
    }
}
