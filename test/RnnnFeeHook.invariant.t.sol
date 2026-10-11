// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {RnnnFeeHook} from "../src/RnnnFeeHook.sol";
import {RnnnToken} from "../src/RnnnToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookDeployer} from "./utils/HookDeployer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {RnnnFeeHookHandler} from "./handlers/RnnnFeeHookHandler.sol";

/// @notice Invariants of the hook under random sequences of swaps (all four shapes), liquidity
/// changes, donations, ERC-6909 claim gifts and fee redemptions by several actors.
///
/// The hook holds value: ERC-6909 claims on IMD inside the PoolManager, owed to the fixed recipient.
/// These invariants say that every fee is exactly 1% of the IMD the pool traded, that what the hook
/// holds plus what the recipient received is exactly what every swap accounted, that claims are
/// always backed by IMD in the manager, that nothing ever reaches the hook or the recipient in RNNN,
/// and that no parameter of the hook or the pool moves.
abstract contract RnnnFeeHookInvariantBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant POOL_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;
    address constant RECIPIENT = 0x45C89d0CF0B8a05218506236FcfcB18DA1D3ebE4;

    /// @dev Enough IMD for every actor to trade and the handler to seed and donate.
    uint256 constant IMD_PER_ACCOUNT = 1e28;

    PoolManager manager;
    MockERC20 imd;
    RnnnToken rnnn;
    RnnnFeeHook hook;
    PoolKey key;
    RnnnFeeHookHandler handler;

    uint256 imdSupply;
    uint256 rnnnSupply;

    function _seedFullRange() internal pure virtual returns (bool);

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        imd = new MockERC20("IMD", "IMD", 0);
        rnnn = new RnnnToken();
        rnnnSupply = rnnn.totalSupply();

        bytes memory code =
            abi.encodePacked(type(RnnnFeeHook).creationCode, abi.encode(address(manager), address(imd), RECIPIENT));
        hook = RnnnFeeHook(HookDeployer.deployAtFlags(code, FLAGS));

        (Currency c0, Currency c1) = address(rnnn) < address(imd)
            ? (Currency.wrap(address(rnnn)), Currency.wrap(address(imd)))
            : (Currency.wrap(address(imd)), Currency.wrap(address(rnnn)));
        key = PoolKey({
            currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        handler = new RnnnFeeHookHandler(manager, imd, rnnn, hook, key, RECIPIENT, _seedFullRange());

        // Fund the handler (the LP) and every actor with both tokens. RNNN is fixed-supply, so it
        // is split from the deployer's balance; IMD is minted.
        uint256 participants = handler.actorCount() + 1;
        uint256 rnnnShare = rnnnSupply / participants;
        imd.mint(address(handler), IMD_PER_ACCOUNT);
        rnnn.transfer(address(handler), rnnnShare);
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            imd.mint(actor, IMD_PER_ACCOUNT);
            rnnn.transfer(actor, rnnnShare);
        }
        // Whatever RNNN rounding left with this contract is handed over so participants hold it all.
        rnnn.transfer(address(handler), rnnn.balanceOf(address(this)));
        imdSupply = imd.totalSupply();

        handler.seed();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.buyExactIn.selector;
        selectors[1] = handler.buyExactOut.selector;
        selectors[2] = handler.sellExactIn.selector;
        selectors[3] = handler.sellExactOut.selector;
        selectors[4] = handler.addLiquidity.selector;
        selectors[5] = handler.removeLiquidity.selector;
        selectors[6] = handler.donate.selector;
        selectors[7] = handler.giftClaimsToHook.selector;
        selectors[8] = handler.redeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ---------------------------------------------------------------------------------------------
    // The one rule: exactly 1% of the IMD side, on every swap
    // ---------------------------------------------------------------------------------------------

    /// @notice Every swap accounted a fee of exactly 1% of the IMD the pool traded, whatever its
    /// shape, and the handler never measured it on a partial fill.
    function invariant_everySwapFeeIsExactlyOnePercentOfTheImdSide() public view {
        assertEq(handler.ghost_partialSpecifiedFills(), 0, "a specified-IMD swap did not fill completely");
        assertEq(handler.ghost_feeMismatches(), 0, "a swap's fee was not 1% of its IMD side");
        assertEq(handler.ghost_feesAccounted(), handler.ghost_feesExpected(), "fee totals diverge");
    }

    // ---------------------------------------------------------------------------------------------
    // Solvency: what the hook holds equals what it owes
    // ---------------------------------------------------------------------------------------------

    /// @notice IMD received by the recipient plus IMD still pending as claims equals every fee ever
    /// accounted plus every claim gifted to the hook. Nothing is lost, duplicated or diverted.
    function invariant_recipientPlusPendingEqualsEverythingOwed() public view {
        assertEq(
            imd.balanceOf(RECIPIENT) + hook.pendingFees(),
            handler.ghost_feesAccounted() + handler.ghost_claimsGifted(),
            "recipient + pending != fees accounted + claims gifted"
        );
    }

    /// @notice The hook's pending claims are always backed by IMD the PoolManager actually holds,
    /// so a redemption can never be short.
    function invariant_pendingClaimsAreBackedByManagerImd() public view {
        assertGe(imd.balanceOf(address(manager)), hook.pendingFees(), "claims exceed the manager's IMD");
    }

    /// @notice Every fee paid inside a swap, every fee deferred and every flush add up.
    function invariant_paidPlusDeferredMinusFlushedIsPending() public view {
        assertEq(
            handler.ghost_paidNow() + handler.ghost_deferred(),
            handler.ghost_feesAccounted(),
            "paid-now + deferred != accounted"
        );
        uint256 redeemedByCalls = imd.balanceOf(RECIPIENT) - handler.ghost_paidNow() - handler.ghost_flushed();
        assertEq(
            handler.ghost_deferred() + handler.ghost_claimsGifted(),
            handler.ghost_flushed() + redeemedByCalls + hook.pendingFees(),
            "deferred + gifted != flushed + redeemed + pending"
        );
    }

    /// @notice `redeemPendingFees` always transfers exactly what it returns and what the manager
    /// covers, and reduces the pending amount by the same.
    function invariant_redeemPaysExactlyWhatItReports() public view {
        assertEq(handler.ghost_redeemMismatches(), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Nothing leaks: not into the hook, not into the recipient as RNNN
    // ---------------------------------------------------------------------------------------------

    /// @notice The hook never holds ERC-20 balances, RNNN claims or ETH; its only asset is IMD claims.
    function invariant_hookHoldsNothingButImdClaims() public view {
        assertEq(imd.balanceOf(address(hook)), 0, "hook holds IMD");
        assertEq(rnnn.balanceOf(address(hook)), 0, "hook holds RNNN");
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(rnnn)).toId()), 0, "hook holds RNNN claims");
        assertEq(address(hook).balance, 0, "hook holds ETH");
        assertEq(handler.ghost_leaks(), 0, "a swap moved RNNN to the recipient or tokens to the hook");
    }

    /// @notice The recipient receives IMD only. Never RNNN.
    function invariant_recipientNeverReceivesRnnn() public view {
        assertEq(rnnn.balanceOf(RECIPIENT), 0);
        assertEq(manager.balanceOf(RECIPIENT, Currency.wrap(address(rnnn)).toId()), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Conservation
    // ---------------------------------------------------------------------------------------------

    /// @notice Every IMD unit is with a participant, the manager or the recipient.
    function invariant_imdIsConserved() public view {
        assertEq(imd.totalSupply(), imdSupply, "IMD supply moved");
        assertEq(
            handler.imdHeldByParticipants() + imd.balanceOf(address(manager)) + imd.balanceOf(RECIPIENT),
            imdSupply,
            "IMD leaked"
        );
    }

    /// @notice RNNN's supply never changes and every unit is with a participant or the pool.
    function invariant_rnnnIsConserved() public view {
        assertEq(rnnn.totalSupply(), rnnnSupply, "RNNN supply moved");
        assertEq(handler.rnnnHeldByParticipants() + rnnn.balanceOf(address(manager)), rnnnSupply, "RNNN leaked");
    }

    // ---------------------------------------------------------------------------------------------
    // Nothing is configurable
    // ---------------------------------------------------------------------------------------------

    /// @notice No sequence of calls changes the recipient, the rate, the token or the manager, nor
    /// the pool's LP fee.
    function invariant_hookAndPoolParametersNeverChange() public view {
        assertEq(hook.feeRecipient(), RECIPIENT);
        assertEq(hook.FEE_BPS(), 100);
        assertEq(Currency.unwrap(hook.imd()), address(imd));
        assertEq(address(hook.poolManager()), address(manager));
        (,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(lpFee, POOL_FEE);
    }
}

/// @notice A pool seeded on both sides, the state after the first trades of the launch.
/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract RnnnFeeHookFundedPoolInvariantTest is RnnnFeeHookInvariantBase {
    function _seedFullRange() internal pure override returns (bool) {
        return true;
    }

    /// @notice The handler's instrumentation is live: on a funded pool every swap shape pays its
    /// fee inside the swap, nothing is deferred, and every action the fuzzer may pick runs.
    function test_handlerExercisesEveryActionOnAFundedPool() public {
        handler.buyExactIn(0, 100 ether);
        handler.buyExactOut(1, 50 ether);
        handler.sellExactIn(2, 1_000 ether);
        handler.sellExactOut(0, 100 ether);
        assertEq(handler.ghost_feeMismatches(), 0);
        assertEq(handler.ghost_partialSpecifiedFills(), 0);
        assertEq(handler.ghost_deferred(), 0, "a funded pool never defers");
        assertEq(handler.ghost_paidNow(), handler.ghost_feesAccounted());
        assertGe(handler.ghost_feesAccounted(), 2 ether + 1 ether, "the two IMD-specified swaps alone pay 2 IMD");
        assertEq(handler.calls("sellExactOut"), 1);

        handler.addLiquidity(5e22);
        handler.removeLiquidity(1e22);
        handler.donate(10 ether, 10 ether);
        handler.giftClaimsToHook(1, 3 ether);
        assertEq(hook.pendingFees(), 3 ether);
        handler.redeem(2);
        assertEq(hook.pendingFees(), 0);
        assertEq(handler.ghost_redeemMismatches(), 0);
        invariant_recipientPlusPendingEqualsEverythingOwed();
        invariant_paidPlusDeferredMinusFlushedIsPending();
        invariant_imdIsConserved();
    }
}

/// @notice A pool seeded with RNNN only, the shape the launch factory creates: the PoolManager holds
/// no IMD until the first buy settles, so the first fees are deferred as claims and flushed later.
/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract RnnnFeeHookFreshPoolInvariantTest is RnnnFeeHookInvariantBase {
    function _seedFullRange() internal pure override returns (bool) {
        return false;
    }

    /// @notice On the launch's seed shape, the pool starts with no IMD at all.
    function test_freshPoolStartsWithoutImd() public view {
        assertEq(imd.balanceOf(address(manager)), 0);
        assertEq(hook.pendingFees(), 0);
    }

    /// @notice The handler's instrumentation sees the deferral path: the first buy defers its fee
    /// as a claim, the next buy flushes it, a sell pays directly, and a redeem call pays the rest.
    function test_handlerExercisesDeferralFlushAndRedeemOnAFreshPool() public {
        handler.buyExactIn(0, 100 ether);
        assertEq(handler.ghost_deferred(), 1 ether, "first fee must be deferred");
        assertEq(hook.pendingFees(), 1 ether);
        assertEq(imd.balanceOf(RECIPIENT), 0);

        handler.buyExactIn(1, 100 ether);
        assertEq(handler.ghost_flushed(), 1 ether, "second buy must flush the first fee");
        assertEq(hook.pendingFees(), 0);
        assertEq(imd.balanceOf(RECIPIENT), 2 ether);

        handler.sellExactIn(2, 10 ether);
        // Paid inside a swap so far: the second buy's own 1 IMD plus the sell's fee.
        assertGt(handler.ghost_paidNow(), 1 ether);
        assertEq(handler.ghost_paidNow() + handler.ghost_deferred(), handler.ghost_feesAccounted());
        handler.sellExactOut(0, 1 ether);
        assertEq(handler.calls("sellExactOut"), 1);

        handler.buyExactOut(1, 5 ether);
        handler.giftClaimsToHook(2, 2 ether);
        handler.redeem(0);
        assertEq(hook.pendingFees(), 0);
        assertEq(handler.ghost_feeMismatches(), 0);
        assertEq(handler.ghost_partialSpecifiedFills(), 0);
        assertEq(handler.ghost_redeemMismatches(), 0);
        invariant_recipientPlusPendingEqualsEverythingOwed();
        invariant_paidPlusDeferredMinusFlushedIsPending();
        invariant_pendingClaimsAreBackedByManagerImd();
    }
}
