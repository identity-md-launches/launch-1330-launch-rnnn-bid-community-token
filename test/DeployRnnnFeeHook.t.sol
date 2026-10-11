// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {DeployRnnnFeeHook} from "../script/DeployRnnnFeeHook.s.sol";
import {RnnnFeeHook} from "../src/RnnnFeeHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeployRnnnFeeHookTest is Test {
    address constant RECIPIENT = 0x45C89d0CF0B8a05218506236FcfcB18DA1D3ebE4;

    function test_deployLandsOnAnAddressWithTheDeclaredFlags() public {
        PoolManager manager = new PoolManager(address(this));
        MockERC20 imd = new MockERC20("IMD", "IMD", 0);
        DeployRnnnFeeHook deployer = new DeployRnnnFeeHook();
        DeployRnnnFeeHook.Config memory config = DeployRnnnFeeHook.Config({
            poolManager: IPoolManager(address(manager)), imd: address(imd), feeRecipient: RECIPIENT
        });

        (bytes32 salt, address predicted) = deployer.mineSalt(address(deployer), config);
        RnnnFeeHook hook = deployer.deploy(config, salt);

        assertEq(address(hook), predicted);
        assertEq(HookFlags.flagsOf(address(hook)), deployer.FLAGS());
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(Currency.unwrap(hook.imd()), address(imd));
        assertEq(hook.feeRecipient(), RECIPIENT);
    }

    function test_deployWithAnUnminedSaltReverts() public {
        PoolManager manager = new PoolManager(address(this));
        MockERC20 imd = new MockERC20("IMD", "IMD", 0);
        DeployRnnnFeeHook deployer = new DeployRnnnFeeHook();
        DeployRnnnFeeHook.Config memory config = DeployRnnnFeeHook.Config({
            poolManager: IPoolManager(address(manager)), imd: address(imd), feeRecipient: RECIPIENT
        });
        (bytes32 salt,) = deployer.mineSalt(address(deployer), config);
        bytes32 wrongSalt = bytes32(uint256(salt) + 1);
        vm.expectRevert();
        deployer.deploy(config, wrongSalt);
    }
}
