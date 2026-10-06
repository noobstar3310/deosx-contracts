// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Behaves like mainnet USDT (TetherToken) where it matters to the vault: `transfer`, `transferFrom` and
/// `approve` return nothing; `approve` reverts when changing one non-zero allowance to another; an owner-set fee
/// is taken from every transfer; blacklisted senders can't move tokens. Plus an open `mint` for tests.
contract MockTether {
    // Constants, not storage, so the code can be etched at a fixed address and still report 6 decimals.
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant name = "Mock Tether USD";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant symbol = "USDT";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    uint256 public basisPointsRate;
    uint256 public maximumFee;
    address public constant FEE_COLLECTOR = address(0xFEE);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public isBlackListed;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFee(uint256 bps, uint256 maxFee) external {
        basisPointsRate = bps;
        maximumFee = maxFee;
    }

    function setBlackListed(address who, bool listed) external {
        isBlackListed[who] = listed;
    }

    function transfer(address to, uint256 value) external {
        require(!isBlackListed[msg.sender], "blacklisted");
        _move(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external {
        require(!isBlackListed[from], "blacklisted");
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _move(from, to, value);
    }

    function approve(address spender, uint256 value) external {
        require(!(value != 0 && allowance[msg.sender][spender] != 0), "approve from non-zero");
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
    }

    function _mint(address to, uint256 amount) private {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function _move(address from, address to, uint256 value) private {
        uint256 fee = value * basisPointsRate / 10_000;
        if (fee > maximumFee) fee = maximumFee;
        require(balanceOf[from] >= value, "balance");
        balanceOf[from] -= value;
        balanceOf[to] += value - fee;
        emit Transfer(from, to, value - fee);
        if (fee > 0) {
            balanceOf[FEE_COLLECTOR] += fee;
            emit Transfer(from, FEE_COLLECTOR, fee);
        }
    }
}
