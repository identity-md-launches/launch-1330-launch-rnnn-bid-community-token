// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolClaimsTest} from "v4-core/src/test/PoolClaimsTest.sol";

import {RnnnFeeHook} from "../../src/RnnnFeeHook.sol";
import {RnnnToken} from "../../src/RnnnToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Invariant handler for `RnnnFeeHook`. Drives the pool through random sequences of swaps of
/// every shape, liquidity changes, donations, ERC-6909 claim gifts and fee redemptions from several
/// actors, and keeps ghost accounting the invariants are checked against.
///
/// @dev Inputs are bounded so every call succeeds (the suites run with `fail-on-revert`): swap sizes
/// are small against the liquidity floor so swaps that specify IMD fill completely, and exact-output
/// sells never ask for more IMD than the pool's reserves. Property checks inside the handler never
/// assert; they count violations in ghosts, so a broken property surfaces through an invariant and
/// not through a swallowed revert.
contract RnnnFeeHookHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 public constant POOL_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /// @dev Full-range liquidity the handler never removes once it is there.
    int256 public constant LIQUIDITY_FLOOR = 1e24;
    /// @dev Smallest full-range position the handler keeps: ten times the largest swap, so swaps
    /// that specify IMD always fill and a position's accrued fees never exceed an add.
    int256 public constant MIN_FULL_RANGE = 1e22;
    /// @dev Beyond this tick a full-range add would need more of one token than the handler owns.
    int24 public constant MAX_ADD_TICK = 50_000;
    uint256 public constant MAX_SWAP = 1e21;
    uint256 public constant MAX_DONATION = 1e21;
    uint256 public constant MAX_CLAIM_GIFT = 1e21;

    PoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;
    PoolModifyLiquidityTest public immutable lpRouter;
    PoolDonateTest public immutable donateRouter;
    PoolClaimsTest public immutable claimsRouter;
    MockERC20 public immutable imd;
    RnnnToken public immutable rnnn;
    RnnnFeeHook public immutable hook;
    address public immutable recipient;
    bool public immutable rnnnIsZero;
    bool public immutable seededFullRange;
    bool public seeded;

    PoolKey public key;

    address[] public actors;

    // ---------------------------------------------------------------------------------------------
    // Ghosts
    // ---------------------------------------------------------------------------------------------

    /// @notice Sum, over every swap, of the fee the hook accounted (paid to the recipient or left
    /// pending). Measured as the change of `recipient balance + pending claims` across the swap.
    uint256 public ghost_feesAccounted;
    /// @notice Sum, over every swap, of 1% of the IMD the pool actually traded.
    uint256 public ghost_feesExpected;
    /// @notice Swaps whose accounted fee was not exactly 1% of the IMD side.
    uint256 public ghost_feeMismatches;
    /// @notice Swaps that specified IMD and did not fill completely (the handler bounds inputs so
    /// this should never happen; if it does the fee property is not what was measured).
    uint256 public ghost_partialSpecifiedFills;
    /// @notice ERC-6909 IMD claims third parties gifted to the hook.
    uint256 public ghost_claimsGifted;
    /// @notice IMD donated to the pool's LPs (sits in the manager but belongs to no swap).
    uint256 public ghost_imdDonated;
    /// @notice Upper bound on IMD LP fees accrued and still in the manager (2% of IMD input, above
    /// the 1.25% pool fee).
    uint256 public ghost_imdLpFeeBound;
    /// @notice Swaps in which the recipient's RNNN balance or the hook's own balances moved.
    uint256 public ghost_leaks;
    /// @notice Pending claims that an `afterSwap` flushed to the recipient.
    uint256 public ghost_flushed;
    /// @notice Fees paid inside the swap (not deferred).
    uint256 public ghost_paidNow;
    /// @notice Fees deferred as claims by a swap.
    uint256 public ghost_deferred;
    /// @notice `redeemPendingFees` calls that returned a value different from what the recipient got.
    uint256 public ghost_redeemMismatches;

    mapping(bytes32 => uint256) public calls;

    int256 internal fullRangeLiquidity;

    struct Before {
        uint256 recipientImd;
        uint256 recipientRnnn;
        uint256 pending;
        uint256 actorImd;
        uint256 actorRnnn;
        uint256 hookImd;
        uint256 hookRnnn;
        uint256 hookRnnnClaims;
    }

    modifier countCall(bytes32 name) {
        calls[name]++;
        _;
    }

    /// @param seedFullRange_ When true the pool starts with full-range liquidity (a funded pool);
    /// when false it starts with liquidity on the RNNN side only, the shape the launch seeds.
    constructor(
        PoolManager manager_,
        MockERC20 imd_,
        RnnnToken rnnn_,
        RnnnFeeHook hook_,
        PoolKey memory key_,
        address recipient_,
        bool seedFullRange_
    ) {
        manager = manager_;
        imd = imd_;
        rnnn = rnnn_;
        hook = hook_;
        key = key_;
        recipient = recipient_;
        rnnnIsZero = address(rnnn_) < address(imd_);
        seededFullRange = seedFullRange_;

        swapRouter = new PoolSwapTest(manager_);
        lpRouter = new PoolModifyLiquidityTest(manager_);
        donateRouter = new PoolDonateTest(manager_);
        claimsRouter = new PoolClaimsTest(manager_);

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        for (uint256 i = 0; i < actors.length; i++) {
            _approveAll(actors[i]);
        }
        _approveAll(address(this));
    }

    /// @notice Seeds the pool. Called once by the test after funding the handler with both tokens.
    function seed() external {
        require(!seeded, "already seeded");
        seeded = true;
        if (seededFullRange) {
            _modifyLiquidity(
                TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), LIQUIDITY_FLOOR
            );
            fullRangeLiquidity = LIQUIDITY_FLOOR;
        } else {
            (int24 lower, int24 upper) = rnnnIsZero
                ? (TICK_SPACING, TickMath.maxUsableTick(TICK_SPACING))
                : (TickMath.minUsableTick(TICK_SPACING), -TICK_SPACING);
            _modifyLiquidity(lower, upper, LIQUIDITY_FLOOR);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---------------------------------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------------------------------

    /// @notice Buy RNNN with an exact IMD input. IMD is the specified currency: fee in `beforeSwap`.
    function buyExactIn(uint256 actorSeed, uint256 amountIn) external countCall("buyExactIn") {
        address actor = _actor(actorSeed);
        amountIn = bound(amountIn, 1, MAX_SWAP);
        Before memory b = _before(actor);

        _swap(actor, !rnnnIsZero, -int256(amountIn));

        uint256 paid = b.actorImd - imd.balanceOf(actor);
        uint256 fee = _accountedFee(b);
        if (paid != amountIn) ghost_partialSpecifiedFills++;
        // The pool took `paid - fee`; the trader paid exactly the request; the fee is 1% of it.
        _recordFee(fee, amountIn / 100);
        ghost_imdLpFeeBound += (paid - fee) * 2 / 100;
        _checkLeaks(b);
    }

    /// @notice Buy an exact RNNN output. IMD is the unspecified currency: fee in `afterSwap`.
    function buyExactOut(uint256 actorSeed, uint256 rnnnOut) external countCall("buyExactOut") {
        address actor = _actor(actorSeed);
        rnnnOut = bound(rnnnOut, 1, MAX_SWAP);
        Before memory b = _before(actor);

        _swap(actor, !rnnnIsZero, int256(rnnnOut));

        uint256 paid = b.actorImd - imd.balanceOf(actor);
        uint256 fee = _accountedFee(b);
        // The pool charged `paid - fee` IMD; the fee is 1% of that, on top.
        _recordFee(fee, (paid - fee) / 100);
        ghost_imdLpFeeBound += (paid - fee) * 2 / 100;
        _checkLeaks(b);
    }

    /// @notice Sell an exact RNNN input. IMD is the unspecified currency: fee in `afterSwap`.
    /// A partial fill (price reaching the bottom of the liquidity) is fine here: the fee is taken
    /// from the IMD the pool actually paid.
    function sellExactIn(uint256 actorSeed, uint256 rnnnIn) external countCall("sellExactIn") {
        if (_priceAtLimit(rnnnIsZero)) return;
        address actor = _actor(actorSeed);
        rnnnIn = bound(rnnnIn, 1, MAX_SWAP);
        Before memory b = _before(actor);

        _swap(actor, rnnnIsZero, -int256(rnnnIn));

        uint256 received = imd.balanceOf(actor) - b.actorImd;
        uint256 fee = _accountedFee(b);
        // The pool paid out `received + fee`; the fee is 1% of that.
        _recordFee(fee, (received + fee) / 100);
        _checkLeaks(b);
    }

    /// @notice Sell RNNN for an exact IMD output. IMD is the specified currency: fee in `beforeSwap`.
    /// Bounded to half of the IMD the pool can pay so the request always fills.
    function sellExactOut(uint256 actorSeed, uint256 imdOut) external countCall("sellExactOut") {
        if (_priceAtLimit(rnnnIsZero)) return;
        address actor = _actor(actorSeed);
        uint256 reserve = _imdReserveLowerBound();
        // Rounding dust the pool keeps on every swap is a few wei; never mistake it for a reserve.
        if (reserve < 2e6) return;
        imdOut = bound(imdOut, 1, _min(MAX_SWAP, reserve / 2));
        Before memory b = _before(actor);

        _swap(actor, rnnnIsZero, int256(imdOut));

        uint256 received = imd.balanceOf(actor) - b.actorImd;
        uint256 fee = _accountedFee(b);
        if (received != imdOut) ghost_partialSpecifiedFills++;
        _recordFee(fee, imdOut / 100);
        _checkLeaks(b);
    }

    // ---------------------------------------------------------------------------------------------
    // Liquidity, donations, claims, redemption
    // ---------------------------------------------------------------------------------------------

    /// @notice Adds full-range liquidity. Bounded well above the fees a position can have accrued
    /// (the test router asserts an add never nets tokens out), and skipped when the price sits at
    /// an extreme, where a full-range position would need more of one token than exists.
    function addLiquidity(uint256 liquidity) external countCall("addLiquidity") {
        if (_priceAtLimit(true) || _priceAtLimit(false)) return;
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        if (tick > MAX_ADD_TICK || tick < -MAX_ADD_TICK) return;
        liquidity = bound(liquidity, uint256(MIN_FULL_RANGE), 1e24);
        _modifyLiquidity(TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), int256(liquidity));
        fullRangeLiquidity += int256(liquidity);
    }

    /// @notice Removes full-range liquidity but never below the floor the pool started with (a
    /// pool seeded RNNN-only has no floor on the full-range position).
    function removeLiquidity(uint256 liquidity) external countCall("removeLiquidity") {
        int256 floor = seededFullRange ? LIQUIDITY_FLOOR : int256(0);
        if (fullRangeLiquidity <= floor) return;
        uint256 available = uint256(fullRangeLiquidity - floor);
        // At least 1e18 of liquidity, so the withdrawal is not rounded to zero tokens on both sides
        // (the test router asserts a removal returns something).
        liquidity = bound(liquidity, _min(1e18, available), available);
        // Never leave a sliver of full-range liquidity behind: a few wei of liquidity let a tiny
        // swap carry the price to an extreme tick. Either enough stays for swaps, or none does.
        if (fullRangeLiquidity - int256(liquidity) < MIN_FULL_RANGE) liquidity = available;
        _modifyLiquidity(TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), -int256(liquidity));
        fullRangeLiquidity -= int256(liquidity);
    }

    /// @notice Donates IMD (and some RNNN) to in-range LPs. Puts IMD into the manager that belongs
    /// to no swap and no claim.
    function donate(uint256 amountImd, uint256 amountRnnn) external countCall("donate") {
        if (IPoolManager(address(manager)).getLiquidity(key.toId()) == 0) return;
        amountImd = bound(amountImd, 0, MAX_DONATION);
        amountRnnn = bound(amountRnnn, 0, MAX_DONATION);
        if (amountImd == 0 && amountRnnn == 0) return;
        (uint256 a0, uint256 a1) = rnnnIsZero ? (amountRnnn, amountImd) : (amountImd, amountRnnn);
        donateRouter.donate(key, a0, a1, "");
        ghost_imdDonated += amountImd;
    }

    /// @notice A third party gifts the hook ERC-6909 IMD claims. The hook must treat them as
    /// pending fees for the recipient and never let them break redemption.
    function giftClaimsToHook(uint256 actorSeed, uint256 amount) external countCall("giftClaimsToHook") {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, MAX_CLAIM_GIFT);
        vm.startPrank(actor);
        claimsRouter.deposit(Currency.wrap(address(imd)), actor, amount);
        manager.transfer(address(hook), Currency.wrap(address(imd)).toId(), amount);
        vm.stopPrank();
        ghost_claimsGifted += amount;
    }

    /// @notice Anyone redeems whatever pending fees the manager's IMD covers.
    function redeem(uint256 actorSeed) external countCall("redeem") {
        uint256 pending = hook.pendingFees();
        uint256 available = imd.balanceOf(address(manager));
        if (pending == 0 || available == 0) return;
        uint256 expected = pending < available ? pending : available;
        uint256 before = imd.balanceOf(recipient);
        vm.prank(_actor(actorSeed));
        uint256 redeemed = hook.redeemPendingFees();
        if (redeemed != expected || imd.balanceOf(recipient) - before != expected) ghost_redeemMismatches++;
        if (hook.pendingFees() != pending - expected) ghost_redeemMismatches++;
    }

    // ---------------------------------------------------------------------------------------------
    // Views for the invariants
    // ---------------------------------------------------------------------------------------------

    /// @notice IMD held by every account the handler moves IMD through, excluding the manager and
    /// the recipient.
    function imdHeldByParticipants() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += imd.balanceOf(actors[i]);
        }
        total += imd.balanceOf(address(this));
    }

    function rnnnHeldByParticipants() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += rnnn.balanceOf(actors[i]);
        }
        total += rnnn.balanceOf(address(this));
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _actor(uint256 actorSeed) internal view returns (address) {
        return actors[actorSeed % actors.length];
    }

    function _approveAll(address who) internal {
        vm.startPrank(who);
        imd.approve(address(swapRouter), type(uint256).max);
        imd.approve(address(lpRouter), type(uint256).max);
        imd.approve(address(donateRouter), type(uint256).max);
        imd.approve(address(claimsRouter), type(uint256).max);
        rnnn.approve(address(swapRouter), type(uint256).max);
        rnnn.approve(address(lpRouter), type(uint256).max);
        rnnn.approve(address(donateRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _before(address actor) internal view returns (Before memory b) {
        b.recipientImd = imd.balanceOf(recipient);
        b.recipientRnnn = rnnn.balanceOf(recipient);
        b.pending = hook.pendingFees();
        b.actorImd = imd.balanceOf(actor);
        b.actorRnnn = rnnn.balanceOf(actor);
        b.hookImd = imd.balanceOf(address(hook));
        b.hookRnnn = rnnn.balanceOf(address(hook));
        b.hookRnnnClaims = manager.balanceOf(address(hook), Currency.wrap(address(rnnn)).toId());
    }

    /// @dev The fee this swap accounted: what the recipient gained plus what became pending. A
    /// flush of older claims moves value from pending to the recipient and cancels out.
    function _accountedFee(Before memory b) internal returns (uint256 fee) {
        uint256 pendingNow = hook.pendingFees();
        uint256 recipientGain = imd.balanceOf(recipient) - b.recipientImd;
        fee = recipientGain + pendingNow - b.pending;
        if (pendingNow < b.pending) {
            ghost_flushed += b.pending - pendingNow;
            ghost_paidNow += fee;
        } else if (pendingNow > b.pending) {
            ghost_deferred += pendingNow - b.pending;
            ghost_paidNow += recipientGain;
        } else {
            ghost_paidNow += fee;
        }
    }

    function _recordFee(uint256 accounted, uint256 expected) internal {
        ghost_feesAccounted += accounted;
        ghost_feesExpected += expected;
        if (accounted != expected) ghost_feeMismatches++;
    }

    function _checkLeaks(Before memory b) internal {
        if (rnnn.balanceOf(recipient) != b.recipientRnnn) ghost_leaks++;
        if (imd.balanceOf(address(hook)) != b.hookImd || rnnn.balanceOf(address(hook)) != b.hookRnnn) ghost_leaks++;
        if (manager.balanceOf(address(hook), Currency.wrap(address(rnnn)).toId()) != b.hookRnnnClaims) ghost_leaks++;
    }

    /// @dev A lower bound on the IMD an exact-output sell can draw from the pool: the manager's IMD
    /// less pending claims, donations and an over-estimate of accrued LP fees.
    function _imdReserveLowerBound() internal view returns (uint256) {
        uint256 held = imd.balanceOf(address(manager));
        uint256 notReserve = hook.pendingFees() + ghost_imdDonated + ghost_imdLpFeeBound;
        return held > notReserve ? held - notReserve : 0;
    }

    /// @dev True when the pool's price already sits at the extreme limit in `zeroForOne`'s
    /// direction, where the PoolManager refuses any further swap that way. Only a pool with no
    /// liquidity on that side can get there (an earlier sell into an RNNN-only pool).
    function _priceAtLimit(bool zeroForOne) internal view returns (bool) {
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        return zeroForOne ? price <= TickMath.MIN_SQRT_PRICE + 1 : price >= TickMath.MAX_SQRT_PRICE - 1;
    }

    function _swap(address actor, bool zeroForOne, int256 amountSpecified) internal {
        vm.prank(actor);
        swapRouter.swap(
            key,
            SwapParams(
                zeroForOne, amountSpecified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _modifyLiquidity(int24 lower, int24 upper, int256 liquidityDelta) internal {
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, liquidityDelta, bytes32(0)), "");
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
