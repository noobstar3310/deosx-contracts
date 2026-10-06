// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title DEOS-X tranche LP token
/// @notice One per tranche, created by the vault. Minted 1:1 against the USDT capital placed in the tranche and
/// burned when that capital is paid out. Only the vault can mint or burn, and it can never be transferred: each
/// slice's lock belongs to the depositor.
contract TrancheToken is ERC20 {
    address public immutable vault;
    uint8 private immutable _decimals;

    error NotVault();
    error SharesNonTransferable();

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        vault = msg.sender;
        _decimals = decimals_;
    }

    modifier onlyVault() {
        _checkVault();
        _;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }

    function _checkVault() private view {
        if (msg.sender != vault) revert NotVault();
    }

    /// @notice Always reverts: the token can never be transferred, so an approval could never be used.
    function approve(address, uint256) public pure override returns (bool) {
        revert SharesNonTransferable();
    }

    /// @dev LP only moves by mint (deposit) or burn (payout).
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) revert SharesNonTransferable();
        super._update(from, to, value);
    }
}
