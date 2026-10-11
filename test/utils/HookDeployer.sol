// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "../../src/HookFlags.sol";

/// @notice Mines a CREATE2 salt so a hook lands on an address carrying `flags`, then deploys it.
/// The deployer is the calling contract itself, the same way the protected floor suite does it.
library HookDeployer {
    uint256 internal constant MAX_ITERATIONS = 200_000;

    error NoSaltFound();
    error DeploymentReverted();

    function mineSalt(address deployer, bytes memory creationCode, uint160 flags)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < MAX_ITERATIONS; i++) {
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initCodeHash))))
            );
            if (HookFlags.matches(predicted, flags)) return (bytes32(i), predicted);
        }
        revert NoSaltFound();
    }

    /// @dev Deploys `creationCode` with CREATE2 from the caller at a mined address.
    function deployAtFlags(bytes memory creationCode, uint160 flags) internal returns (address at) {
        (bytes32 salt,) = mineSalt(address(this), creationCode, flags);
        assembly ("memory-safe") {
            at := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        if (at == address(0)) revert DeploymentReverted();
    }

    /// @dev Like `deployAtFlags` but reports a reverted constructor instead of reverting itself.
    function tryDeployAtFlags(bytes memory creationCode, uint160 flags) internal returns (address at) {
        (bytes32 salt,) = mineSalt(address(this), creationCode, flags);
        assembly ("memory-safe") {
            at := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
    }
}
