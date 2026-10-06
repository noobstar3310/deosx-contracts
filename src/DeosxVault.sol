// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {TrancheToken} from "./TrancheToken.sol";

/// @title DEOS-X tranche vault
/// @notice Investors deposit USDT, placed into three tranches in order, and receive each tranche's LP token 1:1.
/// Every tranche keeps two pots: its capital (equal to its LP supply) and an interest pot the owner (a Safe)
/// pre-funds. Investors ask to withdraw any part of a position, one request at a time per wallet; the Safe pays the
/// capital back 1:1 with an interest amount it decides, from that tranche's interest pot, and later pays the
/// investor's introducer from the same pot.
/// The contract calculates no interest: it records how long each part of a position was held so the Safe can decide.
contract DeosxVault is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    uint256 public constant TRANCHE_COUNT = 3;
    /// @dev T1 and T2 never reopen once filled; T3's room comes back when its capital is paid out.
    uint256 private constant REOPENING_TRANCHE = 2;
    uint16 private constant HALF_TIER_BPS = 5_000;
    uint16 private constant FULL_TIER_BPS = 10_000;

    enum RequestStatus {
        None,
        Pending,
        Cancelled,
        Paid
    }

    enum FeeStatus {
        None,
        Due,
        Paid
    }

    /// @dev `taken` is the room used: in T1 and T2 every unit ever deposited, in T3 the capital still in it.
    struct Tranche {
        uint256 size;
        uint256 taken;
        uint256 capital;
        uint256 interestPot;
    }

    struct Position {
        uint256 amount;
        uint64 depositedAt;
    }

    struct Request {
        address owner;
        uint8 tranche;
        uint64 requestedAt;
        RequestStatus status;
        FeeStatus feeStatus;
        address introducer;
        uint256 amount;
        uint256 heldUnderHalf;
        uint256 heldHalf;
        uint256 heldFull;
        uint256 interest;
        uint256 fee;
    }

    struct PositionView {
        uint256 amount;
        uint64 depositedAt;
        uint64 heldFor;
        uint16 tierBps;
    }

    struct TrancheView {
        uint256 size;
        uint256 taken;
        uint256 room;
        uint256 capital;
        uint256 interestPot;
        address lpToken;
    }

    IERC20 public immutable usdt;
    /// @notice A position held this long is eligible for 50% of its interest.
    uint64 public immutable halfTierAfter;
    /// @notice A position held this long is eligible for 100% of its interest.
    uint64 public immutable fullTierAfter;

    uint256 public openingMinimum;
    uint256 public topUpMinimum;
    uint256 public deployedCapital;
    uint256 public totalInterestPot;

    mapping(address wallet => bool) public isWhitelisted;
    mapping(address wallet => address) public introducerOf;
    mapping(address operator => bool) public isOperator;
    /// @notice Capital a wallet holds across all tranches.
    mapping(address wallet => uint256) public capitalOf;
    /// @notice Capital a wallet's pending request has set aside, per tranche: its amount in its tranche, else 0.
    mapping(address wallet => mapping(uint256 tranche => uint256)) public reserved;
    /// @notice A wallet's pending withdrawal request, across all tranches; 0 if it has none.
    mapping(address wallet => uint256 requestId) public openRequestOf;

    Tranche[TRANCHE_COUNT] private _tranches;
    TrancheToken[TRANCHE_COUNT] private _lp;
    mapping(address wallet => mapping(uint256 tranche => uint256)) private _capitalIn;
    mapping(address wallet => mapping(uint256 tranche => Position[])) private _positions;
    mapping(address wallet => mapping(uint256 tranche => uint256)) private _head;
    uint256 private _requestCount;
    mapping(uint256 requestId => Request) private _requests;
    EnumerableSet.UintSet private _pending;
    EnumerableSet.UintSet private _feesDue;

    event Deposited(address indexed wallet, uint256 amount, uint256[TRANCHE_COUNT] perTranche);
    /// @notice The split is as of the request; it is the one the request is paid on.
    event WithdrawRequested(
        uint256 indexed requestId,
        address indexed owner,
        uint256 tranche,
        uint256 amount,
        uint256 heldUnderHalf,
        uint256 heldHalf,
        uint256 heldFull
    );
    event WithdrawCancelled(uint256 indexed requestId, address indexed owner);
    event WithdrawFulfilled(
        uint256 indexed requestId, address indexed owner, uint256 tranche, uint256 amount, uint256 interest
    );
    event IntroducerFeeDue(uint256 indexed requestId, address indexed introducer);
    event IntroducerFeePaid(uint256 indexed requestId, address indexed introducer, uint256 amount);
    event InterestFunded(uint256 indexed tranche, uint256 amount);
    event InterestWithdrawn(uint256 indexed tranche, uint256 amount);
    event CapitalTransferredOut(address indexed to, uint256 amount);
    event CapitalReturned(uint256 amount);
    event WhitelistSet(address indexed wallet, bool allowed);
    event IntroducerSet(address indexed wallet, address indexed introducer);
    event OperatorSet(address indexed operator, bool allowed);
    event MinimumsSet(uint256 opening, uint256 topUp);

    error InvalidConfig();
    error ZeroAddress();
    error ZeroAmount();
    error RenounceDisabled();
    error NotOperator();
    error NotWhitelisted(address wallet);
    error BelowMinimum(uint256 amount, uint256 minimum);
    error ExceedsCapacity(uint256 room);
    error UnknownTranche(uint256 tranche);
    error ExceedsAvailable(uint256 available, uint256 amount);
    error UnknownRequest(uint256 requestId);
    error NotRequestOwner();
    error NotPending();
    error RequestPending(uint256 requestId);
    error FeeNotDue(uint256 requestId);
    error InsufficientCapital(uint256 available, uint256 needed);
    error InsufficientInterest(uint256 available, uint256 needed);
    error ExceedsDeployed(uint256 deployed, uint256 amount);
    error InvalidRecipient(address to);
    error RoleConflict(address account);
    error PlacementChanged(uint256 tranche, uint256 placed, uint256 minimum);

    constructor(
        IERC20Metadata usdt_,
        address safe,
        uint256[TRANCHE_COUNT] memory sizes,
        uint64 halfTierAfter_,
        uint64 fullTierAfter_,
        uint256 openingMinimum_,
        uint256 topUpMinimum_
    ) Ownable(safe) {
        if (address(usdt_) == address(0)) revert ZeroAddress();
        if (halfTierAfter_ == 0 || fullTierAfter_ <= halfTierAfter_) revert InvalidConfig();
        if (topUpMinimum_ == 0 || openingMinimum_ < topUpMinimum_) revert InvalidConfig();
        uint8 lpDecimals = usdt_.decimals();
        for (uint256 i; i < TRANCHE_COUNT; ++i) {
            if (sizes[i] == 0 || sizes[i] > type(uint128).max) revert InvalidConfig();
            _tranches[i].size = sizes[i];
            string memory n = Strings.toString(i + 1);
            _lp[i] = new TrancheToken(string.concat("DEOS-X Yield Tranche ", n), string.concat("dxT", n), lpDecimals);
        }
        usdt = IERC20(address(usdt_));
        halfTierAfter = halfTierAfter_;
        fullTierAfter = fullTierAfter_;
        openingMinimum = openingMinimum_;
        topUpMinimum = topUpMinimum_;
    }

    modifier onlyOperator() {
        _checkOperator();
        _;
    }

    // ---------------------------------------------------------------------
    // Investor actions
    // ---------------------------------------------------------------------

    /// @notice Deposit `amount` USDT. What arrives fills T1's room, then T2's, then T3's; each piece opens a position
    /// and mints that tranche's LP 1:1. `minPieces` is the least the caller accepts in each tranche (pass what
    /// `previewDeposit` returned): if a deposit mined first changed the split, this one reverts instead of landing in a
    /// lower tranche. Zeros accept any split. A deposit that fills exactly all the room left is exempt from the minimum,
    /// so the last room can always be filled.
    function deposit(uint256 amount, uint256[TRANCHE_COUNT] calldata minPieces) external nonReentrant whenNotPaused {
        if (!isWhitelisted[msg.sender]) revert NotWhitelisted(msg.sender);
        if (amount == 0) revert ZeroAmount();
        uint256 received = _pull(amount);
        if (received == 0) revert ZeroAmount();
        uint256 minimum = capitalOf[msg.sender] == 0 ? openingMinimum : topUpMinimum;
        if (received < minimum && received != _totalRoom()) revert BelowMinimum(received, minimum);
        uint256[TRANCHE_COUNT] memory pieces = _place(received);
        for (uint256 i; i < TRANCHE_COUNT; ++i) {
            if (pieces[i] < minPieces[i]) revert PlacementChanged(i, pieces[i], minPieces[i]);
        }

        for (uint256 i; i < TRANCHE_COUNT; ++i) {
            uint256 piece = pieces[i];
            if (piece == 0) continue;
            _positions[msg.sender][i].push(Position({amount: piece, depositedAt: uint64(block.timestamp)}));
            _capitalIn[msg.sender][i] += piece;
            _tranches[i].taken += piece;
            _tranches[i].capital += piece;
        }
        capitalOf[msg.sender] += received;

        emit Deposited(msg.sender, received, pieces);

        // The books are final before any LP is minted.
        for (uint256 i; i < TRANCHE_COUNT; ++i) {
            if (pieces[i] != 0) _lp[i].mint(msg.sender, pieces[i]);
        }
    }

    /// @notice Ask to withdraw `amount` of your capital in `tranche`: any amount from 1 unit up to what is free there
    /// (no minimum). A wallet has at most one pending request at a time, across all tranches; while it has one, a new
    /// request reverts with `RequestPending`. Cancel it or wait for it to be paid.
    /// Takes the wallet's oldest units in that tranche and records, as of the request, how much of it has been held
    /// under `halfTierAfter`, up to `fullTierAfter`, and longer. That split is final: the request is paid on it.
    function requestWithdraw(uint256 tranche, uint256 amount) external whenNotPaused returns (uint256 requestId) {
        _checkTranche(tranche);
        if (amount == 0) revert ZeroAmount();
        uint256 open = openRequestOf[msg.sender];
        if (open != 0) revert RequestPending(open);
        // With no request open nothing is reserved, so all of the wallet's capital in the tranche is free.
        uint256 free = _capitalIn[msg.sender][tranche];
        if (amount > free) revert ExceedsAvailable(free, amount);

        (uint256 underHalf, uint256 half, uint256 full) =
            _snapshot(msg.sender, tranche, amount, uint64(block.timestamp));
        reserved[msg.sender][tranche] = amount;

        requestId = ++_requestCount;
        Request storage r = _requests[requestId];
        r.owner = msg.sender;
        // forge-lint: disable-next-line(unsafe-typecast)
        r.tranche = uint8(tranche); // safe: checked against TRANCHE_COUNT at entry
        r.requestedAt = uint64(block.timestamp);
        r.status = RequestStatus.Pending;
        r.introducer = introducerOf[msg.sender];
        r.amount = amount;
        r.heldUnderHalf = underHalf;
        r.heldHalf = half;
        r.heldFull = full;
        _pending.add(requestId);
        openRequestOf[msg.sender] = requestId;

        emit WithdrawRequested(requestId, msg.sender, tranche, amount, underHalf, half, full);
    }

    /// @notice Cancel your pending request; its capital is free to request again, and you can make a new request.
    function cancelWithdraw(uint256 requestId) external {
        Request storage r = _requests[requestId];
        if (r.status == RequestStatus.None) revert UnknownRequest(requestId);
        if (r.owner != msg.sender) revert NotRequestOwner();
        if (r.status != RequestStatus.Pending) revert NotPending();

        reserved[msg.sender][r.tranche] = 0;
        r.status = RequestStatus.Cancelled;
        _pending.remove(requestId);
        openRequestOf[msg.sender] = 0;

        emit WithdrawCancelled(requestId, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Owner: pots and capital
    // ---------------------------------------------------------------------

    /// @notice Pre-fund `tranche`'s interest pot from the owner.
    function fundInterest(uint256 tranche, uint256 amount) external nonReentrant onlyOwner {
        _checkTranche(tranche);
        if (amount == 0) revert ZeroAmount();
        uint256 received = _pull(amount);
        _tranches[tranche].interestPot += received;
        totalInterestPot += received;

        emit InterestFunded(tranche, received);
    }

    /// @notice Take unused interest in `tranche`'s pot back to the owner.
    function withdrawInterest(uint256 tranche, uint256 amount) external nonReentrant onlyOwner {
        _checkTranche(tranche);
        if (amount == 0) revert ZeroAmount();
        _spendInterest(tranche, amount);

        emit InterestWithdrawn(tranche, amount);

        usdt.safeTransfer(msg.sender, amount);
    }

    /// @notice Send capital-side USDT to any address, recorded as deployed capital. Interest pots can't be sent out.
    function transferOut(address to, uint256 amount) external nonReentrant onlyOwner {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
        if (amount == 0) revert ZeroAmount();
        _requireCapital(amount);
        deployedCapital += amount;

        emit CapitalTransferredOut(to, amount);

        usdt.safeTransfer(to, amount);
    }

    /// @notice Bring deployed capital back from the owner.
    function returnCapital(uint256 amount) external nonReentrant onlyOwner {
        if (amount == 0) revert ZeroAmount();
        uint256 received = _pull(amount);
        if (received > deployedCapital) revert ExceedsDeployed(deployedCapital, received);
        deployedCapital -= received;

        emit CapitalReturned(received);
    }

    // ---------------------------------------------------------------------
    // Owner: payouts
    // ---------------------------------------------------------------------

    /// @notice Pay a pending request: burn its LP, return its capital 1:1 and add `interest` from its tranche's
    /// interest pot. If the request recorded an introducer (the wallet's introducer when the request was made), its
    /// fee becomes due. The wallet's oldest units in that tranche (the ones the request's split was measured on) leave
    /// its positions, and the wallet can make a new request. If Tether ever turns on its transfer fee, the investor
    /// receives `amount + interest` less it.
    function fulfillWithdraw(uint256 requestId, uint256 interest) external nonReentrant onlyOwner {
        Request storage r = _requests[requestId];
        if (r.status == RequestStatus.None) revert UnknownRequest(requestId);
        if (r.status != RequestStatus.Pending) revert NotPending();
        address investor = r.owner;
        uint256 tranche = r.tranche;
        uint256 amount = r.amount;
        _requireCapital(amount);

        _spendInterest(tranche, interest);
        _consumeOldest(investor, tranche, amount);
        reserved[investor][tranche] = 0;
        _capitalIn[investor][tranche] -= amount;
        capitalOf[investor] -= amount;
        _tranches[tranche].capital -= amount;
        if (tranche == REOPENING_TRANCHE) _tranches[tranche].taken -= amount;
        r.status = RequestStatus.Paid;
        r.interest = interest;
        _pending.remove(requestId);
        openRequestOf[investor] = 0;
        address introducer = r.introducer;
        if (introducer != address(0)) {
            r.feeStatus = FeeStatus.Due;
            _feesDue.add(requestId);
        }

        emit WithdrawFulfilled(requestId, investor, tranche, amount, interest);
        if (introducer != address(0)) emit IntroducerFeeDue(requestId, introducer);

        _lp[tranche].burn(investor, amount);
        usdt.safeTransfer(investor, amount + interest);
    }

    /// @notice Pay the introducer recorded on a paid request `amount` from that tranche's interest pot. Once per
    /// request; 0 closes the fee without paying. If Tether ever turns on its transfer fee, the introducer receives
    /// `amount` less it.
    function payIntroducerFee(uint256 requestId, uint256 amount) external nonReentrant onlyOwner {
        Request storage r = _requests[requestId];
        if (r.feeStatus != FeeStatus.Due) revert FeeNotDue(requestId);
        _spendInterest(r.tranche, amount);
        r.feeStatus = FeeStatus.Paid;
        r.fee = amount;
        _feesDue.remove(requestId);
        address introducer = r.introducer;

        emit IntroducerFeePaid(requestId, introducer, amount);

        if (amount != 0) usdt.safeTransfer(introducer, amount);
    }

    // ---------------------------------------------------------------------
    // Owner and operators: settings
    // ---------------------------------------------------------------------

    /// @notice Appoint or remove an operator. A wallet that is whitelisted or still holds capital can't be appointed:
    /// staff and investors are kept apart, so it must be off the whitelist and fully paid out first. Removing is always
    /// allowed.
    function setOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        if (allowed && _isInvestor(operator)) revert RoleConflict(operator);
        isOperator[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    /// @notice Set the opening and top-up minimums for deposits (the constructor enforces the same bounds): the
    /// top-up minimum can't be 0 or above the opening minimum. Withdrawal requests have no minimum.
    function setMinimums(uint256 opening, uint256 topUp) external onlyOwner {
        if (topUp == 0 || opening < topUp) revert InvalidConfig();
        openingMinimum = opening;
        topUpMinimum = topUp;
        emit MinimumsSet(opening, topUp);
    }

    /// @notice Allow or stop deposits from `wallet`. An operator, the owner or the pending owner can't be whitelisted:
    /// staff and investors are kept apart. Removing is always allowed.
    function setWhitelisted(address wallet, bool allowed) external onlyOperator {
        if (wallet == address(0)) revert ZeroAddress();
        if (allowed && (isOperator[wallet] || wallet == owner() || wallet == pendingOwner())) {
            revert RoleConflict(wallet);
        }
        isWhitelisted[wallet] = allowed;
        emit WhitelistSet(wallet, allowed);
    }

    /// @notice Record `wallet`'s introducer (zero for none). Never the vault itself, which would move pot money onto the
    /// capital side, nor USDT or an LP token, which could never spend a fee paid to them. A withdrawal request takes
    /// the introducer the wallet has when it is made.
    function setIntroducer(address wallet, address introducer) external onlyOperator {
        if (wallet == address(0)) revert ZeroAddress();
        if (introducer == address(this) || introducer == address(usdt) || _isLpToken(introducer)) {
            revert InvalidRecipient(introducer);
        }
        introducerOf[wallet] = introducer;
        emit IntroducerSet(wallet, introducer);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Disabled so the vault can never be left without an owner.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Start handing the vault to `newOwner` (two steps). A wallet that is whitelisted or still holds capital
    /// can't be made owner.
    function transferOwnership(address newOwner) public override onlyOwner {
        if (_isInvestor(newOwner)) revert RoleConflict(newOwner);
        super.transferOwnership(newOwner);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function trancheInfo(uint256 i) external view returns (TrancheView memory v) {
        _checkTranche(i);
        Tranche storage t = _tranches[i];
        v = TrancheView({
            size: t.size,
            taken: t.taken,
            room: _room(i),
            capital: t.capital,
            interestPot: t.interestPot,
            lpToken: address(_lp[i])
        });
    }

    /// @notice Where a deposit of `amount` would be placed now. Reverts with `ExceedsCapacity` like `deposit`.
    function previewDeposit(uint256 amount) external view returns (uint256[TRANCHE_COUNT] memory) {
        return _place(amount);
    }

    /// @notice `wallet`'s open positions in `tranche`, oldest first, with how long each has been held and its tier
    /// in basis points (0, 5000 or 10000). Positions paid out in full are left out.
    function positionsOf(address wallet, uint256 tranche) external view returns (PositionView[] memory views) {
        _checkTranche(tranche);
        Position[] storage list = _positions[wallet][tranche];
        uint256 head = _head[wallet][tranche];
        views = new PositionView[](list.length - head);
        for (uint256 j = head; j < list.length; ++j) {
            uint64 heldFor = uint64(block.timestamp) - list[j].depositedAt;
            views[j - head] = PositionView({
                amount: list[j].amount, depositedAt: list[j].depositedAt, heldFor: heldFor, tierBps: _tierBps(heldFor)
            });
        }
    }

    /// @notice `wallet`'s capital in `tranche` not yet set aside by a pending request.
    function available(address wallet, uint256 tranche) external view returns (uint256) {
        _checkTranche(tranche);
        return _capitalIn[wallet][tranche] - reserved[wallet][tranche];
    }

    /// @notice The request record. Its split is the one measured at `requestedAt`, which a pending request is paid on.
    function getRequest(uint256 requestId) external view returns (Request memory) {
        Request memory r = _requests[requestId];
        if (r.status == RequestStatus.None) revert UnknownRequest(requestId);
        return r;
    }

    function requestCount() external view returns (uint256) {
        return _requestCount;
    }

    /// @notice Request ids waiting to be paid, in no particular order.
    function pendingRequests() external view returns (uint256[] memory) {
        return _pending.values();
    }

    /// @notice Paid request ids whose introducer fee is due and not yet paid, in no particular order.
    function feesDue() external view returns (uint256[] memory) {
        return _feesDue.values();
    }

    /// @return usdtInVault USDT the vault holds.
    /// @return capitalOwed Capital owed to investors (the LP supply of all tranches).
    /// @return interestPots Sum of all tranches' interest pots.
    /// @return capitalCash USDT on the capital side: what `transferOut` and payouts of capital can use. 0 if the vault
    /// ever holds less than its interest pots.
    /// @return deployed Capital sent out with `transferOut` and not yet returned.
    function vaultState()
        external
        view
        returns (uint256 usdtInVault, uint256 capitalOwed, uint256 interestPots, uint256 capitalCash, uint256 deployed)
    {
        for (uint256 i; i < TRANCHE_COUNT; ++i) {
            capitalOwed += _tranches[i].capital;
        }
        usdtInVault = usdt.balanceOf(address(this));
        return (usdtInVault, capitalOwed, totalInterestPot, _capitalCash(usdtInVault), deployedCapital);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Pulls `amount` from the caller and returns what actually arrived, so a token fee can't be credited.
    function _pull(uint256 amount) private returns (uint256 received) {
        uint256 before = usdt.balanceOf(address(this));
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        received = usdt.balanceOf(address(this)) - before;
    }

    function _room(uint256 i) private view returns (uint256) {
        return _tranches[i].size - _tranches[i].taken;
    }

    function _totalRoom() private view returns (uint256 room) {
        for (uint256 i; i < TRANCHE_COUNT; ++i) {
            room += _room(i);
        }
    }

    /// @dev An investor is a wallet that may deposit or still has capital in the vault, whitelisted or not.
    function _isInvestor(address account) private view returns (bool) {
        return isWhitelisted[account] || capitalOf[account] != 0;
    }

    function _isLpToken(address account) private view returns (bool) {
        for (uint256 i; i < TRANCHE_COUNT; ++i) {
            if (account == address(_lp[i])) return true;
        }
        return false;
    }

    /// @dev The waterfall: fill T1's room, then T2's, then T3's. Reverts if `amount` doesn't fit.
    function _place(uint256 amount) private view returns (uint256[TRANCHE_COUNT] memory pieces) {
        uint256 left = amount;
        uint256 room;
        for (uint256 i; i < TRANCHE_COUNT; ++i) {
            uint256 free = _room(i);
            room += free;
            uint256 piece = left < free ? left : free;
            pieces[i] = piece;
            left -= piece;
        }
        if (left > 0) revert ExceedsCapacity(room);
    }

    function _tierBps(uint64 heldFor) private view returns (uint16) {
        if (heldFor < halfTierAfter) return 0;
        return heldFor < fullTierAfter ? HALF_TIER_BPS : FULL_TIER_BPS;
    }

    /// @dev Splits the oldest `amount` units of `wallet`'s capital in `tranche` by how long each had been held at
    /// `asOf`.
    function _snapshot(address wallet, uint256 tranche, uint256 amount, uint64 asOf)
        private
        view
        returns (uint256 underHalf, uint256 half, uint256 full)
    {
        Position[] storage list = _positions[wallet][tranche];
        uint256 left = amount;
        for (uint256 j = _head[wallet][tranche]; left > 0; ++j) {
            uint256 have = list[j].amount;
            uint256 take = have < left ? have : left;
            left -= take;
            uint16 tier = _tierBps(asOf - list[j].depositedAt);
            if (tier == 0) underHalf += take;
            else if (tier == HALF_TIER_BPS) half += take;
            else full += take;
        }
    }

    /// @dev Removes the oldest `amount` units of `wallet`'s positions in `tranche`: positions emptied are passed by the
    /// head, and the next one is reduced in place, keeping its date. Every position from the head on stays non-empty.
    function _consumeOldest(address wallet, uint256 tranche, uint256 amount) private {
        Position[] storage list = _positions[wallet][tranche];
        uint256 head = _head[wallet][tranche];
        while (amount > 0) {
            uint256 have = list[head].amount;
            if (have > amount) {
                list[head].amount = have - amount;
                break;
            }
            list[head].amount = 0;
            amount -= have;
            ++head;
        }
        _head[wallet][tranche] = head;
    }

    function _spendInterest(uint256 tranche, uint256 amount) private {
        uint256 pot = _tranches[tranche].interestPot;
        if (pot < amount) revert InsufficientInterest(pot, amount);
        _tranches[tranche].interestPot = pot - amount;
        totalInterestPot -= amount;
    }

    function _requireCapital(uint256 needed) private view {
        uint256 cash = _capitalCash(usdt.balanceOf(address(this)));
        if (cash < needed) revert InsufficientCapital(cash, needed);
    }

    /// @dev Capital-side cash out of a vault `balance`: what isn't interest pots, or 0 if the balance is below them
    /// (only if Tether destroys or seizes vault funds).
    function _capitalCash(uint256 balance) private view returns (uint256) {
        uint256 pots = totalInterestPot;
        return balance > pots ? balance - pots : 0;
    }

    function _checkTranche(uint256 i) private pure {
        if (i >= TRANCHE_COUNT) revert UnknownTranche(i);
    }

    function _checkOperator() private view {
        if (!isOperator[msg.sender] && msg.sender != owner()) revert NotOperator();
    }
}
