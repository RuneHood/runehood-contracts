// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title CarvyRuneToken
/// @notice Chain-side representation of a Bitcoin Rune launched on Carvy. Fixed 1,000,000,000 supply across
///         Bitcoin + this chain: the bridge burns when a holder moves to Bitcoin and mints back (never above the
///         cap) when a holder moves in from Bitcoin. Nobody else can mint.
contract CarvyRuneToken is ERC20 {
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;

    address public immutable bridge;
    string public runeName;

    error OnlyBridge();
    error CapExceeded();

    constructor(string memory name_, string memory symbol_, string memory runeName_, address initialHolder, address bridge_)
        ERC20(name_, symbol_)
    {
        runeName = runeName_;
        bridge = bridge_;
        _mint(initialHolder, MAX_SUPPLY);
    }

    function bridgeMint(address to, uint256 amount) external {
        if (msg.sender != bridge) revert OnlyBridge();
        if (totalSupply() + amount > MAX_SUPPLY) revert CapExceeded();
        _mint(to, amount);
    }

    function bridgeBurn(address from, uint256 amount) external {
        if (msg.sender != bridge) revert OnlyBridge();
        _burn(from, amount);
    }
}
