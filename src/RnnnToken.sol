// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title RnnnToken
/// @notice The rnnn.bid community token (symbol RNNN): a fixed-supply, plain ERC-20.
/// @dev One billion tokens at 18 decimals are minted once, to the deployer, in the constructor.
/// There is no owner, no mint, no burn, no pause, no blocklist, no transfer fee and no upgrade path.
/// The 1% swap fee the project asked for lives in `RnnnFeeHook`, not here.
contract RnnnToken {
    string public constant name = "rnnn.bid";
    string public constant symbol = "RNNN";
    uint8 public constant decimals = 18;

    /// @notice Whole supply, minted once: 1,000,000,000 tokens at 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    uint256 public immutable totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance();
    error InsufficientAllowance();
    error TransferToZeroAddress();

    constructor() {
        totalSupply = TOTAL_SUPPLY;
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert TransferToZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance();
        balanceOf[from] = fromBalance - amount;
        // Cannot overflow: the sum of all balances is the fixed total supply.
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
