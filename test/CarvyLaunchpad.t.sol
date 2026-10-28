// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CarvyLaunchpad, IUniswapV2Router02} from "../src/CarvyLaunchpad.sol";
import {CarvyBridge} from "../src/CarvyBridge.sol";
import {CarvyRuneToken} from "../src/CarvyRuneToken.sol";

contract MockWBTC is ERC20 {
    constructor() ERC20("Wrapped BTC", "WBTC") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract CarvyLaunchpadTest is Test {
    CarvyLaunchpad pad;
    CarvyBridge bridge;
    MockWBTC wbtc;
    uint256 signerKey = 0xC0FFEE;
    address signer;
    address owner = address(0xA11CE);
    address treasury = address(0x7EA5);
    address buyback = address(0xB0B);
    address holders = address(0x401D);
    address alice = address(0xA1);
    address bob = address(0xB2);

    function setUp() public {
        signer = vm.addr(signerKey);
        bridge = new CarvyBridge(signer, owner);
        pad = new CarvyLaunchpad(bridge, owner, treasury, buyback, holders, IUniswapV2Router02(address(0)));
        vm.startPrank(owner);
        bridge.setFactory(address(pad));
        pad.configureQuote(address(0), 1 ether); // native ETH: 1 ETH virtual
        wbtc = new MockWBTC();
        pad.configureQuote(address(wbtc), 4_000_000); // 0.04 BTC virtual (8 decimals)
        vm.stopPrank();
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        wbtc.mint(alice, 10e8);
    }

    function _launchEth() internal returns (address t) {
        vm.prank(alice);
        t = pad.createRune("Ruby Doge", "RDOGE", "RUBY.DOGE", "ipfs://x", address(0), CarvyLaunchpad.FeeMode.Dev, address(0), 0, 0);
    }

    function test_createAndBuySellEth() public {
        address t = _launchEth();
        assertEq(CarvyRuneToken(t).totalSupply(), 1_000_000_000 ether);
        assertEq(CarvyRuneToken(t).balanceOf(address(pad)), 1_000_000_000 ether);
        assertTrue(bridge.isCarvyRune(t));

        uint256 q = pad.quoteBuy(t, 0.5 ether);
        vm.prank(bob);
        uint256 out = pad.buy{value: 0.5 ether}(t, 0.5 ether, q);
        assertEq(out, q);
        assertEq(CarvyRuneToken(t).balanceOf(bob), out);

        // fee split: 1% of 0.5 = 0.005 -> creator 0.0025, buyback 0.0005, treasury 0.002
        assertEq(pad.claimable(alice, address(0)), 0.0025 ether);
        assertEq(pad.claimable(buyback, address(0)), 0.0005 ether);
        assertEq(pad.claimable(treasury, address(0)), 0.002 ether);

        vm.startPrank(bob);
        CarvyRuneToken(t).approve(address(pad), out);
        uint256 qs = pad.quoteSell(t, out);
        uint256 before = bob.balance;
        pad.sell(t, out, qs);
        vm.stopPrank();
        assertEq(bob.balance - before, qs);
        assertLt(qs, 0.5 ether); // paid fees both ways
        assertGt(qs, 0.49 ether);

        vm.prank(alice);
        pad.claim(address(0));
        assertEq(pad.claimable(alice, address(0)), 0);
    }

    function test_cannotSellMoreThanSold() public {
        address t = _launchEth();
        vm.prank(bob);
        pad.buy{value: 0.1 ether}(t, 0.1 ether, 0);
        uint256 bal = CarvyRuneToken(t).balanceOf(bob);
        vm.startPrank(bob);
        CarvyRuneToken(t).approve(address(pad), type(uint256).max);
        vm.expectRevert(CarvyLaunchpad.BadAmount.selector);
        pad.sell(t, bal + 1, 0);
        vm.stopPrank();
    }

    function test_graduationRefundsExcess() public {
        address t = _launchEth();
        vm.prank(bob);
        uint256 out = pad.buy{value: 500 ether}(t, 500 ether, 0);
        assertEq(out, pad.CURVE_SUPPLY());
        (,,,, bool graduated,,,, uint256 realQuote, uint256 sold) = pad.curves(t);
        assertTrue(graduated);
        assertEq(sold, pad.CURVE_SUPPLY());
        assertLt(realQuote, 5 ether); // ~2.83 ETH raised, rest refunded
        assertGt(bob.balance, 990 ether);
        vm.prank(alice);
        vm.expectRevert(CarvyLaunchpad.CurveClosed.selector);
        pad.buy{value: 1 ether}(t, 1 ether, 0);
    }

    function test_wbtcQuoteAndSlippage() public {
        vm.startPrank(alice);
        wbtc.approve(address(pad), type(uint256).max);
        address t = pad.createRune("Stone Pizza", "PIZZA", "STONE.PIZZA", "", address(wbtc), CarvyLaunchpad.FeeMode.Holders, address(0), 100_000, 0);
        assertGt(CarvyRuneToken(t).balanceOf(alice), 0);
        uint256 q = pad.quoteBuy(t, 200_000);
        vm.expectRevert(CarvyLaunchpad.Slippage.selector);
        pad.buy(t, 200_000, q + 1);
        vm.stopPrank();
        assertGt(pad.claimable(holders, address(wbtc)), 0);
    }

    function test_bridgeOutAndSignedBridgeIn() public {
        address t = _launchEth();
        vm.prank(bob);
        uint256 out = pad.buy{value: 0.2 ether}(t, 0.2 ether, 0);
        vm.prank(bob);
        bridge.bridgeOut(t, out / 2, "bc1pqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq");
        assertEq(CarvyRuneToken(t).totalSupply(), 1_000_000_000 ether - out / 2);

        bytes32 txid = keccak256("btc-tx");
        bytes32 structHash = keccak256(abi.encode(bridge.BRIDGE_IN_TYPEHASH(), t, bob, out / 2, txid, uint32(1)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", bridge.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bridge.bridgeIn(t, bob, out / 2, txid, 1, abi.encodePacked(r, s, v));
        assertEq(CarvyRuneToken(t).totalSupply(), 1_000_000_000 ether);
        vm.expectRevert(CarvyBridge.AlreadyProcessed.selector);
        bridge.bridgeIn(t, bob, out / 2, txid, 1, abi.encodePacked(r, s, v));
    }

    function test_bridgeInCannotExceedCap() public {
        address t = _launchEth();
        bytes32 txid = keccak256("forged");
        bytes32 structHash = keccak256(abi.encode(bridge.BRIDGE_IN_TYPEHASH(), t, bob, 1 ether, txid, uint32(0)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", bridge.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        vm.expectRevert(CarvyRuneToken.CapExceeded.selector);
        bridge.bridgeIn(t, bob, 1 ether, txid, 0, abi.encodePacked(r, s, v));
    }

    function test_badSignerRejected() public {
        address t = _launchEth();
        bytes32 structHash = keccak256(abi.encode(bridge.BRIDGE_IN_TYPEHASH(), t, bob, 1, bytes32(0), uint32(0)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", bridge.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, digest);
        vm.expectRevert(CarvyBridge.BadSignature.selector);
        bridge.bridgeIn(t, bob, 1, bytes32(0), 0, abi.encodePacked(r, s, v));
    }

    function test_onlyBridgeMints() public {
        address t = _launchEth();
        vm.expectRevert(CarvyRuneToken.OnlyBridge.selector);
        CarvyRuneToken(t).bridgeMint(bob, 1);
    }

    function test_signerRotationTimelock() public {
        vm.prank(owner);
        bridge.proposeSigner(address(0x5157));
        vm.expectRevert(CarvyBridge.Timelocked.selector);
        bridge.acceptSigner();
        vm.warp(block.timestamp + 48 hours);
        bridge.acceptSigner();
        assertEq(bridge.signer(), address(0x5157));
    }

    function testFuzz_buySellNeverDrainsMoreThanDeposited(uint96 a, uint96 b) public {
        address t = _launchEth();
        uint256 x = bound(uint256(a), 0.001 ether, 1.2 ether);
        uint256 y = bound(uint256(b), 0.001 ether, 1.2 ether);
        vm.prank(alice);
        uint256 oa = pad.buy{value: x}(t, x, 0);
        vm.prank(bob);
        uint256 ob = pad.buy{value: y}(t, y, 0);
        vm.startPrank(alice);
        CarvyRuneToken(t).approve(address(pad), oa);
        uint256 ra = pad.sell(t, oa, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        CarvyRuneToken(t).approve(address(pad), ob);
        uint256 rb = pad.sell(t, ob, 0);
        vm.stopPrank();
        uint256 owed = pad.claimable(alice, address(0)) + pad.claimable(buyback, address(0)) + pad.claimable(treasury, address(0));
        assertLe(ra + rb + owed, x + y);
        assertGe(address(pad).balance, owed);
    }
}
