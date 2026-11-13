// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract KuberRegistry is Ownable {
    struct MemberStats {
        uint32 circlesJoined;
        uint32 circlesCompleted;
        uint32 loansTaken;
        uint32 repaidOnTime;
        uint32 lateInstallments;
        uint32 suspensions;
        uint32 kicks;
    }

    struct SponsorStats {
        uint32 sponsoredCount;
        uint32 sponsoredCompleted;
        uint32 sponsoredSuspended;
    }

    struct ManagerStats {
        uint32 managedEpochs;
        int256 managedYieldBpsSum;
    }

    uint256 public constant MAX_ACTIVE_CIRCLES = 5;
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 2_000;

    address public factory;
    address public treasury;
    uint16 public protocolFeeBps = 1_000;
    uint256 public avaxPriceUsd6;
    uint256 public gasPriceCap;
    uint256 public maxReimbursePerEpoch;
    mapping(address => bool) public verified;
    mapping(address => bool) public isCircle;
    mapping(address => uint256) public activeMemberships;
    mapping(address => MemberStats) internal _memberStats;
    mapping(address => SponsorStats) internal _sponsorStats;
    mapping(address => ManagerStats) internal _managerStats;
    mapping(address => address[]) internal _debts;

    event VerifiedSet(address indexed account, bool isVerified);
    event FactorySet(address indexed factory);
    event CircleAuthorized(address indexed circle);
    event TreasurySet(address indexed treasury);
    event ProtocolFeeSet(uint16 bps);
    event GasSettingsSet(uint256 avaxPriceUsd6, uint256 gasPriceCap, uint256 maxReimbursePerEpoch);
    event DebtAdded(address indexed person, address indexed circle);
    event DebtCleared(address indexed person, address indexed circle);

    error ZeroAddress();
    error FactoryAlreadySet();
    error NotFactory(address caller);
    error NotCircle(address caller);
    error MembershipCapReached(address person);
    error FeeTooHigh(uint16 bps);
    error GasSettingsOutOfBounds();

    modifier onlyCircle() {
        if (!isCircle[msg.sender]) revert NotCircle(msg.sender);
        _;
    }

    constructor(address initialOwner, address treasury_) Ownable(initialOwner) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
    }

    /// @notice Sets the mock KYC flag for `account`; only the flag is stored on chain.
    function setVerified(address account, bool isVerified) external onlyOwner {
        verified[account] = isVerified;
        emit VerifiedSet(account, isVerified);
    }

    /// @notice Sets the factory, once; only the factory can authorize circles.
    function setFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = factory_;
        emit FactorySet(factory_);
    }

    /// @notice Lets `circle` write history and debts; callable only by the factory.
    function authorizeCircle(address circle) external {
        if (msg.sender != factory) revert NotFactory(msg.sender);
        isCircle[circle] = true;
        emit CircleAuthorized(circle);
    }

    /// @notice Sets the address that receives protocol fees.
    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @notice Sets the protocol fee on positive yield, at most MAX_PROTOCOL_FEE_BPS.
    function setProtocolFeeBps(uint16 bps) external onlyOwner {
        if (bps > MAX_PROTOCOL_FEE_BPS) revert FeeTooHigh(bps);
        protocolFeeBps = bps;
        emit ProtocolFeeSet(bps);
    }

    /// @notice Sets the mock AVAX price (6 decimals), the gas price cap (wei), and the per-epoch reimbursement cap.
    function setGasSettings(uint256 avaxPriceUsd6_, uint256 gasPriceCap_, uint256 maxReimbursePerEpoch_)
        external
        onlyOwner
    {
        // AVAX <= $1,000,000, gas <= 1,000,000 gwei, reimbursement <= 1,000,000 mUSDC: M7 gas math can never overflow.
        if (avaxPriceUsd6_ > 1e12 || gasPriceCap_ > 1e15 || maxReimbursePerEpoch_ > 1e12) {
            revert GasSettingsOutOfBounds();
        }
        avaxPriceUsd6 = avaxPriceUsd6_;
        gasPriceCap = gasPriceCap_;
        maxReimbursePerEpoch = maxReimbursePerEpoch_;
        emit GasSettingsSet(avaxPriceUsd6_, gasPriceCap_, maxReimbursePerEpoch_);
    }

    // History counters emit no events: each change comes from a circle action the circle emits; readers use the views.

    /// @notice Records a join; reverts when `person` already has MAX_ACTIVE_CIRCLES active memberships.
    function recordJoin(address person) external onlyCircle {
        if (activeMemberships[person] >= MAX_ACTIVE_CIRCLES) revert MembershipCapReached(person);
        activeMemberships[person] += 1;
        _memberStats[person].circlesJoined += 1;
    }

    /// @notice Records a leave (leave, forming leave, cancel, or paused at finalize).
    function recordLeave(address person) external onlyCircle {
        _decrementActive(person);
    }

    /// @notice Records a kick.
    function recordKick(address person) external onlyCircle {
        _decrementActive(person);
        _memberStats[person].kicks += 1;
    }

    /// @notice Records that `person` finished a circle.
    function recordComplete(address person) external onlyCircle {
        _decrementActive(person);
        _memberStats[person].circlesCompleted += 1;
    }

    /// @notice Records a funded loan.
    function recordLoan(address person) external onlyCircle {
        _memberStats[person].loansTaken += 1;
    }

    /// @notice Records a fully repaid loan; counts it only when no installment was ever missed.
    function recordRepaid(address person, bool onTime) external onlyCircle {
        if (onTime) _memberStats[person].repaidOnTime += 1;
    }

    /// @notice Records an installment found unpaid at a settlement.
    function recordLateInstallment(address person) external onlyCircle {
        _memberStats[person].lateInstallments += 1;
    }

    /// @notice Records a suspension, and on the sponsor too when there is one.
    function recordSuspension(address person, address sponsor) external onlyCircle {
        _memberStats[person].suspensions += 1;
        if (sponsor != address(0)) _sponsorStats[sponsor].sponsoredSuspended += 1;
    }

    /// @notice Records that `sponsor` sponsored a mid-cycle member.
    function recordSponsored(address sponsor) external onlyCircle {
        _sponsorStats[sponsor].sponsoredCount += 1;
    }

    /// @notice Records that a member `sponsor` sponsored finished the circle.
    function recordSponsoredCompleted(address sponsor) external onlyCircle {
        _sponsorStats[sponsor].sponsoredCompleted += 1;
    }

    /// @notice Records one managed epoch and its signed yield in bps.
    function recordManagerEpoch(address manager, int256 yieldBps) external onlyCircle {
        _managerStats[manager].managedEpochs += 1;
        _managerStats[manager].managedYieldBpsSum += yieldBps;
    }

    /// @notice Adds the calling circle to `person`'s debt list; a no-op when it is already there.
    function addDebt(address person) external onlyCircle {
        // Bounded: at most 5 entries by construction (membership cap plus lockout).
        uint256 n = _debts[person].length;
        for (uint256 i; i < n; ++i) {
            if (_debts[person][i] == msg.sender) return;
        }
        _debts[person].push(msg.sender);
        emit DebtAdded(person, msg.sender);
    }

    /// @notice Removes the calling circle from `person`'s debt list; a no-op when it is absent.
    function clearDebt(address person) external onlyCircle {
        uint256 n = _debts[person].length;
        for (uint256 i; i < n; ++i) {
            if (_debts[person][i] == msg.sender) {
                _debts[person][i] = _debts[person][n - 1];
                _debts[person].pop();
                emit DebtCleared(person, msg.sender);
                return;
            }
        }
    }

    /// @notice Circles in which `person` has open debt (at most 5).
    function debtCircles(address person) external view returns (address[] memory) {
        return _debts[person];
    }

    /// @notice True when `person` has open debt in any circle.
    function hasOpenDebt(address person) external view returns (bool) {
        return _debts[person].length != 0;
    }

    /// @notice Member history of `person`.
    function memberStats(address person) external view returns (MemberStats memory) {
        return _memberStats[person];
    }

    /// @notice Sponsor history of `sponsor`.
    function sponsorStats(address sponsor) external view returns (SponsorStats memory) {
        return _sponsorStats[sponsor];
    }

    /// @notice Fund manager track record of `manager`.
    function managerStats(address manager) external view returns (ManagerStats memory) {
        return _managerStats[manager];
    }

    // Floors at 0 so a leave, kick, or finish can never revert inside a settlement.
    function _decrementActive(address person) internal {
        if (activeMemberships[person] != 0) activeMemberships[person] -= 1;
    }
}
