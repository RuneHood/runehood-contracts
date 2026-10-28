// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CarvyHolderRewards} from "../src/CarvyHolderRewards.sol";

contract MockToken is ERC20 {
    constructor() ERC20("M", "M") {
        _mint(msg.sender, 1e30);
    }
}

contract MockPad {
    function claim(address) external {
        payable(msg.sender).transfer(1 ether);
    }

    receive() external payable {}
}

contract CarvyHolderRewardsTest is Test {
    CarvyHolderRewards r;
    MockToken tok;
    address owner = makeAddr("owner");
    address updater = makeAddr("updater");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        r = new CarvyHolderRewards(owner, updater);
        tok = new MockToken();
        tok.transfer(address(r), 1000 ether);
        vm.deal(address(r), 10 ether);
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _root2(bytes32 l0, bytes32 l1) internal pure returns (bytes32) {
        return _pair(l0, l1);
    }

    function test_claimNativeAndToken_cumulative() public {
        bytes32 la = r.leafOf(alice, address(0), 1 ether);
        bytes32 lb = r.leafOf(bob, address(tok), 100 ether);
        vm.prank(updater);
        r.setRoot(_root2(la, lb), "ipfs://e1");
        bytes32[] memory pa = new bytes32[](1);
        pa[0] = lb;
        bytes32[] memory pb = new bytes32[](1);
        pb[0] = la;
        r.claim(alice, address(0), 1 ether, pa);
        assertEq(alice.balance, 1 ether);
        r.claim(bob, address(tok), 100 ether, pb);
        assertEq(tok.balanceOf(bob), 100 ether);
        vm.expectRevert(CarvyHolderRewards.NothingToClaim.selector);
        r.claim(alice, address(0), 1 ether, pa);

        // next epoch: alice cumulative grows to 3 ether -> she gets only the difference
        bytes32 la2 = r.leafOf(alice, address(0), 3 ether);
        vm.prank(updater);
        r.setRoot(_root2(la2, lb), "ipfs://e2");
        pa[0] = lb;
        r.claim(alice, address(0), 3 ether, pa);
        assertEq(alice.balance, 3 ether);
    }

    function test_badProofAndUpdaterOnly() public {
        vm.expectRevert(CarvyHolderRewards.NotUpdater.selector);
        r.setRoot(bytes32(uint256(1)), "");
        bytes32 la = r.leafOf(alice, address(0), 1 ether);
        vm.prank(updater);
        r.setRoot(la, "");
        bytes32[] memory p = new bytes32[](0);
        vm.expectRevert(CarvyHolderRewards.BadProof.selector);
        r.claim(alice, address(0), 2 ether, p);
        r.claim(alice, address(0), 1 ether, p); // single-leaf tree
        assertEq(alice.balance, 1 ether);
    }

    function test_pullFromLaunchpad() public {
        MockPad pad = new MockPad();
        vm.deal(address(pad), 5 ether);
        uint256 b = address(r).balance;
        r.pull(address(pad), address(0));
        assertEq(address(r).balance, b + 1 ether);
    }
}
