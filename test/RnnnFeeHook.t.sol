// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {RnnnFeeHook} from "../src/RnnnFeeHook.sol";
import {RnnnToken} from "../src/RnnnToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookDeployer} from "./utils/HookDeployer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract RnnnFeeHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant POOL_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    /// @dev The fee recipient the brief fixes.
    address constant RECIPIENT = 0x45C89d0CF0B8a05218506236FcfcB18DA1D3ebE4;
    uint256 constant IMD_SUPPLY = 1e30;

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
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

        imd = new MockERC20("IMD", "IMD", IMD_SUPPLY);
        rnnn = new RnnnToken();

        hook = _deployHook(address(manager), address(imd), RECIPIENT);

        rnnnIsZero = address(rnnn) < address(imd);
        key = _keyFor(Currency.wrap(address(rnnn)), Currency.wrap(address(imd)), POOL_FEE, TICK_SPACING);
        manager.initialize(key, SQRT_PRICE_1_1);

        imd.approve(address(swapRouter), type(uint256).max);
        imd.approve(address(lpRouter), type(uint256).max);
        rnnn.approve(address(swapRouter), type(uint256).max);
        rnnn.approve(address(lpRouter), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment, permissions, access control
    // ---------------------------------------------------------------------------------------------

    function test_permissionsMatchTheAddressFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
        assertEq(FLAGS, 0x20CC);
    }

    function test_immutablesAreSetByTheConstructor() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(Currency.unwrap(hook.imd()), address(imd));
        assertEq(hook.feeRecipient(), RECIPIENT);
        assertEq(hook.FEE_BPS(), 100);
        assertEq(hook.feeFor(100 ether), 1 ether);
        assertEq(hook.pendingFees(), 0);
    }

    function test_constructorRejectsZeroAddresses() public {
        assertEq(_tryDeployHook(address(manager), address(imd), address(0)), address(0), "zero recipient");
        assertEq(_tryDeployHook(address(manager), address(0), RECIPIENT), address(0), "zero imd");
        assertEq(_tryDeployHook(address(0), address(imd), RECIPIENT), address(0), "zero manager");
    }

    function test_constructorRejectsAnAddressWithoutTheRightFlags() public {
        bytes memory code = _creationCode(address(manager), address(imd), RECIPIENT);
        assertEq(HookDeployer.tryDeployAtFlags(code, FLAGS ^ HookFlags.AFTER_SWAP), address(0), "missing flag");
        assertEq(HookDeployer.tryDeployAtFlags(code, FLAGS | HookFlags.BEFORE_DONATE), address(0), "extra flag");
    }

    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2);
        BalanceDelta zero = BalanceDelta.wrap(0);
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));

        vm.expectRevert(RnnnFeeHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(RnnnFeeHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(RnnnFeeHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, zero, "");
        vm.expectRevert(RnnnFeeHook.NotPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(RnnnFeeHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(RnnnFeeHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(RnnnFeeHook.NotPoolManager.selector);
        hook.afterAddLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(RnnnFeeHook.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(RnnnFeeHook.NotPoolManager.selector);
        hook.afterRemoveLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(RnnnFeeHook.NotPoolManager.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(RnnnFeeHook.NotPoolManager.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
    }

    /// @dev Even the PoolManager cannot drive the hook's accounting through a direct callback: a
    /// fake `afterSwap` from the manager's address outside a swap finds the manager locked.
    function test_afterSwapOutsideAnUnlockReverts() public {
        _addFullRangeLiquidity(1e24);
        SwapParams memory params = SwapParams(!rnnnIsZero, -100 ether, _limit(!rnnnIsZero));
        vm.prank(address(manager));
        vm.expectRevert();
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
    }

    function test_unusedCallbacksRevertEvenFromTheManager() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        BalanceDelta zero = BalanceDelta.wrap(0);
        vm.startPrank(address(manager));
        vm.expectRevert(RnnnFeeHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(RnnnFeeHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(RnnnFeeHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(RnnnFeeHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(RnnnFeeHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(RnnnFeeHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(RnnnFeeHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    /// @dev The hook has no owner and no setter. Every common administrative selector must fail,
    /// from a stranger and from the deployer, and leave the recipient and fee untouched.
    function test_noPrivilegedFunctions() public {
        string[16] memory signatures = [
            "setFeeRecipient(address)",
            "setRecipient(address)",
            "setFee(uint256)",
            "setFeeBps(uint256)",
            "transferOwnership(address)",
            "setOwner(address)",
            "renounceOwnership()",
            "owner()",
            "pause()",
            "unpause()",
            "mint(address,uint256)",
            "withdraw(address,uint256)",
            "rescue(address,uint256)",
            "sweep(address)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], stranger, uint256(1));
            vm.prank(stranger);
            (bool okStranger,) = address(hook).call(data);
            assertFalse(okStranger, signatures[i]);
            (bool okDeployer,) = address(hook).call(data);
            assertFalse(okDeployer, signatures[i]);
        }
        assertEq(hook.feeRecipient(), RECIPIENT);
        assertEq(hook.FEE_BPS(), 100);
        // No fallback or receive either: ETH and unknown calls are refused.
        (bool okEth,) = address(hook).call{value: 1 wei}("");
        assertFalse(okEth);
    }

    function test_runtimeCodeHasNoEscapeHatch() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff, "SELFDESTRUCT");
            assertTrue(op != 0xf4, "DELEGATECALL");
            assertTrue(op != 0xf2, "CALLCODE");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Pool initialization
    // ---------------------------------------------------------------------------------------------

    function test_initializeAcceptsTheLaunchPool() public view {
        (uint160 price,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, SQRT_PRICE_1_1);
        assertEq(lpFee, POOL_FEE);
    }

    function test_initializeAcceptsImdOnEitherSideAndAnyListedFee() public {
        // A token that sorts on the other side of IMD than RNNN does.
        MockERC20 other = _tokenOnSide(!rnnnIsZero);
        PoolKey memory otherKey = _keyFor(Currency.wrap(address(other)), Currency.wrap(address(imd)), 3_000, 60);
        manager.initialize(otherKey, SQRT_PRICE_1_1);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(otherKey.toId());
        assertEq(price, SQRT_PRICE_1_1);
    }

    function test_initializeAcceptsAnyCallerSuchAsTheLaunchFactory() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 1e24);
        PoolKey memory otherKey = _keyFor(Currency.wrap(address(other)), Currency.wrap(address(imd)), POOL_FEE, 60);
        address factory = makeAddr("factory");
        vm.prank(factory);
        manager.initialize(otherKey, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesAPoolWithoutImd() public {
        MockERC20 a = new MockERC20("A", "A", 1e24);
        MockERC20 b = new MockERC20("B", "B", 1e24);
        PoolKey memory badKey = _keyFor(Currency.wrap(address(a)), Currency.wrap(address(b)), POOL_FEE, 60);
        vm.expectRevert();
        manager.initialize(badKey, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesANativeEthPoolWithoutImd() public {
        PoolKey memory badKey = _keyFor(Currency.wrap(address(0)), Currency.wrap(address(rnnn)), POOL_FEE, 60);
        vm.expectRevert();
        manager.initialize(badKey, SQRT_PRICE_1_1);
    }

    // ---------------------------------------------------------------------------------------------
    // Fee on a funded pool (both sides seeded): paid to the recipient inside the swap
    // ---------------------------------------------------------------------------------------------

    function test_buyExactInput_sendsExactlyOnePercentOfImdToRecipient() public {
        _addFullRangeLiquidity(1e24);
        uint256 amountIn = 100 ether;
        Snapshot memory s = _snapshot();

        vm.expectEmit(true, false, false, true, address(hook));
        emit RnnnFeeHook.FeeTaken(key.toId(), amountIn / 100, true);
        BalanceDelta delta = _buyExactIn(amountIn);

        uint256 fee = imd.balanceOf(RECIPIENT) - s.recipientImd;
        assertEq(fee, 1 ether, "recipient did not get 1%");
        assertEq(fee, amountIn / 100);
        assertEq(s.swapperImd - imd.balanceOf(address(this)), amountIn, "swapper paid other than amountIn");
        assertEq(imd.balanceOf(address(manager)) - s.managerImd, amountIn - fee, "pool got other than 99%");
        assertEq(uint256(uint128(-_imdDelta(delta))), amountIn);
        assertGt(rnnn.balanceOf(address(this)), s.swapperRnnn, "swapper got no RNNN");
        assertEq(rnnn.balanceOf(RECIPIENT), 0, "fee must not be in RNNN");
        assertEq(hook.pendingFees(), 0);
        _assertHookHoldsNothing();
        _assertImdConserved();
    }

    function test_sellExactInput_sendsExactlyOnePercentOfImdToRecipient() public {
        _addFullRangeLiquidity(1e24);
        uint256 rnnnIn = 1_000 ether;
        Snapshot memory s = _snapshot();

        BalanceDelta delta = _sellExactIn(rnnnIn);

        uint256 fee = imd.balanceOf(RECIPIENT) - s.recipientImd;
        uint256 received = imd.balanceOf(address(this)) - s.swapperImd;
        assertGt(fee, 0);
        assertEq(received, uint256(uint128(_imdDelta(delta))));
        // The pool paid out `received + fee`; the recipient got exactly 1% of it.
        assertEq(fee, (received + fee) / 100, "recipient did not get 1% of the IMD side");
        assertEq(s.managerImd - imd.balanceOf(address(manager)), received + fee);
        assertEq(s.swapperRnnn - rnnn.balanceOf(address(this)), rnnnIn);
        assertEq(rnnn.balanceOf(RECIPIENT), 0, "fee must not be in RNNN");
        assertEq(hook.pendingFees(), 0);
        _assertHookHoldsNothing();
        _assertImdConserved();
    }

    function test_buyExactOutput_sendsExactlyOnePercentOfImdToRecipient() public {
        _addFullRangeLiquidity(1e24);
        uint256 rnnnOut = 50 ether;
        Snapshot memory s = _snapshot();

        BalanceDelta delta = _buyExactOut(rnnnOut);

        uint256 fee = imd.balanceOf(RECIPIENT) - s.recipientImd;
        uint256 paid = s.swapperImd - imd.balanceOf(address(this));
        assertGt(fee, 0);
        assertEq(rnnn.balanceOf(address(this)) - s.swapperRnnn, rnnnOut, "exact output not honoured");
        assertEq(paid, uint256(uint128(-_imdDelta(delta))));
        // The pool charged `paid - fee`; the recipient got exactly 1% of it on top.
        assertEq(fee, (paid - fee) / 100, "recipient did not get 1% of the IMD side");
        assertEq(imd.balanceOf(address(manager)) - s.managerImd, paid - fee);
        assertEq(hook.pendingFees(), 0);
        _assertHookHoldsNothing();
        _assertImdConserved();
    }

    function test_sellExactOutput_sendsExactlyOnePercentOfImdToRecipient() public {
        _addFullRangeLiquidity(1e24);
        uint256 imdOut = 100 ether;
        Snapshot memory s = _snapshot();

        BalanceDelta delta = _sellExactOut(imdOut);

        uint256 fee = imd.balanceOf(RECIPIENT) - s.recipientImd;
        assertEq(fee, 1 ether, "recipient did not get 1%");
        assertEq(fee, imdOut / 100);
        assertEq(imd.balanceOf(address(this)) - s.swapperImd, imdOut, "exact output not honoured");
        assertEq(uint256(uint128(_imdDelta(delta))), imdOut);
        assertEq(s.managerImd - imd.balanceOf(address(manager)), imdOut + fee);
        assertLt(rnnn.balanceOf(address(this)), s.swapperRnnn);
        assertEq(hook.pendingFees(), 0);
        _assertHookHoldsNothing();
        _assertImdConserved();
    }

    function test_feeIsNeverTakenInRnnnAndLpFeeIsUntouched() public {
        _addFullRangeLiquidity(1e24);
        _buyExactIn(10 ether);
        _sellExactIn(10 ether);
        _buyExactOut(10 ether);
        _sellExactOut(10 ether);
        assertEq(rnnn.balanceOf(RECIPIENT), 0);
        assertEq(rnnn.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(rnnn)).toId()), 0);
        assertGt(imd.balanceOf(RECIPIENT), 0);
        (,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(lpFee, POOL_FEE);
        _assertHookHoldsNothing();
        _assertImdConserved();
    }

    function test_tinySwapWithZeroFeeStillSucceeds() public {
        _addFullRangeLiquidity(1e24);
        uint256 before = imd.balanceOf(RECIPIENT);
        _buyExactIn(99);
        assertEq(imd.balanceOf(RECIPIENT), before);
        assertEq(hook.pendingFees(), 0);
    }

    function test_secondImdPoolWithTheHookIsChargedTheSameWay() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 1e27);
        other.approve(address(lpRouter), type(uint256).max);
        other.approve(address(swapRouter), type(uint256).max);
        PoolKey memory otherKey = _keyFor(Currency.wrap(address(other)), Currency.wrap(address(imd)), POOL_FEE, 60);
        manager.initialize(otherKey, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(
            otherKey,
            ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 1e24, bytes32(0)
            ),
            ""
        );
        bool imdIsZero = address(imd) < address(other);
        uint256 before = imd.balanceOf(RECIPIENT);
        swapRouter.swap(
            otherKey, SwapParams(imdIsZero, -200 ether, _limit(imdIsZero)), PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(imd.balanceOf(RECIPIENT) - before, 2 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Fee on a fresh pool seeded with RNNN only: deferred as a claim, then paid
    // ---------------------------------------------------------------------------------------------

    function test_firstBuyOnRnnnOnlyPool_defersFeeAsClaimThenAnyoneRedeemsIt() public {
        _addRnnnOnlyLiquidity(1e24);
        assertEq(imd.balanceOf(address(manager)), 0, "manager must start without IMD");
        uint256 amountIn = 100 ether;
        Snapshot memory s = _snapshot();

        vm.expectEmit(true, false, false, true, address(hook));
        emit RnnnFeeHook.FeeTaken(key.toId(), amountIn / 100, false);
        _buyExactIn(amountIn);

        // The swap went through, the trader paid exactly amountIn, and the fee is pending.
        assertEq(imd.balanceOf(RECIPIENT), s.recipientImd, "nothing could be paid yet");
        assertEq(s.swapperImd - imd.balanceOf(address(this)), amountIn);
        assertGt(rnnn.balanceOf(address(this)), s.swapperRnnn);
        assertEq(hook.pendingFees(), 1 ether);
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(imd)).toId()), 1 ether);
        assertEq(imd.balanceOf(address(manager)), amountIn, "manager now holds the whole input");

        // Anyone redeems the claim; the recipient receives exactly the fee, as IMD.
        vm.expectEmit(true, false, false, true, address(hook));
        emit RnnnFeeHook.PendingFeesRedeemed(stranger, 1 ether);
        vm.prank(stranger);
        uint256 redeemed = hook.redeemPendingFees();
        assertEq(redeemed, 1 ether);
        assertEq(imd.balanceOf(RECIPIENT) - s.recipientImd, 1 ether);
        assertEq(hook.pendingFees(), 0);
        assertEq(imd.balanceOf(address(manager)), amountIn - 1 ether);
        _assertHookHoldsNothing();
        _assertImdConserved();
    }

    function test_firstExactOutputBuyOnRnnnOnlyPool_defersFeeAsClaim() public {
        _addRnnnOnlyLiquidity(1e24);
        uint256 rnnnOut = 50 ether;
        Snapshot memory s = _snapshot();

        _buyExactOut(rnnnOut);

        uint256 paid = s.swapperImd - imd.balanceOf(address(this));
        uint256 pending = hook.pendingFees();
        assertGt(pending, 0);
        assertEq(imd.balanceOf(RECIPIENT), s.recipientImd);
        assertEq(rnnn.balanceOf(address(this)) - s.swapperRnnn, rnnnOut);
        assertEq(pending, (paid - pending) / 100, "pending fee is not 1% of the IMD side");

        hook.redeemPendingFees();
        assertEq(imd.balanceOf(RECIPIENT) - s.recipientImd, pending);
        assertEq(hook.pendingFees(), 0);
        _assertImdConserved();
    }

    function test_pendingFeesAreFlushedByTheNextSwapThatFindsImd() public {
        _addRnnnOnlyLiquidity(1e24);
        uint256 recipientBefore = imd.balanceOf(RECIPIENT);

        _buyExactIn(100 ether);
        assertEq(hook.pendingFees(), 1 ether);
        assertEq(imd.balanceOf(RECIPIENT), recipientBefore);

        // The manager now holds 99 IMD, enough for this swap's fee and the pending one.
        vm.expectEmit(true, false, false, true, address(hook));
        emit RnnnFeeHook.PendingFeesRedeemed(address(hook), 1 ether);
        _buyExactIn(100 ether);
        assertEq(hook.pendingFees(), 0);
        assertEq(imd.balanceOf(RECIPIENT) - recipientBefore, 2 ether);
        _assertHookHoldsNothing();
        _assertImdConserved();
    }

    function test_sellAfterTheFirstBuyPaysDirectly() public {
        _addRnnnOnlyLiquidity(1e24);
        _buyExactIn(100 ether);
        hook.redeemPendingFees();
        uint256 recipientBefore = imd.balanceOf(RECIPIENT);
        uint256 swapperBefore = imd.balanceOf(address(this));

        _sellExactIn(10 ether);

        uint256 fee = imd.balanceOf(RECIPIENT) - recipientBefore;
        uint256 received = imd.balanceOf(address(this)) - swapperBefore;
        assertGt(fee, 0);
        assertEq(fee, (received + fee) / 100);
        assertEq(hook.pendingFees(), 0);
    }

    function test_redeemPendingFeesRevertsWhenNothingIsPending() public {
        vm.expectRevert(RnnnFeeHook.NothingToRedeem.selector);
        hook.redeemPendingFees();
        _addFullRangeLiquidity(1e24);
        _buyExactIn(10 ether);
        vm.expectRevert(RnnnFeeHook.NothingToRedeem.selector);
        hook.redeemPendingFees();
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: the fee is exactly 1% whatever the size
    // ---------------------------------------------------------------------------------------------

    function testFuzz_buyExactInput_feeIsExactlyOnePercent(uint256 amountIn) public {
        _addFullRangeLiquidity(1e26);
        amountIn = bound(amountIn, 100, 1e24);
        Snapshot memory s = _snapshot();
        _buyExactIn(amountIn);
        assertEq(imd.balanceOf(RECIPIENT) - s.recipientImd, amountIn / 100);
        assertEq(s.swapperImd - imd.balanceOf(address(this)), amountIn);
        assertEq(hook.pendingFees(), 0);
        _assertImdConserved();
    }

    function testFuzz_sellExactInput_feeIsExactlyOnePercent(uint256 rnnnIn) public {
        _addFullRangeLiquidity(1e26);
        rnnnIn = bound(rnnnIn, 100, 1e24);
        Snapshot memory s = _snapshot();
        _sellExactIn(rnnnIn);
        uint256 fee = imd.balanceOf(RECIPIENT) - s.recipientImd;
        uint256 received = imd.balanceOf(address(this)) - s.swapperImd;
        assertEq(fee, (received + fee) / 100);
        assertEq(s.managerImd - imd.balanceOf(address(manager)), received + fee);
        assertEq(hook.pendingFees(), 0);
        _assertImdConserved();
    }

    function testFuzz_sellExactOutput_feeIsExactlyOnePercent(uint256 imdOut) public {
        _addFullRangeLiquidity(1e26);
        imdOut = bound(imdOut, 100, 1e24);
        Snapshot memory s = _snapshot();
        _sellExactOut(imdOut);
        assertEq(imd.balanceOf(RECIPIENT) - s.recipientImd, imdOut / 100);
        assertEq(imd.balanceOf(address(this)) - s.swapperImd, imdOut);
        _assertImdConserved();
    }

    function testFuzz_buyExactOutput_feeIsExactlyOnePercent(uint256 rnnnOut) public {
        _addFullRangeLiquidity(1e26);
        rnnnOut = bound(rnnnOut, 100, 1e24);
        Snapshot memory s = _snapshot();
        _buyExactOut(rnnnOut);
        uint256 fee = imd.balanceOf(RECIPIENT) - s.recipientImd;
        uint256 paid = s.swapperImd - imd.balanceOf(address(this));
        assertEq(fee, (paid - fee) / 100);
        assertEq(rnnn.balanceOf(address(this)) - s.swapperRnnn, rnnnOut);
        _assertImdConserved();
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    struct Snapshot {
        uint256 recipientImd;
        uint256 swapperImd;
        uint256 swapperRnnn;
        uint256 managerImd;
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.recipientImd = imd.balanceOf(RECIPIENT);
        s.swapperImd = imd.balanceOf(address(this));
        s.swapperRnnn = rnnn.balanceOf(address(this));
        s.managerImd = imd.balanceOf(address(manager));
    }

    function _assertHookHoldsNothing() internal view {
        assertEq(imd.balanceOf(address(hook)), 0, "hook holds IMD");
        assertEq(rnnn.balanceOf(address(hook)), 0, "hook holds RNNN");
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(rnnn)).toId()), 0, "hook holds RNNN claims");
    }

    /// @dev Every IMD unit is with the swapper, the pool, or the recipient (or pending as a claim,
    /// in which case it still sits in the manager).
    function _assertImdConserved() internal view {
        assertEq(
            imd.balanceOf(address(this)) + imd.balanceOf(address(manager)) + imd.balanceOf(RECIPIENT),
            IMD_SUPPLY,
            "IMD leaked"
        );
    }

    function _creationCode(address manager_, address imd_, address recipient) internal pure returns (bytes memory) {
        return abi.encodePacked(type(RnnnFeeHook).creationCode, abi.encode(manager_, imd_, recipient));
    }

    function _deployHook(address manager_, address imd_, address recipient) internal returns (RnnnFeeHook) {
        return RnnnFeeHook(HookDeployer.deployAtFlags(_creationCode(manager_, imd_, recipient), FLAGS));
    }

    function _tryDeployHook(address manager_, address imd_, address recipient) internal returns (address) {
        return HookDeployer.tryDeployAtFlags(_creationCode(manager_, imd_, recipient), FLAGS);
    }

    function _keyFor(Currency a, Currency b, uint24 fee, int24 spacing) internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: spacing, hooks: IHooks(address(hook))});
    }

    /// @dev A mock token whose address sorts below IMD when `below` is true, above otherwise.
    function _tokenOnSide(bool below) internal returns (MockERC20 token) {
        for (uint256 i = 0; i < 64; i++) {
            token = new MockERC20("Side", "SIDE", 1e24);
            if ((address(token) < address(imd)) == below) return token;
        }
        revert("no token on the wanted side");
    }

    function _addFullRangeLiquidity(int256 liquidity) internal {
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), liquidity, bytes32(0)
            ),
            ""
        );
    }

    /// @dev Liquidity entirely on the RNNN side of the current price, the shape the launch seeds.
    function _addRnnnOnlyLiquidity(int256 liquidity) internal {
        (int24 lower, int24 upper) = rnnnIsZero
            ? (TICK_SPACING, TickMath.maxUsableTick(TICK_SPACING))
            : (TickMath.minUsableTick(TICK_SPACING), -TICK_SPACING);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, liquidity, bytes32(0)), "");
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams(zeroForOne, amountSpecified, _limit(zeroForOne)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    /// @dev IMD in, RNNN out.
    function _buyExactIn(uint256 imdIn) internal returns (BalanceDelta) {
        return _swap(!rnnnIsZero, -int256(imdIn));
    }

    function _buyExactOut(uint256 rnnnOut) internal returns (BalanceDelta) {
        return _swap(!rnnnIsZero, int256(rnnnOut));
    }

    /// @dev RNNN in, IMD out.
    function _sellExactIn(uint256 rnnnIn) internal returns (BalanceDelta) {
        return _swap(rnnnIsZero, -int256(rnnnIn));
    }

    function _sellExactOut(uint256 imdOut) internal returns (BalanceDelta) {
        return _swap(rnnnIsZero, int256(imdOut));
    }

    function _imdDelta(BalanceDelta delta) internal view returns (int128) {
        return rnnnIsZero ? delta.amount1() : delta.amount0();
    }
}
