// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RnnnToken} from "../src/RnnnToken.sol";

contract RnnnTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

    RnnnToken token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new RnnnToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "rnnn.bid");
        assertEq(token.symbol(), "RNNN");
        assertEq(token.decimals(), 18);
    }

    function test_mintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferMovesExactAmount() public {
        uint256 amount = 1_234 ether;
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(RnnnToken.InsufficientBalance.selector);
        token.transfer(bob, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.expectRevert(RnnnToken.TransferToZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 60 ether);
        assertEq(token.allowance(alice, bob), 60 ether);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 40 ether));
        assertEq(token.balanceOf(bob), 40 ether);
        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.allowance(alice, bob), 20 ether);

        vm.prank(bob);
        vm.expectRevert(RnnnToken.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 21 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(address(this), alice, 1 ether);
        assertEq(token.allowance(address(this), bob), type(uint256).max);
    }

    /// @dev No mint, owner, pause or upgrade entry point exists: every such call must fail and leave
    /// the supply untouched, from a stranger and from the deployer alike.
    function test_noAdminFunctionChangesSupply() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(address,uint256)",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "setFee(uint256)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
            vm.prank(alice);
            (bool okStranger,) = address(token).call(data);
            assertFalse(okStranger, signatures[i]);
            (bool okDeployer,) = address(token).call(data);
            assertFalse(okDeployer, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(alice), 0, signatures[i]);
        }
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4, "DELEGATECALL");
            assertTrue(op != 0xf2, "CALLCODE");
            assertTrue(op != 0xff, "SELFDESTRUCT");
        }
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, SUPPLY);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(address(this)), SUPPLY);
    }
}
