// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CarvyRuneToken} from "./CarvyRuneToken.sol";
import {CarvyBridge} from "./CarvyBridge.sol";

interface IUniswapV2Router02 {
    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256 amountTokenMin, uint256 amountETHMin, address to, uint256 deadline)
        external
        payable
        returns (uint256, uint256, uint256);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256, uint256, uint256);
}

/// @title CarvyLaunchpad
/// @notice One-click Bitcoin Rune launches with an on-chain bonding curve on this chain.
///  Every Rune: 1,000,000,000 fixed supply, constant-product curve with virtual reserves in the creator's chosen
///  quote asset (native ETH or an allow-listed ERC20 such as WBTC, cbBTC, USDC). When 793,100,000 tokens are sold
///  the Rune graduates and anyone can migrate the remaining tokens + raised quote into a DEX pool whose LP is burned.
///  Trading fee 1%: 50% creator side (dev wallet, routed wallet, or holder rewards vault), 50% platform, of which
///  20% goes to the $CARVY buyback-and-burn vault. Fees accrue and are claimed (pull), so a bad recipient can never
///  block trading.
contract CarvyLaunchpad is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 793_100_000 ether;
    uint256 public constant VIRTUAL_TOKENS = 1_073_000_000 ether;
    uint256 public constant FEE_BPS = 100; // 1%
    uint256 public constant CREATOR_SHARE_BPS = 5_000; // of the fee
    uint256 public constant BUYBACK_SHARE_BPS = 2_000; // of the platform part
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public constant NATIVE = address(0);

    enum FeeMode {
        Dev,
        Holders,
        Routed
    }

    struct Curve {
        address creator;
        address quote;
        address feeRecipient;
        FeeMode feeMode;
        bool graduated;
        bool migrated;
        uint256 vQuote;
        uint256 vToken;
        uint256 realQuote;
        uint256 sold;
    }

    CarvyBridge public immutable bridge;
    IUniswapV2Router02 public router; // may be zero on chains without a V2 router: owner migrates manually
    address public treasury;
    address public buybackVault;
    address public holderRewardsVault;

    /// quote asset => initial virtual quote reserve (raw units). 0 = not allowed.
    mapping(address => uint256) public virtualQuote0;
    mapping(address => Curve) public curves;
    mapping(address => mapping(address => uint256)) public claimable; // recipient => quote => amount
    address[] public allRunes;

    event RuneCreated(address indexed token, address indexed creator, string name, string symbol, string runeName, address quote, FeeMode feeMode, address feeRecipient, string metadataURI);
    event Trade(address indexed token, address indexed trader, bool isBuy, uint256 quoteAmount, uint256 tokenAmount, uint256 fee, uint256 vQuote, uint256 vToken, uint256 sold);
    event Graduated(address indexed token, uint256 realQuote);
    event Migrated(address indexed token, uint256 quoteAmount, uint256 tokenAmount);
    event Claimed(address indexed recipient, address indexed quote, uint256 amount);
    event QuoteConfigured(address quote, uint256 virtualReserve);

    error QuoteNotAllowed();
    error UnknownRune();
    error CurveClosed();
    error Slippage();
    error BadAmount();
    error BadParams();
    error TransferFailed();
    error NotGraduated();

    constructor(CarvyBridge bridge_, address owner_, address treasury_, address buybackVault_, address holderRewardsVault_, IUniswapV2Router02 router_)
        Ownable(owner_)
    {
        bridge = bridge_;
        treasury = treasury_;
        buybackVault = buybackVault_;
        holderRewardsVault = holderRewardsVault_;
        router = router_;
    }

    // ------------------------------------------------------------------ admin

    function configureQuote(address quote, uint256 virtualReserve) external onlyOwner {
        virtualQuote0[quote] = virtualReserve;
        emit QuoteConfigured(quote, virtualReserve);
    }

    function setVaults(address treasury_, address buybackVault_, address holderRewardsVault_) external onlyOwner {
        if (treasury_ == address(0) || buybackVault_ == address(0) || holderRewardsVault_ == address(0)) revert BadParams();
        treasury = treasury_;
        buybackVault = buybackVault_;
        holderRewardsVault = holderRewardsVault_;
    }

    function setRouter(IUniswapV2Router02 r) external onlyOwner {
        router = r;
    }

    // ------------------------------------------------------------------ launch

    function createRune(
        string calldata name,
        string calldata symbol,
        string calldata runeName,
        string calldata metadataURI,
        address quote,
        FeeMode feeMode,
        address routedTo,
        uint256 initialBuy,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token) {
        uint256 v0 = virtualQuote0[quote];
        if (v0 == 0) revert QuoteNotAllowed();
        if (bytes(symbol).length == 0 || bytes(symbol).length > 10 || bytes(runeName).length == 0 || bytes(runeName).length > 40) revert BadParams();
        if (quote != NATIVE && msg.value != 0) revert BadAmount();
        if (quote == NATIVE && msg.value != initialBuy) revert BadAmount();

        token = address(new CarvyRuneToken(name, symbol, runeName, address(this), address(bridge)));
        bridge.register(token);

        address recipient = feeMode == FeeMode.Dev ? msg.sender : feeMode == FeeMode.Holders ? holderRewardsVault : routedTo;
        if (recipient == address(0)) revert BadParams();

        curves[token] = Curve({
            creator: msg.sender,
            quote: quote,
            feeRecipient: recipient,
            feeMode: feeMode,
            graduated: false,
            migrated: false,
            vQuote: v0,
            vToken: VIRTUAL_TOKENS,
            realQuote: 0,
            sold: 0
        });
        allRunes.push(token);
        emit RuneCreated(token, msg.sender, name, symbol, runeName, quote, feeMode, recipient, metadataURI);

        if (initialBuy > 0) {
            if (quote != NATIVE) IERC20(quote).safeTransferFrom(msg.sender, address(this), initialBuy);
            _buy(token, initialBuy, minTokensOut, msg.sender);
        }
    }

    // ------------------------------------------------------------------ trade

    function buy(address token, uint256 amountIn, uint256 minTokensOut) external payable nonReentrant returns (uint256 out) {
        Curve storage c = curves[token];
        if (c.creator == address(0)) revert UnknownRune();
        if (c.quote == NATIVE) {
            if (msg.value != amountIn) revert BadAmount();
        } else {
            if (msg.value != 0) revert BadAmount();
            IERC20(c.quote).safeTransferFrom(msg.sender, address(this), amountIn);
        }
        out = _buy(token, amountIn, minTokensOut, msg.sender);
    }

    function sell(address token, uint256 tokenAmount, uint256 minQuoteOut) external nonReentrant returns (uint256 out) {
        Curve storage c = curves[token];
        if (c.creator == address(0)) revert UnknownRune();
        if (c.graduated) revert CurveClosed();
        if (tokenAmount == 0 || tokenAmount > c.sold) revert BadAmount();

        uint256 k = c.vQuote * c.vToken;
        uint256 newVToken = c.vToken + tokenAmount;
        uint256 newVQuote = Math.ceilDiv(k, newVToken);
        uint256 gross = c.vQuote - newVQuote;
        if (gross > c.realQuote) gross = c.realQuote;
        uint256 fee = (gross * FEE_BPS) / 10_000;
        out = gross - fee;
        if (out < minQuoteOut || out == 0) revert Slippage();

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        c.vQuote = newVQuote;
        c.vToken = newVToken;
        c.realQuote -= gross;
        c.sold -= tokenAmount;
        _accrueFee(c, fee);
        _pay(c.quote, msg.sender, out);
        emit Trade(token, msg.sender, false, out, tokenAmount, fee, c.vQuote, c.vToken, c.sold);
    }

    function _buy(address token, uint256 amountIn, uint256 minTokensOut, address buyer) internal returns (uint256 out) {
        Curve storage c = curves[token];
        if (c.graduated) revert CurveClosed();
        if (amountIn == 0) revert BadAmount();

        uint256 fee = (amountIn * FEE_BPS) / 10_000;
        uint256 net = amountIn - fee;
        uint256 k = c.vQuote * c.vToken;
        uint256 newVQuote = c.vQuote + net;
        uint256 newVToken = Math.ceilDiv(k, newVQuote);
        out = c.vToken - newVToken;

        uint256 refund;
        uint256 left = CURVE_SUPPLY - c.sold;
        if (out >= left) {
            // last buy: take exactly what is left and refund the rest
            out = left;
            newVToken = c.vToken - out;
            newVQuote = Math.ceilDiv(k, newVToken);
            net = newVQuote - c.vQuote;
            fee = (net * FEE_BPS) / (10_000 - FEE_BPS);
            refund = amountIn - net - fee;
        }
        if (out < minTokensOut || out == 0) revert Slippage();

        c.vQuote = newVQuote;
        c.vToken = newVToken;
        c.realQuote += net;
        c.sold += out;
        _accrueFee(c, fee);
        IERC20(token).safeTransfer(buyer, out);
        if (refund > 0) _pay(c.quote, buyer, refund);
        emit Trade(token, buyer, true, amountIn - refund, out, fee, c.vQuote, c.vToken, c.sold);

        if (c.sold >= CURVE_SUPPLY) {
            c.graduated = true;
            emit Graduated(token, c.realQuote);
        }
    }

    // ------------------------------------------------------------------ graduation

    /// @notice Anyone can migrate a graduated Rune into the configured V2-style DEX. LP tokens go to the dead address.
    function migrate(address token) external nonReentrant {
        Curve storage c = curves[token];
        if (!c.graduated) revert NotGraduated();
        if (c.migrated || address(router) == address(0)) revert CurveClosed();
        c.migrated = true;
        uint256 q = c.realQuote;
        uint256 t = IERC20(token).balanceOf(address(this));
        c.realQuote = 0;
        IERC20(token).forceApprove(address(router), t);
        if (c.quote == NATIVE) {
            router.addLiquidityETH{value: q}(token, t, 0, 0, DEAD, block.timestamp);
        } else {
            IERC20(c.quote).forceApprove(address(router), q);
            router.addLiquidity(token, c.quote, t, q, 0, 0, DEAD, block.timestamp);
        }
        emit Migrated(token, q, t);
    }

    /// @notice Fallback for chains without a V2 router: the owner moves graduated liquidity to a pool contract.
    ///         Only possible for graduated Runes, only once, and fully visible on chain.
    function migrateTo(address token, address pool) external onlyOwner nonReentrant {
        Curve storage c = curves[token];
        if (!c.graduated || c.migrated || pool == address(0)) revert NotGraduated();
        c.migrated = true;
        uint256 q = c.realQuote;
        uint256 t = IERC20(token).balanceOf(address(this));
        c.realQuote = 0;
        IERC20(token).safeTransfer(pool, t);
        _pay(c.quote, pool, q);
        emit Migrated(token, q, t);
    }

    // ------------------------------------------------------------------ fees

    function _accrueFee(Curve storage c, uint256 fee) internal {
        if (fee == 0) return;
        uint256 creatorPart = (fee * CREATOR_SHARE_BPS) / 10_000;
        uint256 platform = fee - creatorPart;
        uint256 buyback = (platform * BUYBACK_SHARE_BPS) / 10_000;
        claimable[c.feeRecipient][c.quote] += creatorPart;
        claimable[buybackVault][c.quote] += buyback;
        claimable[treasury][c.quote] += platform - buyback;
    }

    function claim(address quote) external nonReentrant {
        uint256 a = claimable[msg.sender][quote];
        if (a == 0) revert BadAmount();
        claimable[msg.sender][quote] = 0;
        _pay(quote, msg.sender, a);
        emit Claimed(msg.sender, quote, a);
    }

    function _pay(address quote, address to, uint256 amount) internal {
        if (quote == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(quote).safeTransfer(to, amount);
        }
    }

    // ------------------------------------------------------------------ views

    function runesCount() external view returns (uint256) {
        return allRunes.length;
    }

    function quoteBuy(address token, uint256 amountIn) external view returns (uint256 out) {
        Curve storage c = curves[token];
        uint256 net = amountIn - (amountIn * FEE_BPS) / 10_000;
        out = c.vToken - Math.ceilDiv(c.vQuote * c.vToken, c.vQuote + net);
        uint256 left = CURVE_SUPPLY - c.sold;
        if (out > left) out = left;
    }

    function quoteSell(address token, uint256 tokenAmount) external view returns (uint256 out) {
        Curve storage c = curves[token];
        uint256 gross = c.vQuote - Math.ceilDiv(c.vQuote * c.vToken, c.vToken + tokenAmount);
        if (gross > c.realQuote) gross = c.realQuote;
        out = gross - (gross * FEE_BPS) / 10_000;
    }

    /// @notice Price of 1 whole token in raw quote units, scaled by 1e18.
    function price(address token) external view returns (uint256) {
        Curve storage c = curves[token];
        return (c.vQuote * 1e18) / (c.vToken / 1e18);
    }
}
