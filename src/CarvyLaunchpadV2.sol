// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {CarvyRuneToken} from "./CarvyRuneToken.sol";
import {CarvyBridge} from "./CarvyBridge.sol";
import {CarvyHook} from "./CarvyHook.sol";

/// @title CarvyLaunchpadV2
/// @notice One-click Bitcoin Rune launches with an on-chain bonding curve that graduates into Uniswap V4.
///  - 1,000,000,000 fixed supply, constant-product curve with virtual reserves in the chosen quote asset
///    (native ETH or an allow-listed ERC20).
///  - Platform fee 1% on curve trades: 50% creator side, 50% platform (20% of it to the $CARVY buyback vault).
///  - Optional creator tax chosen at launch (buy and sell, max 5% each). It applies on the curve AND, forever, in
///    the graduated Uniswap V4 pool through the shared CarvyHook.
///  - At 793,100,000 tokens sold the Rune graduates. Anyone can call migrate(): the raised quote and the matching
///    amount of tokens go into a full-range V4 pool at the final curve price; leftover tokens are burned.
///    The LP position stays in this contract forever (no function can remove liquidity); only swap fees can be
///    collected, and they go to the treasury.
contract CarvyLaunchpadV2 is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 793_100_000 ether;
    uint256 public constant VIRTUAL_TOKENS = 1_073_000_000 ether;
    uint256 public constant FEE_BPS = 100;
    uint256 public constant CREATOR_SHARE_BPS = 5_000;
    uint256 public constant BUYBACK_SHARE_BPS = 2_000;
    uint16 public constant MAX_TAX_BPS = 500;
    uint24 public constant POOL_FEE = 3_000; // 0.3% LP fee, collected to the treasury
    int24 public constant TICK_SPACING = 60;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public constant NATIVE = address(0);
    IAllowanceTransfer public constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

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
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        bool graduated;
        bool migrated;
        uint256 vQuote;
        uint256 vToken;
        uint256 realQuote;
        uint256 sold;
        uint256 lpTokenId;
    }

    CarvyBridge public immutable bridge;
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    CarvyHook public hook;
    address public treasury;
    address public buybackVault;
    address public holderRewardsVault;

    mapping(address => uint256) public virtualQuote0;
    mapping(address => Curve) public curves;
    mapping(address => mapping(address => uint256)) public claimable;
    address[] public allRunes;

    event RuneCreated(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        string runeName,
        address quote,
        uint8 feeMode,
        address feeRecipient,
        string metadataURI,
        uint16 buyTaxBps,
        uint16 sellTaxBps
    );
    event Trade(address indexed token, address indexed trader, bool isBuy, uint256 quoteAmount, uint256 tokenAmount, uint256 fee, uint256 vQuote, uint256 vToken, uint256 sold);
    event Graduated(address indexed token, uint256 realQuote);
    event Migrated(address indexed token, uint256 quoteAmount, uint256 tokenAmount, uint256 lpTokenId, bytes32 poolId);
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
    error HookAlreadySet();

    constructor(
        CarvyBridge bridge_,
        IPoolManager pm,
        IPositionManager posm,
        address owner_,
        address treasury_,
        address buybackVault_,
        address holderRewardsVault_
    ) Ownable(owner_) {
        bridge = bridge_;
        poolManager = pm;
        positionManager = posm;
        treasury = treasury_;
        buybackVault = buybackVault_;
        holderRewardsVault = holderRewardsVault_;
    }

    receive() external payable {}

    // ------------------------------------------------------------------ admin

    function setHook(CarvyHook h) external onlyOwner {
        if (address(hook) != address(0)) revert HookAlreadySet();
        hook = h;
    }

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

    // ------------------------------------------------------------------ launch

    struct CreateParams {
        string name;
        string symbol;
        string runeName;
        string metadataURI;
        address quote;
        FeeMode feeMode;
        address routedTo;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint256 initialBuy;
        uint256 minTokensOut;
    }

    function createRune(CreateParams calldata p) external payable nonReentrant returns (address token) {
        uint256 v0 = virtualQuote0[p.quote];
        if (v0 == 0) revert QuoteNotAllowed();
        if (bytes(p.symbol).length == 0 || bytes(p.symbol).length > 10 || bytes(p.runeName).length == 0 || bytes(p.runeName).length > 40) revert BadParams();
        if (p.buyTaxBps > MAX_TAX_BPS || p.sellTaxBps > MAX_TAX_BPS) revert BadParams();
        if (p.quote != NATIVE && msg.value != 0) revert BadAmount();
        if (p.quote == NATIVE && msg.value != p.initialBuy) revert BadAmount();

        token = address(new CarvyRuneToken(p.name, p.symbol, p.runeName, address(this), address(bridge)));
        bridge.register(token);

        address recipient = p.feeMode == FeeMode.Dev ? msg.sender : p.feeMode == FeeMode.Holders ? holderRewardsVault : p.routedTo;
        if (recipient == address(0)) revert BadParams();

        Curve storage c = curves[token];
        c.creator = msg.sender;
        c.quote = p.quote;
        c.feeRecipient = recipient;
        c.feeMode = p.feeMode;
        c.buyTaxBps = p.buyTaxBps;
        c.sellTaxBps = p.sellTaxBps;
        c.vQuote = v0;
        c.vToken = VIRTUAL_TOKENS;
        allRunes.push(token);
        emit RuneCreated(token, msg.sender, p.name, p.symbol, p.runeName, p.quote, uint8(p.feeMode), recipient, p.metadataURI, p.buyTaxBps, p.sellTaxBps);

        if (p.initialBuy > 0) {
            if (p.quote != NATIVE) IERC20(p.quote).safeTransferFrom(msg.sender, address(this), p.initialBuy);
            _buy(token, p.initialBuy, p.minTokensOut, msg.sender);
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
        uint256 tax = (gross * c.sellTaxBps) / 10_000;
        out = gross - fee - tax;
        if (out < minQuoteOut || out == 0) revert Slippage();

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        c.vQuote = newVQuote;
        c.vToken = newVToken;
        c.realQuote -= gross;
        c.sold -= tokenAmount;
        _accrue(c, fee, tax);
        _pay(c.quote, msg.sender, out);
        emit Trade(token, msg.sender, false, out, tokenAmount, fee + tax, c.vQuote, c.vToken, c.sold);
    }

    function _buy(address token, uint256 amountIn, uint256 minTokensOut, address buyer) internal returns (uint256 out) {
        Curve storage c = curves[token];
        if (c.graduated) revert CurveClosed();
        if (amountIn == 0) revert BadAmount();

        uint256 cut = FEE_BPS + c.buyTaxBps;
        uint256 fee = (amountIn * FEE_BPS) / 10_000;
        uint256 tax = (amountIn * c.buyTaxBps) / 10_000;
        uint256 net = amountIn - fee - tax;
        uint256 k = c.vQuote * c.vToken;
        uint256 newVQuote = c.vQuote + net;
        uint256 newVToken = Math.ceilDiv(k, newVQuote);
        out = c.vToken - newVToken;

        uint256 refund;
        uint256 left = CURVE_SUPPLY - c.sold;
        if (out >= left) {
            out = left;
            newVToken = c.vToken - out;
            newVQuote = Math.ceilDiv(k, newVToken);
            net = newVQuote - c.vQuote;
            uint256 gross = Math.ceilDiv(net * 10_000, 10_000 - cut);
            if (gross > amountIn) gross = amountIn;
            fee = (gross * FEE_BPS) / 10_000;
            tax = gross - net - fee;
            refund = amountIn - gross;
        }
        if (out < minTokensOut || out == 0) revert Slippage();

        c.vQuote = newVQuote;
        c.vToken = newVToken;
        c.realQuote += net;
        c.sold += out;
        _accrue(c, fee, tax);
        IERC20(token).safeTransfer(buyer, out);
        if (refund > 0) _pay(c.quote, buyer, refund);
        emit Trade(token, buyer, true, amountIn - refund, out, fee + tax, c.vQuote, c.vToken, c.sold);

        if (c.sold >= CURVE_SUPPLY) {
            c.graduated = true;
            emit Graduated(token, c.realQuote);
        }
    }

    // ------------------------------------------------------------------ graduation -> Uniswap V4

    function poolKeyOf(address token) public view returns (PoolKey memory key, bool quoteIs0) {
        address q = curves[token].quote;
        quoteIs0 = q < token; // native ETH (0x0) is always currency0
        (address a, address b) = quoteIs0 ? (q, token) : (token, q);
        key = PoolKey({currency0: Currency.wrap(a), currency1: Currency.wrap(b), fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))});
    }

    /// @notice Anyone can migrate a graduated Rune into its Uniswap V4 pool.
    function migrate(address token) external nonReentrant {
        Curve storage c = curves[token];
        if (!c.graduated) revert NotGraduated();
        if (c.migrated || address(hook) == address(0)) revert CurveClosed();
        c.migrated = true;

        uint256 q = c.realQuote;
        c.realQuote = 0;
        uint256 bal = IERC20(token).balanceOf(address(this));
        // tokens matching the raised quote at the final curve price
        uint256 t = FullMath.mulDiv(q, c.vToken, c.vQuote);
        if (t > bal) t = bal;
        if (bal > t) IERC20(token).safeTransfer(DEAD, bal - t);

        (PoolKey memory key, bool quoteIs0) = poolKeyOf(token);
        hook.register(key, quoteIs0, c.buyTaxBps, c.sellTaxBps, c.feeRecipient);
        (uint256 a0, uint256 a1) = quoteIs0 ? (q, t) : (t, q);
        uint160 sqrtP = _sqrtPrice(a0, a1);
        poolManager.initialize(key, sqrtP);

        c.lpTokenId = _mintFullRange(key, sqrtP, a0, a1);
        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust > 0) IERC20(token).safeTransfer(DEAD, dust);
        emit Migrated(token, q, t, c.lpTokenId, keccak256(abi.encode(key)));
    }

    function _sqrtPrice(uint256 a0, uint256 a1) internal pure returns (uint160) {
        // price = amount1 / amount0  ->  sqrtPriceX96 = sqrt(a1 / a0) * 2^96
        uint256 s = Math.sqrt(FullMath.mulDiv(a1, 1 << 192, a0));
        if (s < TickMath.MIN_SQRT_PRICE) s = TickMath.MIN_SQRT_PRICE + 1;
        if (s >= TickMath.MAX_SQRT_PRICE) s = TickMath.MAX_SQRT_PRICE - 1;
        return uint160(s);
    }

    function _mintFullRange(PoolKey memory key, uint160 sqrtP, uint256 a0, uint256 a1) internal returns (uint256 tokenId) {
        int24 lo = TickMath.minUsableTick(TICK_SPACING);
        int24 hi = TickMath.maxUsableTick(TICK_SPACING);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), a0, a1);
        uint256 value;
        address c0 = Currency.unwrap(key.currency0);
        if (c0 == NATIVE) value = a0;
        else _approvePermit2(c0, a0);
        _approvePermit2(Currency.unwrap(key.currency1), a1);

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, lo, hi, uint256(liq), uint128(a0), uint128(a1), address(this), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, address(this)); // sweep native dust back here
        tokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities{value: value}(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)), params), block.timestamp
        );
    }

    function _approvePermit2(address token, uint256 amount) internal {
        IERC20(token).forceApprove(address(PERMIT2), amount);
        PERMIT2.approve(token, address(positionManager), uint160(amount), uint48(block.timestamp));
    }

    /// @notice Collect LP swap fees of a graduated Rune to the treasury. Liquidity itself can never be removed.
    function collectPoolFees(address token) external nonReentrant {
        Curve storage c = curves[token];
        if (!c.migrated) revert NotGraduated();
        (PoolKey memory key,) = poolKeyOf(token);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(c.lpTokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, treasury);
        positionManager.modifyLiquidities(abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params), block.timestamp);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ fees

    function _accrue(Curve storage c, uint256 fee, uint256 tax) internal {
        uint256 creatorPart = (fee * CREATOR_SHARE_BPS) / 10_000;
        uint256 platform = fee - creatorPart;
        uint256 buyback = (platform * BUYBACK_SHARE_BPS) / 10_000;
        claimable[c.feeRecipient][c.quote] += creatorPart + tax;
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
        uint256 net = amountIn - (amountIn * FEE_BPS) / 10_000 - (amountIn * c.buyTaxBps) / 10_000;
        out = c.vToken - Math.ceilDiv(c.vQuote * c.vToken, c.vQuote + net);
        uint256 left = CURVE_SUPPLY - c.sold;
        if (out > left) out = left;
    }

    function quoteSell(address token, uint256 tokenAmount) external view returns (uint256 out) {
        Curve storage c = curves[token];
        uint256 gross = c.vQuote - Math.ceilDiv(c.vQuote * c.vToken, c.vToken + tokenAmount);
        if (gross > c.realQuote) gross = c.realQuote;
        out = gross - (gross * FEE_BPS) / 10_000 - (gross * c.sellTaxBps) / 10_000;
    }
}
