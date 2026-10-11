// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title RnnnFeeHook
/// @notice Uniswap v4 hook for the rnnn.bid (RNNN) / IMD pool with exactly one rule: on every swap,
/// 1% of the swap's IMD amount is taken, in IMD, and sent to a fixed recipient.
///
/// @dev Design, in short:
/// - No owner, no pause, no mint, no other fee, no setter. Every parameter is an immutable set in the
///   constructor. There is no function that only a privileged address may call.
/// - The fee is always taken on the IMD side, never on RNNN, and is never swapped for anything.
/// - When IMD is the swap's *specified* currency (exact-input buy, exact-output sell) the fee is
///   taken in `beforeSwap` through `beforeSwapReturnDelta`: the pool trades 1% less (buy) or 1% more
///   (sell) IMD than the trader specified, and the difference is credited to the hook.
/// - When IMD is the *unspecified* currency (exact-output buy, exact-input sell) the fee is taken in
///   `afterSwap` through `afterSwapReturnDelta`, from the IMD amount the pool computed.
/// - In `afterSwap` the credit is paid out at once with `poolManager.take(imd, feeRecipient, fee)`
///   whenever the PoolManager already holds enough IMD (it always does once the pool has traded, and
///   on every sell). On the first buys into a pool seeded with RNNN only, the manager has no IMD yet
///   (the trader's input is settled after the hook runs), so the hook instead mints itself an
///   ERC-6909 claim on IMD. Pending claims are paid to the recipient automatically by the next swap
///   that finds enough IMD in the manager, and anyone may call `redeemPendingFees` at any time.
/// - `beforeInitialize` only admits pools that contain IMD, so the hook is never attached to a pool
///   whose fee it could not take in IMD. It does not touch the LP fee or any other pool parameter.
contract RnnnFeeHook is IHooks, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;

    /// @notice Fee on the IMD side of every swap, in basis points: 100 = 1%.
    uint256 public constant FEE_BPS = 100;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice The Uniswap v4 PoolManager this hook serves. Set once.
    IPoolManager public immutable poolManager;

    /// @notice The IMD token (the pool's paired currency). The fee is taken on this side only.
    Currency public immutable imd;

    /// @notice Where every fee goes, as IMD. Set once; nothing can change it.
    address public immutable feeRecipient;

    /// @notice A fee was accounted for a swap. `paidNow` says whether it was transferred to the
    /// recipient within the swap or left pending as an ERC-6909 claim.
    event FeeTaken(PoolId indexed poolId, uint256 amount, bool paidNow);

    /// @notice Pending fees held as ERC-6909 claims were transferred to the recipient, as IMD.
    event PendingFeesRedeemed(address indexed caller, uint256 amount);

    error NotPoolManager();
    error HookNotImplemented();
    error ZeroAddress();
    error PoolMustIncludeImd();
    error NothingToRedeem();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param poolManager_ The chain's Uniswap v4 PoolManager.
    /// @param imd_ The IMD ERC-20 the launch pool pairs with.
    /// @param feeRecipient_ The address that receives every fee, in IMD. Immutable.
    /// @dev The constructor stores values and validates its own address; it calls no other contract.
    constructor(IPoolManager poolManager_, address imd_, address feeRecipient_) {
        if (address(poolManager_) == address(0) || imd_ == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        imd = Currency.wrap(imd_);
        feeRecipient = feeRecipient_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------------------------------

    /// @notice The callbacks this hook implements. The hook address must carry exactly these bits.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Fees already owed to the recipient but not yet transferred, held by the hook as
    /// ERC-6909 claims on IMD inside the PoolManager.
    function pendingFees() public view returns (uint256) {
        return poolManager.balanceOf(address(this), imd.toId());
    }

    /// @notice The fee the hook takes for an IMD amount of `imdAmount`.
    function feeFor(uint256 imdAmount) public pure returns (uint256) {
        return imdAmount * FEE_BPS / BPS_DENOMINATOR;
    }

    // ---------------------------------------------------------------------------------------------
    // Pending fee redemption (permissionless)
    // ---------------------------------------------------------------------------------------------

    /// @notice Transfers pending fees to the recipient, as IMD. Anyone may call it. Transfers as much
    /// of the pending amount as the PoolManager's IMD balance covers.
    /// @return amount The IMD amount transferred to the recipient.
    function redeemPendingFees() external returns (uint256 amount) {
        amount = _redeemable();
        if (amount == 0) revert NothingToRedeem();
        poolManager.unlock(abi.encode(msg.sender));
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Reached only through `redeemPendingFees`: the PoolManager calls back whoever unlocked it,
    /// and this hook is the only caller that unlocks it on its own behalf. The data carries the
    /// address that called `redeemPendingFees`, used for the event only; the amount is re-read.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 amount = _redeemable();
        if (amount == 0) revert NothingToRedeem();
        _payPending(amount, abi.decode(data, (address)));
        return "";
    }

    // ---------------------------------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Admits any pool that includes IMD, at whatever LP fee and tick spacing the initializer
    /// chose. Refuses pools without IMD: the hook could not take its fee in IMD there.
    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (!(key.currency0 == imd || key.currency1 == imd)) revert PoolMustIncludeImd();
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    /// @dev When IMD is the specified currency, returns a specified-delta of +fee: the pool trades
    /// `amountSpecified` adjusted by the fee and the fee is credited to the hook. The LP fee is never
    /// overridden (the third return value is 0 and the pool is not a dynamic-fee pool).
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_specifiedCurrency(key, params) == imd) {
            uint256 fee = feeFor(_abs(params.amountSpecified));
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc IHooks
    /// @dev Computes the fee (from `amountSpecified` when IMD was specified, so it matches what
    /// `beforeSwap` already credited; from the pool's IMD delta otherwise, returned as the
    /// unspecified delta) and pays it out or records it as a pending claim.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        uint256 fee;
        int128 hookDeltaUnspecified;
        if (_specifiedCurrency(key, params) == imd) {
            fee = feeFor(_abs(params.amountSpecified));
        } else {
            int128 imdDelta = key.currency0 == imd ? delta.amount0() : delta.amount1();
            fee = feeFor(_abs(int256(imdDelta)));
            hookDeltaUnspecified = fee.toInt128();
        }
        if (fee > 0) _collect(key, fee);
        return (IHooks.afterSwap.selector, hookDeltaUnspecified);
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Settles a fee credit of `fee` IMD that the PoolManager owes (or is about to owe) this
    /// hook for the current swap. Pays the recipient directly when the manager's IMD balance covers
    /// it, and flushes any older pending claims when the balance covers those too. Otherwise records
    /// the fee as an ERC-6909 claim the hook holds for the recipient.
    function _collect(PoolKey calldata key, uint256 fee) internal {
        uint256 available = imd.balanceOf(address(poolManager));
        if (available >= fee) {
            poolManager.take(imd, feeRecipient, fee);
            emit FeeTaken(key.toId(), fee, true);
            uint256 pending = pendingFees();
            if (pending > 0 && available - fee >= pending) _payPending(pending, address(this));
        } else {
            poolManager.mint(address(this), imd.toId(), fee);
            emit FeeTaken(key.toId(), fee, false);
        }
    }

    /// @dev Burns `amount` of the hook's IMD claims and transfers that IMD to the recipient.
    function _payPending(uint256 amount, address caller) internal {
        poolManager.burn(address(this), imd.toId(), amount);
        poolManager.take(imd, feeRecipient, amount);
        emit PendingFeesRedeemed(caller, amount);
    }

    /// @dev The pending amount the PoolManager's IMD balance can pay right now.
    function _redeemable() internal view returns (uint256) {
        uint256 pending = pendingFees();
        uint256 available = imd.balanceOf(address(poolManager));
        return pending < available ? pending : available;
    }

    /// @dev The currency `params.amountSpecified` is denominated in: the input for exact-input
    /// swaps, the output for exact-output swaps.
    function _specifiedCurrency(PoolKey calldata key, SwapParams calldata params) internal pure returns (Currency) {
        return (params.amountSpecified < 0) == params.zeroForOne ? key.currency0 : key.currency1;
    }

    function _abs(int256 value) internal pure returns (uint256) {
        return value < 0 ? uint256(-value) : uint256(value);
    }
}
