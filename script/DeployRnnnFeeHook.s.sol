// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {RnnnFeeHook} from "../src/RnnnFeeHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @title DeployRnnnFeeHook
/// @notice Manual deployment path for the hook, for a rehearsal or a deployment outside the IMD
/// launch factory. The IMD launch itself deploys the hook from its bytecode and this script is not
/// part of it.
/// @dev `run()` reads its configuration from the environment; `deploy()` takes it as arguments so
/// tests can call it without touching the environment.
contract DeployRnnnFeeHook is Script {
    /// @notice The permission bits the hook address must carry.
    uint160 public constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    /// @notice The CREATE2 deployer forge broadcasts `new{salt: ...}` through.
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 internal constant MAX_ITERATIONS = 500_000;

    error NoSaltFound();

    struct Config {
        IPoolManager poolManager;
        address imd;
        address feeRecipient;
    }

    /// @dev Reads POOL_MANAGER, IMD and FEE_RECIPIENT and deploys through the CREATE2 deployer.
    function run() external returns (RnnnFeeHook hook) {
        Config memory config = Config({
            poolManager: IPoolManager(vm.envAddress("POOL_MANAGER")),
            imd: vm.envAddress("IMD"),
            feeRecipient: vm.envAddress("FEE_RECIPIENT")
        });
        (bytes32 salt,) = mineSalt(CREATE2_DEPLOYER, config);
        vm.startBroadcast();
        hook = deploy(config, salt);
        vm.stopBroadcast();
    }

    /// @notice Deploys the hook with CREATE2 at `salt`. The resulting address must carry `FLAGS`,
    /// or the constructor reverts.
    function deploy(Config memory config, bytes32 salt) public returns (RnnnFeeHook hook) {
        hook = new RnnnFeeHook{salt: salt}(config.poolManager, config.imd, config.feeRecipient);
    }

    /// @notice Finds a salt for which `deployer` deploys the hook at an address carrying `FLAGS`.
    function mineSalt(address deployer, Config memory config) public pure returns (bytes32 salt, address predicted) {
        bytes32 initCodeHash = keccak256(creationCode(config));
        for (uint256 i = 0; i < MAX_ITERATIONS; i++) {
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initCodeHash))))
            );
            if (HookFlags.matches(predicted, FLAGS)) return (bytes32(i), predicted);
        }
        revert NoSaltFound();
    }

    /// @notice The hook's creation code with its constructor arguments appended.
    function creationCode(Config memory config) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(RnnnFeeHook).creationCode, abi.encode(config.poolManager, config.imd, config.feeRecipient)
        );
    }
}
