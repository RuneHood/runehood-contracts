// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IPancakeFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPancakePair {
    function mint(address to) external returns (uint256 liquidity);
}

interface IWETH {
    function deposit() external payable;
}

import {CarvyRuneTokenTax} from "./CarvyRuneTokenTax.sol";
import {CarvyBridge} from "./CarvyBridge.sol";

/// @title CarvyLaunchpadPancake
/// @notice Carvy launchpad for BNB Chain: same bonding curve and fees as CarvyLaunchpadV2, but graduation goes into
///         a PancakeSwap V2 pair (the main DEX on BNB Chain).
///  - The pair is created at launch and stays closed (token-level guard) until graduation, so its price cannot be
///    front-run.
///  - At 793,100,000 tokens sold anyone can call migrate(): the raised quote and the matching tokens are added to
///    the pair at the final curve price; leftover tokens are burned. The LP tokens stay in this contract forever.
///  - The creator tax (max 5% buy / 5% sell) keeps working after graduation, enforced by the token on pair trades.
contract CarvyLaunchpadPancake is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 793_100_000 ether;
    uint256 public constant VIRTUAL_TOKENS = 1_073_000_000 ether;
    uint256 public constant FEE_BPS = 100;
    uint256 public constant CREATOR_SHARE_BPS = 5_000;
    uint256 public constant BUYBACK_SHARE_BPS = 2_000;
    uint16 public constant MAX_TAX_BPS = 500;
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
    IPancakeFactory public immutable factory;
    address public immutable wrappedNative;
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

    constructor(
        CarvyBridge bridge_,
        IPancakeFactory factory_,
        address wrappedNative_,
        address owner_,
        address treasury_,
        address buybackVault_,
        address holderRewardsVault_
    ) Ownable(owner_) {
        bridge = bridge_;
        factory = factory_;
        wrappedNative = wrappedNative_;
        treasury = treasury_;
        buybackVault = buybackVault_;
        holderRewardsVault = holderRewardsVault_;
    }

    receive() external payable {}

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

        token = address(new CarvyRuneTokenTax(p.name, p.symbol, p.runeName, address(this), address(bridge)));
        bridge.register(token);
        CarvyRuneTokenTax(token).setPair(factory.createPair(token, p.quote == NATIVE ? wrappedNative : p.quote));

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

    // ------------------------------------------------------------------ graduation -> PancakeSwap V2

    /// @notice Anyone can migrate a graduated Rune into its PancakeSwap pair.
    function migrate(address token) external nonReentrant {
        Curve storage c = curves[token];
        if (!c.graduated) revert NotGraduated();
        if (c.migrated) revert CurveClosed();
        c.migrated = true;

        uint256 q = c.realQuote;
        c.realQuote = 0;
        uint256 bal = IERC20(token).balanceOf(address(this));
        // tokens matching the raised quote at the final curve price
        uint256 t = Math.mulDiv(q, c.vToken, c.vQuote);
        if (t > bal) t = bal;
        if (bal > t) IERC20(token).safeTransfer(DEAD, bal - t);

        address pair = CarvyRuneTokenTax(token).pair();
        IERC20(token).safeTransfer(pair, t);
        if (c.quote == NATIVE) {
            IWETH(wrappedNative).deposit{value: q}();
            IERC20(wrappedNative).safeTransfer(pair, q);
        } else {
            IERC20(c.quote).safeTransfer(pair, q);
        }
        uint256 liquidity = IPancakePair(pair).mint(address(this)); // LP locked here forever
        c.lpTokenId = liquidity;
        CarvyRuneTokenTax(token).openPair(c.buyTaxBps, c.sellTaxBps, c.feeRecipient);
        emit Migrated(token, q, t, liquidity, bytes32(uint256(uint160(pair))));
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
