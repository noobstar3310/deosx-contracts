// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Test USDT for the Sepolia rehearsal
/// @notice Behaves like mainnet USDT where the vault and the app meet it: 6 decimals, `transfer`, `transferFrom` and
/// `approve` return nothing, `approve` reverts when changing one non-zero allowance to another, and a short balance or
/// allowance reverts. Anyone can mint up to `MAX_MINT` per call. The cap keeps the supply far from the uint256 limit
/// for any realistic number of calls, so no one can make minting overflow for everybody. Never deploy on mainnet.
contract TestTether {
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant name = "DEOS-X Test Tether USD";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant symbol = "USDT";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    uint8 public constant decimals = 6;
    /// @notice The whole fund (2M + 3M + 15M) in one call.
    uint256 public constant MAX_MINT = 20_000_000e6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ZeroAmount();
    error AboveMaxMint(uint256 amount, uint256 max);
    error ApproveFromNonZero();
    error InsufficientBalance();
    error InsufficientAllowance();

    function mint(address to, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (amount > MAX_MINT) revert AboveMaxMint(amount, MAX_MINT);
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 value) external {
        _move(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < value) revert InsufficientAllowance();
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _move(from, to, value);
    }

    function approve(address spender, uint256 value) external {
        if (value != 0 && allowance[msg.sender][spender] != 0) revert ApproveFromNonZero();
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
    }

    function _move(address from, address to, uint256 value) private {
        uint256 balance = balanceOf[from];
        if (balance < value) revert InsufficientBalance();
        balanceOf[from] = balance - value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}
