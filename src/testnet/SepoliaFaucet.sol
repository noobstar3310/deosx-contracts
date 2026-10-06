// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Sepolia ETH faucet for the portals
/// @notice Holds Sepolia ETH and drips `dripAmount` to a wallet at most once every `cooldown`. Only the relayer (the
/// portals' server key) can drip, so a wallet with no ETH at all can be served: the relayer pays the gas, the ETH comes
/// from this contract. The cooldown is kept here, per wallet, so no server or database can be talked out of it. A
/// leaked relayer key can drain the faucet one wallet per cooldown and nothing else; the owner swaps it with
/// `setRelayer`. Never deploy on mainnet.
contract SepoliaFaucet is Ownable {
    uint256 public immutable dripAmount;
    uint256 public immutable cooldown;

    address public relayer;
    /// @notice When each wallet was last dripped; 0 if never.
    mapping(address wallet => uint256) public lastDripAt;

    event Dripped(address indexed wallet, uint256 amount);
    event RelayerSet(address indexed relayer);
    event Withdrawn(address indexed to, uint256 amount);

    error NotRelayer();
    error ZeroAddress();
    error CoolingDown(uint256 availableAt);
    error FaucetEmpty(uint256 balance, uint256 needed);
    error TransferFailed();

    constructor(address owner_, address relayer_, uint256 dripAmount_, uint256 cooldown_) Ownable(owner_) {
        if (relayer_ == address(0)) revert ZeroAddress();
        relayer = relayer_;
        dripAmount = dripAmount_;
        cooldown = cooldown_;
        emit RelayerSet(relayer_);
    }

    receive() external payable {}

    /// @notice Send `dripAmount` to `wallet`, if its cooldown has run out.
    function drip(address payable wallet) external {
        if (msg.sender != relayer) revert NotRelayer();
        if (wallet == address(0)) revert ZeroAddress();
        uint256 at = nextDripAt(wallet);
        if (block.timestamp < at) revert CoolingDown(at);
        if (address(this).balance < dripAmount) revert FaucetEmpty(address(this).balance, dripAmount);
        lastDripAt[wallet] = block.timestamp;
        emit Dripped(wallet, dripAmount);
        (bool ok,) = wallet.call{value: dripAmount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice The earliest time `wallet` can be dripped again; 0 if it never was.
    function nextDripAt(address wallet) public view returns (uint256) {
        uint256 last = lastDripAt[wallet];
        return last == 0 ? 0 : last + cooldown;
    }

    function setRelayer(address relayer_) external onlyOwner {
        if (relayer_ == address(0)) revert ZeroAddress();
        relayer = relayer_;
        emit RelayerSet(relayer_);
    }

    /// @notice Take ETH back out, for example to move it to a new faucet.
    function withdraw(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        emit Withdrawn(to, amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
