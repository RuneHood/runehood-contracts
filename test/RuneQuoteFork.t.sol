// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {CarvyLaunchpadV2} from "../src/CarvyLaunchpadV2.sol";
import {RunehoodZap, IRuneLaunchpad} from "../src/RunehoodZap.sol";

/// Fork test on live Robinhood Chain: a Rune paired with $RUNE, bought and sold with ETH through the zap
/// (ETH -> RUNE in the pons V4 pool), graduated and migrated into a RUNE/token V4 pool.
contract RuneQuoteForkTest is Test {
    CarvyLaunchpadV2 constant PAD = CarvyLaunchpadV2(payable(0x0A1Ff578b7D1Fa9844E26DE415dF7319447bc4Ce));
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    RunehoodZap constant ZAP = RunehoodZap(payable(0xdF14e44557a6DBF4f7856a952872B30aB7541FfD));
    address constant RUNE = 0x437d083c57BB31573Aa383f9602ec5a86519b9d4;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address creator = makeAddr("rq-creator");
    address alice = makeAddr("rq-alice");
    address whale = makeAddr("rq-whale");

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_ROBINHOOD", string("https://rpc.mainnet.chain.robinhood.com")));
        vm.prank(PAD.owner());
        PAD.configureQuote(RUNE, 15_000_000e18);
        vm.deal(alice, 10 ether);
        vm.deal(whale, 100 ether);
    }

    function _buyPath() internal pure returns (PoolKey[] memory p) {
        p = new PoolKey[](1);
        p[0] = PoolKey(Currency.wrap(address(0)), Currency.wrap(RUNE), 0, 200, IHooks(PONS_HOOK));
    }

    function test_runePairedRune_zapAndGraduate() public {
        vm.prank(creator);
        address t = PAD.createRune(
            CarvyLaunchpadV2.CreateParams("Rune Kid", "RKID", "RUNE.KID", "runehood:meta:x", RUNE, CarvyLaunchpadV2.FeeMode.Dev, address(0), 100, 100, 0, 0)
        );
        // buy with ETH through pons pool
        vm.prank(alice);
        uint256 out = ZAP.buyWithEth{value: 0.02 ether}(t, _buyPath(), 0, 0);
        assertGt(out, 0);
        assertEq(IERC20(t).balanceOf(alice), out);
        console2.log("RKID for 0.02 ETH", out / 1e18);

        // sell back to ETH
        uint256 e0 = alice.balance;
        vm.startPrank(alice);
        IERC20(t).approve(address(ZAP), out);
        PoolKey[] memory sp = _buyPath();
        uint256 eth = ZAP.sellForEth(t, out, RUNE, sp, 0);
        vm.stopPrank();
        assertEq(alice.balance - e0, eth);
        console2.log("ETH back (wei)", eth);

        // whale graduates the curve with ETH, then migrate into a RUNE/RKID V4 pool
        vm.prank(whale);
        ZAP.buyWithEth{value: 8 ether}(t, _buyPath(), 0, 0);
        (,,,,,, bool graduated,,,,,,) = PAD.curves(t);
        assertTrue(graduated, "not graduated");
        PAD.migrate(t);
        (,,,,,,, bool migrated,,,,, uint256 lpId) = PAD.curves(t);
        assertTrue(migrated);
        assertEq(IERC721(address(PAD.positionManager())).ownerOf(lpId), address(PAD));
        console2.log("RUNE left in whale refund", IERC20(RUNE).balanceOf(whale) / 1e18);
    }
}
