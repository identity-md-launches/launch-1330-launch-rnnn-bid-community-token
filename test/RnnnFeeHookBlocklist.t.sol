// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {RnnnFeeHook} from "../src/RnnnFeeHook.sol";
import {RnnnToken} from "../src/RnnnToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookDeployer} from "./utils/HookDeployer.sol";
import {BlocklistERC20} from "./mocks/BlocklistERC20.sol";

/// @notice The live IMD token is owner-controlled and can block addresses. If its admin ever blocks
/// the fee recipient, the hook must defer the fee as a claim rather than halt trading.
contract RnnnFeeHookBlocklistTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant POOL_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;
    address constant RECIPIENT = 0x45C89d0CF0B8a05218506236FcfcB18DA1D3ebE4;

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    BlocklistERC20 imd;
    RnnnToken rnnn;
    RnnnFeeHook hook;
    PoolKey key;
    bool rnnnIsZero;

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        imd = new BlocklistERC20("IMD", "IMD", 1e30);
        rnnn = new RnnnToken();

        bytes memory code =
            abi.encodePacked(type(RnnnFeeHook).creationCode, abi.encode(address(manager), address(imd), RECIPIENT));
        hook = RnnnFeeHook(HookDeployer.deployAtFlags(code, FLAGS));

        rnnnIsZero = address(rnnn) < address(imd);
        (Currency c0, Currency c1) = rnnnIsZero
            ? (Currency.wrap(address(rnnn)), Currency.wrap(address(imd)))
            : (Currency.wrap(address(imd)), Currency.wrap(address(rnnn)));
        key = PoolKey(c0, c1, POOL_FEE, TICK_SPACING, IHooks(address(hook)));
        manager.initialize(key, SQRT_PRICE_1_1);

        imd.approve(address(swapRouter), type(uint256).max);
        imd.approve(address(lpRouter), type(uint256).max);
        rnnn.approve(address(swapRouter), type(uint256).max);
        rnnn.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 1e24, bytes32(0)
            ),
            ""
        );
    }

    function test_blockedRecipient_swapsStillExecuteAndFeesAreDeferredUntilUnblocked() public {
        imd.setBlocked(RECIPIENT, true);
        uint256 swapperImd = imd.balanceOf(address(this));
        uint256 swapperRnnn = rnnn.balanceOf(address(this));

        // A buy: the trade goes through, the fee is a claim.
        _swap(!rnnnIsZero, -100 ether);
        assertEq(swapperImd - imd.balanceOf(address(this)), 100 ether);
        assertGt(rnnn.balanceOf(address(this)), swapperRnnn);
        assertEq(hook.pendingFees(), 1 ether);
        assertEq(imd.balanceOf(RECIPIENT), 0);

        // A sell: the manager holds IMD, the transfer is refused, the fee is a claim.
        swapperImd = imd.balanceOf(address(this));
        _swap(rnnnIsZero, -100 ether);
        uint256 received = imd.balanceOf(address(this)) - swapperImd;
        uint256 sellFee = hook.pendingFees() - 1 ether;
        assertGt(received, 0);
        assertEq(sellFee, (received + sellFee) / 100, "sell fee is not 1% of the IMD side");
        assertEq(imd.balanceOf(RECIPIENT), 0);

        // While blocked, redemption fails with the token's own error and nothing moves.
        uint256 pending = hook.pendingFees();
        vm.expectRevert();
        hook.redeemPendingFees();
        assertEq(hook.pendingFees(), pending);

        // Unblocked: anyone redeems, and the recipient receives every deferred fee as IMD.
        imd.setBlocked(RECIPIENT, false);
        hook.redeemPendingFees();
        assertEq(imd.balanceOf(RECIPIENT), pending);
        assertEq(hook.pendingFees(), 0);
    }

    function test_blockedRecipient_laterSwapsDoNotFlushPendingClaims() public {
        _swap(!rnnnIsZero, -100 ether);
        assertEq(imd.balanceOf(RECIPIENT), 1 ether, "unblocked: paid in the swap");
        imd.setBlocked(RECIPIENT, true);
        _swap(!rnnnIsZero, -100 ether);
        assertEq(hook.pendingFees(), 1 ether);
        _swap(!rnnnIsZero, -100 ether);
        assertEq(hook.pendingFees(), 2 ether, "pending claims stay pending while blocked");
        assertEq(imd.balanceOf(RECIPIENT), 1 ether);
        imd.setBlocked(RECIPIENT, false);
        _swap(!rnnnIsZero, -100 ether);
        assertEq(hook.pendingFees(), 0, "the next swap after unblocking flushes them");
        assertEq(imd.balanceOf(RECIPIENT), 4 ether);
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        swapRouter.swap(
            key, SwapParams(zeroForOne, amountSpecified, limit), PoolSwapTest.TestSettings(false, false), ""
        );
    }
}
