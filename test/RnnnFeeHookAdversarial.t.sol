// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolClaimsTest} from "v4-core/src/test/PoolClaimsTest.sol";

import {RnnnFeeHook} from "../src/RnnnFeeHook.sol";
import {RnnnToken} from "../src/RnnnToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookDeployer} from "./utils/HookDeployer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Adversarial and edge-case tests for `RnnnFeeHook`, beyond the happy path in
/// `RnnnFeeHook.t.sol`: the pool with IMD on the other side, hook data, donations, claim gifts,
/// callbacks driven at the wrong time, the branch where a flush cannot be afforded, and the limits
/// of the fee arithmetic.
contract RnnnFeeHookAdversarialTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant POOL_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;
    address constant RECIPIENT = 0x45C89d0CF0B8a05218506236FcfcB18DA1D3ebE4;
    uint256 constant IMD_SUPPLY = 1e30;

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    PoolDonateTest donateRouter;
    PoolClaimsTest claimsRouter;
    MockERC20 imd;
    RnnnToken rnnn;
    RnnnFeeHook hook;
    PoolKey key;
    bool rnnnIsZero;

    address stranger = makeAddr("stranger");

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        donateRouter = new PoolDonateTest(manager);
        claimsRouter = new PoolClaimsTest(manager);

        imd = new MockERC20("IMD", "IMD", IMD_SUPPLY);
        rnnn = new RnnnToken();

        bytes memory code =
            abi.encodePacked(type(RnnnFeeHook).creationCode, abi.encode(address(manager), address(imd), RECIPIENT));
        hook = RnnnFeeHook(HookDeployer.deployAtFlags(code, FLAGS));

        rnnnIsZero = address(rnnn) < address(imd);
        key = _keyFor(address(rnnn), POOL_FEE, TICK_SPACING);
        manager.initialize(key, SQRT_PRICE_1_1);

        imd.approve(address(swapRouter), type(uint256).max);
        imd.approve(address(lpRouter), type(uint256).max);
        imd.approve(address(donateRouter), type(uint256).max);
        imd.approve(address(claimsRouter), type(uint256).max);
        rnnn.approve(address(swapRouter), type(uint256).max);
        rnnn.approve(address(lpRouter), type(uint256).max);
        rnnn.approve(address(donateRouter), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------
    // IMD on the other side of the key
    // ---------------------------------------------------------------------------------------------

    /// @dev The RNNN/IMD ordering in `setUp` is whatever the deployment addresses give. A token on
    /// the other side of IMD exercises the opposite branch of every `currency0 == imd` test in the
    /// hook, for all four swap shapes.
    function test_feeIsOnePercentWhenImdIsOnTheOtherSideOfTheKey() public {
        MockERC20 other = _tokenOnSide(!rnnnIsZero);
        other.approve(address(lpRouter), type(uint256).max);
        other.approve(address(swapRouter), type(uint256).max);
        PoolKey memory otherKey = _keyFor(address(other), POOL_FEE, TICK_SPACING);
        manager.initialize(otherKey, SQRT_PRICE_1_1);
        _addFullRange(otherKey, 1e24);
        bool imdIsZero = address(imd) < address(other);
        // `other` sorts on the opposite side of IMD from RNNN, so IMD's slot in the key flips.
        assertEq(imdIsZero, rnnnIsZero, "the other token must sit where RNNN does not");

        // Exact-input buy: 1% of the IMD paid.
        uint256 recipientBefore = imd.balanceOf(RECIPIENT);
        _swapOn(otherKey, imdIsZero, -int256(100 ether));
        assertEq(imd.balanceOf(RECIPIENT) - recipientBefore, 1 ether, "exact-input buy");

        // Exact-output sell: 1% of the IMD received.
        recipientBefore = imd.balanceOf(RECIPIENT);
        _swapOn(otherKey, !imdIsZero, int256(100 ether));
        assertEq(imd.balanceOf(RECIPIENT) - recipientBefore, 1 ether, "exact-output sell");

        // Exact-output buy: 1% of what the pool charged, on top.
        recipientBefore = imd.balanceOf(RECIPIENT);
        uint256 imdBefore = imd.balanceOf(address(this));
        _swapOn(otherKey, imdIsZero, int256(50 ether));
        uint256 fee = imd.balanceOf(RECIPIENT) - recipientBefore;
        uint256 paid = imdBefore - imd.balanceOf(address(this));
        assertGt(fee, 0);
        assertEq(fee, (paid - fee) / 100, "exact-output buy");

        // Exact-input sell: 1% of what the pool paid out.
        recipientBefore = imd.balanceOf(RECIPIENT);
        imdBefore = imd.balanceOf(address(this));
        _swapOn(otherKey, !imdIsZero, -int256(50 ether));
        fee = imd.balanceOf(RECIPIENT) - recipientBefore;
        uint256 received = imd.balanceOf(address(this)) - imdBefore;
        assertGt(fee, 0);
        assertEq(fee, (received + fee) / 100, "exact-input sell");

        assertEq(other.balanceOf(RECIPIENT), 0, "fee must not be in the launch token");
        assertEq(hook.pendingFees(), 0);
    }

    /// @dev The hook's rate does not depend on the pool's LP fee or tick spacing.
    function test_feeIsOnePercentWhateverTheLpFeeAndTickSpacing() public {
        PoolKey memory cheapKey = _keyFor(address(rnnn), 500, 10);
        manager.initialize(cheapKey, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(
            cheapKey,
            ModifyLiquidityParams(TickMath.minUsableTick(10), TickMath.maxUsableTick(10), 1e24, bytes32(0)),
            ""
        );
        uint256 recipientBefore = imd.balanceOf(RECIPIENT);
        _swapOn(cheapKey, !rnnnIsZero, -int256(1_000 ether));
        assertEq(imd.balanceOf(RECIPIENT) - recipientBefore, 10 ether);
        (,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(cheapKey.toId());
        assertEq(lpFee, 500, "the hook changed the LP fee");
    }

    // ---------------------------------------------------------------------------------------------
    // Inputs the hook must ignore
    // ---------------------------------------------------------------------------------------------

    function test_hookDataIsIgnored() public {
        _addFullRange(key, 1e24);
        uint256 recipientBefore = imd.balanceOf(RECIPIENT);
        bytes memory junk = abi.encode(stranger, uint256(0), type(uint256).max, "setFeeRecipient(address)");
        swapRouter.swap(
            key,
            SwapParams(!rnnnIsZero, -int256(100 ether), _limit(!rnnnIsZero)),
            PoolSwapTest.TestSettings(false, false),
            junk
        );
        assertEq(imd.balanceOf(RECIPIENT) - recipientBefore, 1 ether);
        assertEq(hook.feeRecipient(), RECIPIENT);
    }

    function test_swapperTakingClaimsInsteadOfTokensStillPaysTheFee() public {
        _addFullRange(key, 1e24);
        uint256 recipientBefore = imd.balanceOf(RECIPIENT);
        // Sell RNNN and keep the IMD output as an ERC-6909 claim.
        swapRouter.swap(
            key,
            SwapParams(rnnnIsZero, int256(100 ether), _limit(rnnnIsZero)),
            PoolSwapTest.TestSettings(true, false),
            ""
        );
        assertEq(imd.balanceOf(RECIPIENT) - recipientBefore, 1 ether, "fee must still be paid as IMD");
        assertEq(manager.balanceOf(address(this), Currency.wrap(address(imd)).toId()), 100 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Things that put IMD into the manager without a swap must not pay the recipient
    // ---------------------------------------------------------------------------------------------

    function test_donationsAndLiquidityChangesPayNoFee() public {
        _addFullRange(key, 1e24);
        uint256 recipientBefore = imd.balanceOf(RECIPIENT);
        (uint256 a0, uint256 a1) = rnnnIsZero ? (uint256(0), uint256(1_000 ether)) : (uint256(1_000 ether), uint256(0));
        donateRouter.donate(key, a0, a1, "");
        _addFullRange(key, 1e22);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), -1e22, bytes32(0)
            ),
            ""
        );
        assertEq(imd.balanceOf(RECIPIENT), recipientBefore);
        assertEq(hook.pendingFees(), 0);
    }

    /// @dev Anyone can hand the hook ERC-6909 IMD claims. They become pending fees for the recipient
    /// and nothing else; they cannot be pulled back and they do not break the next swap.
    function test_claimsGiftedToTheHookGoToTheRecipientAndNowhereElse() public {
        _addFullRange(key, 1e24);
        claimsRouter.deposit(Currency.wrap(address(imd)), address(this), 5 ether);
        manager.transfer(address(hook), Currency.wrap(address(imd)).toId(), 5 ether);
        assertEq(hook.pendingFees(), 5 ether);

        // The gifter cannot get them back: the hook has no transfer, approve or withdraw path.
        (bool ok,) = address(hook)
            .call(
                abi.encodeWithSignature(
                    "transfer(address,uint256,uint256)", address(this), Currency.wrap(address(imd)).toId(), 5 ether
                )
            );
        assertFalse(ok);
        vm.expectRevert();
        manager.transferFrom(address(hook), address(this), Currency.wrap(address(imd)).toId(), 5 ether);

        // The next swap flushes them to the recipient together with its own fee.
        uint256 recipientBefore = imd.balanceOf(RECIPIENT);
        _swapOn(key, !rnnnIsZero, -int256(100 ether));
        assertEq(imd.balanceOf(RECIPIENT) - recipientBefore, 6 ether);
        assertEq(hook.pendingFees(), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // The flush branch that cannot be afforded
    // ---------------------------------------------------------------------------------------------

    /// @dev A pending claim is flushed only when the manager's IMD covers both this swap's fee and
    /// the claim. Here the manager holds just the IMD backing the claim: the fee is paid, the claim
    /// stays pending, and it is still fully backed afterwards.
    function test_flushIsSkippedWhenTheManagerCannotCoverBothFeeAndPending() public {
        _addRnnnOnlyLiquidity(1e24);
        _swapOn(key, !rnnnIsZero, -int256(100 ether));
        assertEq(hook.pendingFees(), 1 ether);

        // The LP pulls everything out: the manager is left with the 1 IMD backing the claim plus the
        // LP's accrued fee, which the LP takes too.
        (int24 lower, int24 upper) = _rnnnOnlyRange();
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, -1e24, bytes32(0)), "");
        uint256 managerImd = imd.balanceOf(address(manager));
        assertGe(managerImd, 1 ether);
        assertLt(managerImd, 2 ether, "setup: manager must not be able to afford fee + pending");

        // New liquidity, RNNN-only again (strictly beyond the price the first buy moved to, so it
        // deposits no IMD), and another 100 IMD buy: fee 1 IMD, pending 1 IMD.
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        (int24 lower2, int24 upper2) = rnnnIsZero
            ? ((tick / TICK_SPACING + 2) * TICK_SPACING, TickMath.maxUsableTick(TICK_SPACING))
            : (TickMath.minUsableTick(TICK_SPACING), (tick / TICK_SPACING - 2) * TICK_SPACING);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower2, upper2, 1e24, bytes32(0)), "");
        assertEq(imd.balanceOf(address(manager)), managerImd, "setup: the new position must deposit no IMD");
        uint256 recipientBefore = imd.balanceOf(RECIPIENT);
        vm.expectEmit(true, false, false, true, address(hook));
        emit RnnnFeeHook.FeeTaken(key.toId(), 1 ether, true);
        _swapOn(key, !rnnnIsZero, -int256(100 ether));

        assertEq(imd.balanceOf(RECIPIENT) - recipientBefore, 1 ether, "this swap's fee was paid");
        assertEq(hook.pendingFees(), 1 ether, "the old claim is still pending");
        assertGe(imd.balanceOf(address(manager)), hook.pendingFees(), "the claim is still backed");

        // And it is redeemable now that the manager holds the new input.
        hook.redeemPendingFees();
        assertEq(hook.pendingFees(), 0);
        assertEq(imd.balanceOf(RECIPIENT) - recipientBefore, 2 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Callbacks driven at the wrong time
    // ---------------------------------------------------------------------------------------------

    /// @dev Even the manager's own address cannot drive `unlockCallback` into paying while the
    /// manager is locked or while nothing is pending.
    function test_unlockCallbackFromTheManagerOutsideRedeemCannotPay() public {
        vm.prank(address(manager));
        vm.expectRevert(RnnnFeeHook.NothingToRedeem.selector);
        hook.unlockCallback(abi.encode(stranger));

        _addRnnnOnlyLiquidity(1e24);
        _swapOn(key, !rnnnIsZero, -int256(100 ether));
        assertEq(hook.pendingFees(), 1 ether);
        vm.prank(address(manager));
        vm.expectRevert(IPoolManager.ManagerLocked.selector);
        hook.unlockCallback(abi.encode(stranger));
        assertEq(hook.pendingFees(), 1 ether);
    }

    /// @dev A stranger who unlocks the manager gets the callback on their own address, never on the
    /// hook; the hook's claims cannot be moved that way.
    function test_strangerUnlockDoesNotReachTheHook() public {
        _addRnnnOnlyLiquidity(1e24);
        _swapOn(key, !rnnnIsZero, -int256(100 ether));
        StrangerUnlocker unlocker = new StrangerUnlocker(manager, hook);
        vm.expectRevert();
        unlocker.tryToBurnHookClaims(Currency.wrap(address(imd)).toId(), 1 ether);
        assertEq(hook.pendingFees(), 1 ether);
    }

    /// @dev `beforeSwap` is a view: the manager calling it directly can read a delta but moves no
    /// value, and a fake call cannot mint claims.
    function test_beforeSwapFromTheManagerMovesNothing() public {
        SwapParams memory params = SwapParams(!rnnnIsZero, -int256(100 ether), _limit(!rnnnIsZero));
        vm.prank(address(manager));
        (bytes4 selector,, uint24 lpFeeOverride) = hook.beforeSwap(address(this), key, params, "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(lpFeeOverride, 0, "the hook must never override the LP fee");
        assertEq(hook.pendingFees(), 0);
        assertEq(imd.balanceOf(RECIPIENT), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Fee arithmetic at the edges
    // ---------------------------------------------------------------------------------------------

    function test_feeForRoundsDownAndNeverOverflowsForPoolSizedAmounts() public view {
        assertEq(hook.feeFor(0), 0);
        assertEq(hook.feeFor(99), 0);
        assertEq(hook.feeFor(100), 1);
        assertEq(hook.feeFor(199), 1);
        uint256 int128Max = uint256(uint128(type(int128).max));
        assertEq(hook.feeFor(int128Max), int128Max / 100);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeForIsExactlyOnePercentRoundedDown(uint256 amount) public view {
        amount = bound(amount, 0, type(uint256).max / 100);
        assertEq(hook.feeFor(amount), amount / 100);
        assertLe(hook.feeFor(amount) * 100, amount);
        assertGt(hook.feeFor(amount) * 100 + 100, amount);
    }

    /// @dev Below 100 wei of IMD on the specified side the fee rounds to zero and the swap is a plain
    /// swap: no claim, no transfer, no event from the hook.
    function test_swapsBelowOneHundredWeiOfImdPayNothingOnEveryShape() public {
        _addFullRange(key, 1e24);
        uint256 recipientBefore = imd.balanceOf(RECIPIENT);
        _swapOn(key, !rnnnIsZero, -99); // exact-input buy of 99 wei
        _swapOn(key, rnnnIsZero, 99); // exact-output sell of 99 wei
        _swapOn(key, rnnnIsZero, -50); // exact-input sell of 50 wei RNNN
        _swapOn(key, !rnnnIsZero, 50); // exact-output buy of 50 wei RNNN
        assertEq(imd.balanceOf(RECIPIENT), recipientBefore);
        assertEq(hook.pendingFees(), 0);
    }

    /// @dev `beforeSwap` reverts if the fee cannot be expressed as an int128. The pool could never
    /// settle such a swap either, so nothing is lost, but the revert is the hook's.
    function test_beforeSwapRevertsOnAnAmountWhoseFeeExceedsInt128() public {
        SwapParams memory params =
            SwapParams(!rnnnIsZero, -int256(uint256(uint128(type(int128).max)) * 101), _limit(!rnnnIsZero));
        vm.prank(address(manager));
        vm.expectRevert();
        hook.beforeSwap(address(this), key, params, "");
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _keyFor(address token, uint24 fee, int24 spacing) internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = token < address(imd)
            ? (Currency.wrap(token), Currency.wrap(address(imd)))
            : (Currency.wrap(address(imd)), Currency.wrap(token));
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: spacing, hooks: IHooks(address(hook))});
    }

    function _tokenOnSide(bool below) internal returns (MockERC20 token) {
        for (uint256 i = 0; i < 64; i++) {
            token = new MockERC20("Side", "SIDE", 1e27);
            if ((address(token) < address(imd)) == below) return token;
        }
        revert("no token on the wanted side");
    }

    function _addFullRange(PoolKey memory k, int256 liquidity) internal {
        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams(
                TickMath.minUsableTick(k.tickSpacing), TickMath.maxUsableTick(k.tickSpacing), liquidity, bytes32(0)
            ),
            ""
        );
    }

    function _rnnnOnlyRange() internal view returns (int24 lower, int24 upper) {
        return rnnnIsZero
            ? (TICK_SPACING, TickMath.maxUsableTick(TICK_SPACING))
            : (TickMath.minUsableTick(TICK_SPACING), -TICK_SPACING);
    }

    function _addRnnnOnlyLiquidity(int256 liquidity) internal {
        (int24 lower, int24 upper) = _rnnnOnlyRange();
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, liquidity, bytes32(0)), "");
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _swapOn(PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            k, SwapParams(zeroForOne, amountSpecified, _limit(zeroForOne)), PoolSwapTest.TestSettings(false, false), ""
        );
    }
}

/// @dev Unlocks the manager itself and tries to burn the hook's claims from inside the callback.
contract StrangerUnlocker {
    PoolManager immutable manager;
    RnnnFeeHook immutable hook;

    constructor(PoolManager manager_, RnnnFeeHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function tryToBurnHookClaims(uint256 id, uint256 amount) external {
        manager.unlock(abi.encode(id, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (uint256 id, uint256 amount) = abi.decode(data, (uint256, uint256));
        // Burning from the hook needs the hook's approval, which it never gives.
        manager.burn(address(hook), id, amount);
        return "";
    }
}
