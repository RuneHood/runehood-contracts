// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/*
 *  Carvy graduation hook (Uniswap V4) - one hook per chain, shared by every graduated Carvy Rune pool.
 *
 *  - Only the Carvy launchpad can create pools with this hook, so every pool is an official graduated Rune.
 *  - Each pool carries the creator tax chosen at launch (buy and sell, max 5% each). The tax is fixed for the
 *    life of the pool and paid to the creator's fee recipient, in the quote asset whenever that side can be
 *    charged (exact-input buys, exact-input sells), otherwise in the Rune token.
 *  - Wallet transfers are never taxed: only swaps in the official pool are.
 */

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

contract CarvyHook is IHooks {
    using PoolIdLibrary for PoolKey;

    struct Tax {
        bool quoteIs0;
        uint16 buyBps;
        uint16 sellBps;
        address recipient;
        bool registered;
    }

    uint16 public constant MAX_TAX_BPS = 500;

    IPoolManager public immutable poolManager;
    address public immutable launchpad;
    mapping(PoolId => Tax) public taxes;

    event PoolRegistered(PoolId indexed id, address token, uint16 buyBps, uint16 sellBps, address recipient);
    event Taxed(PoolId indexed id, bool buy, Currency currency, uint256 amount);

    error NotPoolManager();
    error NotLaunchpad();
    error NotRegistered();
    error TaxTooHigh();
    error HookNotImplemented();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager pm, address launchpad_) {
        poolManager = pm;
        launchpad = launchpad_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// Called by the launchpad right before it initializes the graduated pool.
    function register(PoolKey calldata key, bool quoteIs0, uint16 buyBps, uint16 sellBps, address recipient) external {
        if (msg.sender != launchpad) revert NotLaunchpad();
        if (buyBps > MAX_TAX_BPS || sellBps > MAX_TAX_BPS) revert TaxTooHigh();
        PoolId id = key.toId();
        taxes[id] = Tax(quoteIs0, buyBps, sellBps, recipient, true);
        emit PoolRegistered(id, Currency.unwrap(quoteIs0 ? key.currency1 : key.currency0), buyBps, sellBps, recipient);
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (sender != launchpad) revert NotLaunchpad();
        if (!taxes[key.toId()].registered) revert NotRegistered();
        return IHooks.beforeInitialize.selector;
    }

    /// buy == swapping the quote asset into the Rune token.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Tax memory t = taxes[id];
        bool buy = params.zeroForOne == t.quoteIs0;
        // exact-input buy: cut the tax from the quote going in
        if (!(buy && params.amountSpecified < 0) || t.buyBps == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 fee = (uint256(-params.amountSpecified) * t.buyBps) / 10_000;
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        Currency c = params.zeroForOne ? key.currency0 : key.currency1; // input currency
        poolManager.take(c, t.recipient, fee);
        emit Taxed(id, true, c, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        Tax memory t = taxes[id];
        bool buy = params.zeroForOne == t.quoteIs0;
        bool exactIn = params.amountSpecified < 0;
        if (buy && exactIn) return (IHooks.afterSwap.selector, 0);
        uint256 bps = buy ? t.buyBps : t.sellBps;
        if (bps == 0) return (IHooks.afterSwap.selector, 0);
        // unspecified currency: exact-in -> output side, exact-out -> input side
        bool unspecifiedIs0 = exactIn ? !params.zeroForOne : params.zeroForOne;
        int128 amt = unspecifiedIs0 ? delta.amount0() : delta.amount1();
        uint256 abs = amt < 0 ? uint256(uint128(-amt)) : uint256(uint128(amt));
        uint256 fee = (abs * bps) / 10_000;
        if (fee == 0) return (IHooks.afterSwap.selector, 0);
        Currency c = unspecifiedIs0 ? key.currency0 : key.currency1;
        poolManager.take(c, t.recipient, fee);
        emit Taxed(id, buy, c, fee);
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    // ----------------------------------------------------------------- unused hooks

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
