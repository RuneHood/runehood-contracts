// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

interface IRuneLaunchpad {
    function buy(address token, uint256 amountIn, uint256 minTokensOut) external payable returns (uint256);
    function sell(address token, uint256 tokenAmount, uint256 minQuoteOut) external returns (uint256);
}

/// @title RunehoodZap
/// @notice Buy / sell a Rune whose curve is priced in an ERC-20 (e.g. a Robinhood Stock Token) using native ETH,
///         in one transaction: ETH is swapped to the quote through Uniswap V4 pools (any path), then the curve is bought;
///         selling does the reverse. Holds no funds between transactions, has no owner and no admin functions.
contract RunehoodZap is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IRuneLaunchpad public immutable launchpad;

    error NotPoolManager();
    error BadPath();
    error Slippage();
    error EthTransferFailed();

    event ZapBuy(address indexed token, address indexed buyer, uint256 ethIn, uint256 quoteIn, uint256 tokensOut);
    event ZapSell(address indexed token, address indexed seller, uint256 tokensIn, uint256 quoteOut, uint256 ethOut);

    constructor(IPoolManager _poolManager, IRuneLaunchpad _launchpad) {
        poolManager = _poolManager;
        launchpad = _launchpad;
    }

    receive() external payable {}

    /// @param path V4 pools from native ETH to the curve's quote token (no hooks needed, any length).
    function buyWithEth(address token, PoolKey[] calldata path, uint256 minQuoteOut, uint256 minTokensOut)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (path.length == 0 || msg.value == 0) revert BadPath();
        (Currency outCur, Currency inCur) = _ends(path, Currency.wrap(address(0)));
        if (Currency.unwrap(inCur) != address(0) || Currency.unwrap(outCur) == address(0)) revert BadPath();
        address quote = Currency.unwrap(outCur);

        uint256 q = _swap(path, inCur, msg.value);
        if (q < minQuoteOut) revert Slippage();

        IERC20(quote).forceApprove(address(launchpad), q);
        tokensOut = launchpad.buy(token, q, minTokensOut);
        IERC20(quote).forceApprove(address(launchpad), 0);

        IERC20(token).safeTransfer(msg.sender, IERC20(token).balanceOf(address(this)));
        uint256 left = IERC20(quote).balanceOf(address(this)); // curve refund near graduation
        if (left > 0) IERC20(quote).safeTransfer(msg.sender, left);
        emit ZapBuy(token, msg.sender, msg.value, q, tokensOut);
    }

    /// @param quote the curve's quote token (what the launchpad pays out on sell)
    /// @param path V4 pools from `quote` to native ETH.
    function sellForEth(address token, uint256 tokenAmount, address quote, PoolKey[] calldata path, uint256 minEthOut)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        if (path.length == 0 || tokenAmount == 0) revert BadPath();
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        IERC20(token).forceApprove(address(launchpad), tokenAmount);
        uint256 q = launchpad.sell(token, tokenAmount, 0);

        // the path must start at the quote the curve paid out and end in native ETH
        if (IERC20(quote).balanceOf(address(this)) < q) revert BadPath();
        Currency start = Currency.wrap(quote);
        (Currency outCur,) = _ends(path, start);
        if (Currency.unwrap(outCur) != address(0)) revert BadPath();

        ethOut = _swap(path, start, q);
        if (ethOut < minEthOut) revert Slippage();
        (bool ok,) = msg.sender.call{value: ethOut}("");
        if (!ok) revert EthTransferFailed();
        emit ZapSell(token, msg.sender, tokenAmount, q, ethOut);
    }

    // ------------------------------------------------------------------ internals

    /// Walks the path from `input`, returns (final output currency, input).
    function _ends(PoolKey[] calldata path, Currency input) internal pure returns (Currency cur, Currency inCur) {
        inCur = input;
        cur = input;
        for (uint256 i; i < path.length; i++) {
            if (cur == path[i].currency0) cur = path[i].currency1;
            else if (cur == path[i].currency1) cur = path[i].currency0;
            else revert BadPath();
        }
    }

    function _swap(PoolKey[] calldata path, Currency input, uint256 amountIn) internal returns (uint256 out) {
        out = abi.decode(poolManager.unlock(abi.encode(path, input, amountIn)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey[] memory path, Currency input, uint256 amountIn) = abi.decode(data, (PoolKey[], Currency, uint256));
        Currency cur = input;
        uint256 amt = amountIn;
        for (uint256 i; i < path.length; i++) {
            bool zf = cur == path[i].currency0;
            BalanceDelta d = poolManager.swap(
                path[i],
                SwapParams({zeroForOne: zf, amountSpecified: -int256(amt), sqrtPriceLimitX96: zf ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
                ""
            );
            int128 o = zf ? d.amount1() : d.amount0();
            amt = uint256(uint128(o));
            cur = zf ? path[i].currency1 : path[i].currency0;
        }
        // pay the input
        if (Currency.unwrap(input) == address(0)) {
            poolManager.settle{value: amountIn}();
        } else {
            poolManager.sync(input);
            IERC20(Currency.unwrap(input)).safeTransfer(address(poolManager), amountIn);
            poolManager.settle();
        }
        // receive the output
        poolManager.take(cur, address(this), amt);
        return abi.encode(amt);
    }
}
