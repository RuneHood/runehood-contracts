// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CarvyRuneToken} from "./CarvyRuneToken.sol";

/// @title CarvyRuneTokenTax
/// @notice Carvy Rune token for chains whose graduation DEX has no hooks (PancakeSwap V2 on BNB Chain).
///  - Same fixed supply and bridge rules as CarvyRuneToken.
///  - Its PancakeSwap pair is created at launch. Until graduation only the launchpad can send tokens into the pair,
///    so nobody can seed a fake price before the real liquidity arrives.
///  - After graduation the creator tax (max 5% buy / 5% sell, fixed at launch) is taken on trades with the pair and
///    sent to the creator's fee recipient. Wallet transfers and bridging are never taxed.
contract CarvyRuneTokenTax is CarvyRuneToken {
    uint16 public constant MAX_TAX_BPS = 500;

    address public immutable launchpad;
    address public pair;
    bool public pairOpen;
    uint16 public buyTaxBps;
    uint16 public sellTaxBps;
    address public taxRecipient;

    error OnlyLaunchpad();
    error PairNotOpen();
    error AlreadySet();
    error TaxTooHigh();

    event PairOpened(address pair, uint16 buyTaxBps, uint16 sellTaxBps, address taxRecipient);

    constructor(string memory name_, string memory symbol_, string memory runeName_, address launchpad_, address bridge_)
        CarvyRuneToken(name_, symbol_, runeName_, launchpad_, bridge_)
    {
        launchpad = launchpad_;
    }

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        _;
    }

    function setPair(address p) external onlyLaunchpad {
        if (pair != address(0)) revert AlreadySet();
        pair = p;
    }

    /// Called once by the launchpad right after liquidity is added at graduation.
    function openPair(uint16 buyBps, uint16 sellBps, address recipient) external onlyLaunchpad {
        if (pairOpen) revert AlreadySet();
        if (buyBps > MAX_TAX_BPS || sellBps > MAX_TAX_BPS) revert TaxTooHigh();
        pairOpen = true;
        buyTaxBps = buyBps;
        sellTaxBps = sellBps;
        taxRecipient = recipient;
        emit PairOpened(pair, buyBps, sellBps, recipient);
    }

    function _update(address from, address to, uint256 value) internal override {
        address p = pair;
        if (p != address(0) && (from == p || to == p)) {
            if (!pairOpen) {
                if (from != launchpad) revert PairNotOpen();
            } else if (from != launchpad && to != launchpad) {
                uint256 bps = from == p ? buyTaxBps : sellTaxBps;
                address r = taxRecipient;
                if (bps > 0 && r != address(0) && from != r && to != r) {
                    uint256 t = (value * bps) / 10_000;
                    if (t > 0) {
                        super._update(from, r, t);
                        value -= t;
                    }
                }
            }
        }
        super._update(from, to, value);
    }
}
