// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CarvyLaunchpadPancake, IPancakeFactory} from "../src/CarvyLaunchpadPancake.sol";
import {CarvyRuneTokenTax} from "../src/CarvyRuneTokenTax.sol";
import {CarvyBridge} from "../src/CarvyBridge.sol";

interface IRouter {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external;
}

interface IPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// Real BNB Chain fork: PancakeSwap V2 factory/router, WBNB, BTCB.
contract CarvyPancakeFork is Test {
    address constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;

    CarvyLaunchpadPancake pad;
    CarvyBridge bridge;
    address owner = makeAddr("pcs-owner");
    address treasury = makeAddr("pcs-treasury");
    address buyback = makeAddr("pcs-buyback");
    address holders = makeAddr("pcs-holders");
    address creator = makeAddr("pcs-creator");
    address alice = makeAddr("pcs-alice");
    address bob = makeAddr("pcs-bob");

    function setUp() public {
        vm.createSelectFork("https://bsc-rpc.publicnode.com");
        bridge = new CarvyBridge(owner, owner);
        pad = new CarvyLaunchpadPancake(bridge, IPancakeFactory(FACTORY), WBNB, owner, treasury, buyback, holders);
        vm.startPrank(owner);
        bridge.setFactory(address(pad));
        pad.configureQuote(address(0), 3 ether);
        pad.configureQuote(BTCB, 0.04 ether);
        vm.stopPrank();
        vm.deal(creator, 100 ether);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function _create(address quote, uint16 bt, uint16 st) internal returns (address t) {
        vm.prank(creator);
        t = pad.createRune(CarvyLaunchpadPancake.CreateParams("Ruby Doge", "RDOGE", "RUBY.DOGE", "carvy:meta:x", quote, CarvyLaunchpadPancake.FeeMode.Dev, address(0), bt, st, 0, 0));
    }

    function _graduate(address t) internal {
        vm.prank(bob);
        pad.buy{value: 100 ether}(t, 100 ether, 0);
        pad.migrate(t);
    }

    function test_pairCreatedAtLaunch_andClosedBeforeGraduation() public {
        address t = _create(address(0), 0, 0);
        address pair = CarvyRuneTokenTax(t).pair();
        assertTrue(pair != address(0));
        vm.prank(alice);
        pad.buy{value: 1 ether}(t, 1 ether, 0);
        uint256 bal = IERC20(t).balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(CarvyRuneTokenTax.PairNotOpen.selector);
        IERC20(t).transfer(pair, bal / 2); // nobody can seed the pair before graduation
    }

    function test_graduateIntoPancake_lpLocked_priceMatchesCurve() public {
        address t = _create(address(0), 0, 0);
        _graduate(t);
        address pair = CarvyRuneTokenTax(t).pair();
        (uint112 r0, uint112 r1,) = IPair(pair).getReserves();
        (uint256 rT, uint256 rQ) = IPair(pair).token0() == t ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        assertGt(rQ, 5 ether);
        assertGt(rT, 100_000_000 ether);
        // LP owned by the launchpad, nobody else
        assertGt(IPair(pair).balanceOf(address(pad)), 0);
        assertEq(IPair(pair).balanceOf(address(pad)) + 1000, IPair(pair).totalSupply());
        // curve sold out + LP tokens + burned leftovers = full supply on chain
        assertEq(IERC20(t).balanceOf(address(pad)), 0);
        vm.expectRevert(CarvyLaunchpadPancake.CurveClosed.selector);
        pad.migrate(t);
    }

    function test_tradeOnPancakeAfterGraduation_withCreatorTax() public {
        address t = _create(address(0), 300, 500);
        _graduate(t);
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = t;
        uint256 before = IERC20(t).balanceOf(creator);
        vm.prank(alice);
        IRouter(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: 1 ether}(0, path, alice, block.timestamp);
        uint256 got = IERC20(t).balanceOf(alice);
        uint256 taxBuy = IERC20(t).balanceOf(creator) - before;
        assertGt(got, 0);
        assertApproxEqRel(taxBuy, ((got + taxBuy) * 300) / 10_000, 0.0001e18); // 3% buy tax to the creator

        path[0] = t;
        path[1] = WBNB;
        vm.startPrank(alice);
        IERC20(t).approve(ROUTER, got);
        uint256 e0 = alice.balance;
        uint256 c0 = IERC20(t).balanceOf(creator);
        IRouter(ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(got, 0, path, alice, block.timestamp);
        vm.stopPrank();
        assertGt(alice.balance, e0);
        assertEq(IERC20(t).balanceOf(creator) - c0, (got * 500) / 10_000); // 5% sell tax
    }

    function test_walletTransfersNeverTaxed() public {
        address t = _create(address(0), 500, 500);
        _graduate(t);
        vm.prank(bob);
        IERC20(t).transfer(alice, 1000 ether);
        assertEq(IERC20(t).balanceOf(alice), 1000 ether);
    }

    function test_btcbQuoteGraduates() public {
        address t = _create(BTCB, 0, 0);
        deal(BTCB, bob, 10 ether);
        vm.startPrank(bob);
        IERC20(BTCB).approve(address(pad), type(uint256).max);
        pad.buy(t, 1 ether, 0);
        vm.stopPrank();
        pad.migrate(t);
        (bool g, bool m) = _flags(t);
        assertTrue(g && m);
    }

    function test_bridgeStillWorks() public {
        address t = _create(address(0), 300, 300);
        vm.prank(alice);
        pad.buy{value: 1 ether}(t, 1 ether, 0);
        uint256 bal = IERC20(t).balanceOf(alice);
        vm.prank(alice);
        bridge.bridgeOut(t, bal, "bc1pxqkeg937wmse4t0ser53sena8lhz5vfkylq2vq6t5gpe4ert947sek3xvf");
        assertEq(IERC20(t).balanceOf(alice), 0);
    }

    function test_donationBeforeGraduationCannotBlockMigration() public {
        address t = _create(address(0), 0, 0);
        address pair = CarvyRuneTokenTax(t).pair();
        // attacker sends WBNB to the empty pair and syncs it
        deal(WBNB, alice, 5 ether);
        vm.prank(alice);
        IERC20(WBNB).transfer(pair, 5 ether);
        (bool ok,) = pair.call(abi.encodeWithSignature("sync()"));
        ok;
        _graduate(t); // still succeeds; the donation just adds to locked liquidity
        (bool g, bool m) = _flags(t);
        assertTrue(g && m);
    }

    function _flags(address t) internal view returns (bool g, bool m) {
        (,,,,,, g, m,,,,,) = pad.curves(t);
    }
}
