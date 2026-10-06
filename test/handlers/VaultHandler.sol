// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {DeosxVault} from "../../src/DeosxVault.sol";
import {MockTether} from "../mocks/MockTether.sol";

/// @notice Drives the vault through random sequences of investor, operator and Safe actions, and keeps ghost totals of
/// every USDT that went in and out (in all and per tranche's pot), so the invariant suite can check the books against
/// them. It also records each request's split and introducer as made, so the suite can check neither changes.
/// Beyond the money flows it toggles the whitelist, changes introducers, changes the minimums, pauses, hands the vault
/// to another Safe, and sends USDT to the vault by plain transfer. Every action skips what the vault would refuse, so
/// the run stays at zero reverts (`fail_on_revert`).
contract VaultHandler is Test {
    DeosxVault internal vault;
    MockTether internal usdt;
    /// @notice The vault's current owner; `handOver` swaps it between two Safes.
    address public safe;
    address[2] internal safes;
    address internal operator = makeAddr("handler-operator");
    address internal otc = makeAddr("handler-otc");

    address[] public investors;
    address[2] public introducers;

    uint256 public ghostDeposited;
    uint256 public ghostCapitalPaid;
    uint256 public ghostInterestFunded;
    uint256 public ghostInterestPaid;
    uint256 public ghostFeesPaid;
    uint256 public ghostInterestWithdrawn;
    uint256 public ghostOut;
    uint256 public ghostReturned;
    /// @notice USDT sent to the vault by plain transfer, outside its functions (KNOWN_ISSUES §1).
    uint256 public ghostDonated;

    /// @notice Per tranche: interest funded into its pot, paid from it as interest, paid from it as fees, and taken
    /// back to the Safe.
    uint256[3] public ghostFundedIn;
    uint256[3] public ghostInterestPaidIn;
    uint256[3] public ghostFeesPaidIn;
    uint256[3] public ghostWithdrawnIn;

    /// @notice A request's `heldUnderHalf`, `heldHalf` and `heldFull` as it was made.
    mapping(uint256 requestId => uint256[3]) internal _ghostSplit;
    /// @notice The wallet's introducer when the request was made.
    mapping(uint256 requestId => address) internal _ghostIntroducer;

    constructor(DeosxVault vault_, MockTether usdt_, address safe_) {
        vault = vault_;
        usdt = usdt_;
        safe = safe_;
        safes = [safe_, makeAddr("handler-safe-2")];
        introducers[0] = makeAddr("handler-introducer-0");
        introducers[1] = makeAddr("handler-introducer-1");
        vm.prank(safe);
        vault.setOperator(operator, true);
        for (uint256 i; i < 4; ++i) {
            address who = makeAddr(string.concat("handler-investor-", vm.toString(i)));
            investors.push(who);
            vm.startPrank(operator);
            vault.setWhitelisted(who, true);
            // Investors 0 and 1 have different introducers, 2 has the same as 0, 3 has none.
            if (i < 3) vault.setIntroducer(who, introducers[i % 2]);
            vm.stopPrank();
            vm.prank(who);
            usdt.approve(address(vault), type(uint256).max);
        }
        for (uint256 i; i < 2; ++i) {
            vm.prank(safes[i]);
            usdt.approve(address(vault), type(uint256).max);
        }
    }

    function investorCount() external view returns (uint256) {
        return investors.length;
    }

    function ghostSplit(uint256 requestId) external view returns (uint256[3] memory) {
        return _ghostSplit[requestId];
    }

    function deposit(uint256 who, uint256 amount) external {
        address investor = investors[who % investors.length];
        if (vault.paused() || !vault.isWhitelisted(investor)) return;
        uint256 minimum = vault.capitalOf(investor) == 0 ? vault.openingMinimum() : vault.topUpMinimum();
        uint256 room = vault.trancheInfo(0).room + vault.trancheInfo(1).room + vault.trancheInfo(2).room;
        if (room == 0) return;
        if (room < minimum) {
            // Exactly all the room left is exempt from the minimum.
            amount = room;
        } else {
            // Up to 1M a time, so the fund fills over many deposits and wallets build up positions of different ages.
            amount = bound(amount, minimum, room < 1_000_000e6 ? room : 1_000_000e6);
        }
        usdt.mint(investor, amount);
        vm.prank(investor);
        vault.deposit(amount, [uint256(0), 0, 0]);
        ghostDeposited += amount;
    }

    function request(uint256 who, uint256 tranche, uint256 amount) external {
        address investor = investors[who % investors.length];
        tranche = tranche % 3;
        // One open request per wallet: a second one would revert. No whitelist check: a removed wallet can leave.
        if (vault.paused() || vault.openRequestOf(investor) != 0) return;
        uint256 free = vault.available(investor, tranche);
        if (free == 0) return;
        amount = bound(amount, 1, free);
        address introducer = vault.introducerOf(investor);
        vm.prank(investor);
        uint256 id = vault.requestWithdraw(tranche, amount);
        DeosxVault.Request memory r = vault.getRequest(id);
        _ghostSplit[id] = [r.heldUnderHalf, r.heldHalf, r.heldFull];
        _ghostIntroducer[id] = introducer;
    }

    function cancel(uint256 pick) external {
        uint256[] memory ids = vault.pendingRequests();
        if (ids.length == 0) return;
        uint256 id = ids[pick % ids.length];
        vm.prank(vault.getRequest(id).owner);
        vault.cancelWithdraw(id);
    }

    function fulfill(uint256 pick, uint256 interest) external {
        uint256[] memory ids = vault.pendingRequests();
        if (ids.length == 0) return;
        uint256 id = ids[pick % ids.length];
        DeosxVault.Request memory r = vault.getRequest(id);
        (,,, uint256 cash,) = vault.vaultState();
        if (cash < r.amount) _returnAll();
        interest = bound(interest, 0, vault.trancheInfo(r.tranche).interestPot);
        uint256 before = usdt.balanceOf(r.owner);
        vm.prank(safe);
        vault.fulfillWithdraw(id, interest);
        assertEq(usdt.balanceOf(r.owner) - before, r.amount + interest, "investor paid capital plus interest");
        ghostCapitalPaid += r.amount;
        ghostInterestPaid += interest;
        ghostInterestPaidIn[r.tranche] += interest;
    }

    function payFee(uint256 pick, uint256 amount) external {
        uint256[] memory ids = vault.feesDue();
        if (ids.length == 0) return;
        uint256 id = ids[pick % ids.length];
        DeosxVault.Request memory r = vault.getRequest(id);
        // The fee goes to the introducer recorded at the request, whatever the wallet's introducer is now.
        assertEq(r.introducer, _ghostIntroducer[id], "fee goes to the introducer recorded at the request");
        amount = bound(amount, 0, vault.trancheInfo(r.tranche).interestPot);
        uint256 before = usdt.balanceOf(r.introducer);
        vm.prank(safe);
        vault.payIntroducerFee(id, amount);
        assertEq(usdt.balanceOf(r.introducer) - before, amount, "introducer paid the amount");
        ghostFeesPaid += amount;
        ghostFeesPaidIn[r.tranche] += amount;
    }

    function fundInterest(uint256 tranche, uint256 amount) external {
        tranche = tranche % 3;
        amount = bound(amount, 1, 1_000_000e6);
        usdt.mint(safe, amount);
        vm.prank(safe);
        vault.fundInterest(tranche, amount);
        ghostInterestFunded += amount;
        ghostFundedIn[tranche] += amount;
    }

    function withdrawInterest(uint256 tranche, uint256 amount) external {
        tranche = tranche % 3;
        uint256 pot = vault.trancheInfo(tranche).interestPot;
        if (pot == 0) return;
        amount = bound(amount, 1, pot);
        vm.prank(safe);
        vault.withdrawInterest(tranche, amount);
        ghostInterestWithdrawn += amount;
        ghostWithdrawnIn[tranche] += amount;
    }

    function transferOut(uint256 amount) external {
        (,,, uint256 cash,) = vault.vaultState();
        if (cash == 0) return;
        amount = bound(amount, 1, cash);
        vm.prank(safe);
        vault.transferOut(otc, amount);
        ghostOut += amount;
    }

    function returnCapital(uint256 amount) external {
        uint256 deployed = vault.deployedCapital();
        if (deployed == 0) return;
        _returnCapital(bound(amount, 1, deployed));
    }

    function warp(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 1, 60 days));
    }

    /// @notice The operator takes a wallet off the whitelist or puts it back.
    function setWhitelisted(uint256 who, bool allowed) external {
        vm.prank(operator);
        vault.setWhitelisted(investors[who % investors.length], allowed);
    }

    /// @notice The operator changes a wallet's introducer to one of the two, or to none.
    function setIntroducer(uint256 who, uint256 pick) external {
        pick %= 3;
        vm.prank(operator);
        vault.setIntroducer(investors[who % investors.length], pick < 2 ? introducers[pick] : address(0));
    }

    /// @notice The Safe changes the minimums, keeping the top-up at or above the 5,500 USDT operating rule
    /// (KNOWN_ISSUES §2) and at most the opening minimum.
    function setMinimums(uint256 opening, uint256 topUp) external {
        topUp = bound(topUp, 5_500e6, 50_000e6);
        opening = bound(opening, topUp, 200_000e6);
        vm.prank(safe);
        vault.setMinimums(opening, topUp);
    }

    function togglePause() external {
        bool paused = vault.paused();
        vm.prank(safe);
        if (paused) vault.unpause();
        else vault.pause();
    }

    /// @notice The Safe hands the vault to the other Safe in two steps.
    function handOver() external {
        address next = safe == safes[0] ? safes[1] : safes[0];
        vm.prank(safe);
        vault.transferOwnership(next);
        vm.prank(next);
        vault.acceptOwnership();
        safe = next;
    }

    /// @notice Someone sends USDT to the vault with a plain transfer: it lands on the capital side, untracked.
    function donate(uint256 amount) external {
        amount = bound(amount, 1, 100_000e6);
        usdt.mint(address(vault), amount);
        ghostDonated += amount;
    }

    function _returnAll() private {
        uint256 deployed = vault.deployedCapital();
        if (deployed != 0) _returnCapital(deployed);
    }

    function _returnCapital(uint256 amount) private {
        usdt.mint(safe, amount);
        vm.prank(safe);
        vault.returnCapital(amount);
        ghostReturned += amount;
    }
}
