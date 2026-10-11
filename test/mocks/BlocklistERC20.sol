// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

/// @notice An ERC-20 with an address blocklist, standing in for the live IMD token on Robinhood
/// Chain, which exposes `blocked(address)` and refuses transfers that touch a blocked address.
contract BlocklistERC20 is MockERC20 {
    mapping(address => bool) public blocked;

    constructor(string memory name_, string memory symbol_, uint256 supply) MockERC20(name_, symbol_, supply) {}

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(!blocked[from] && !blocked[to], "BlocklistERC20: blocked");
        super._transfer(from, to, amount);
    }
}
