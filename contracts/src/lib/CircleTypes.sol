// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KuberRegistry} from "../KuberRegistry.sol";

// AGREE_CAP = contribution and AGREE_RATE = offered / 2 are formulas (Backing.back, Queue._fundOne); MAX_ACTIVE_CIRCLES
// lives in KuberRegistry.
uint256 constant BPS = 10_000;
uint256 constant MAX_MEMBERS = 50;
uint256 constant MIN_MEMBERS_FLOOR = 5;
uint256 constant MIN_SAVE_FLOOR = 3;
uint256 constant MAX_EPOCHS = 60;
uint256 constant MIN_EPOCH_DURATION = 30;
uint256 constant MIN_INVITES = 4;
uint256 constant SUSPEND_AT = 3;
uint256 constant MAX_OFFERED_RATE = 3_000;
uint256 constant MAX_EXTRA = 1_000;
uint256 constant MAX_VOUCHERS = 10;
uint256 constant MAX_AGREERS = 10;
uint256 constant JOINS_PER_EPOCH = 1;
uint256 constant MAX_OPEN_JOINS = 5;

enum CircleStatus {
    Forming,
    Active,
    Ended,
    Cancelled
}

enum MemberStatus {
    None,
    Active,
    Suspended,
    Left,
    Kicked
}

enum LoanStatus {
    None,
    Pending,
    Funded,
    Repaid,
    Defaulted,
    Cancelled,
    Expired
}

enum Lane {
    None,
    Aged,
    Fast,
    Line
}

enum BackingTier {
    Vouch,
    Agree
}

enum ProposalKind {
    Rule,
    Allocation,
    Manager,
    Kick,
    Join
}

enum ProposalStatus {
    None,
    Open,
    Passed,
    Failed,
    Applied,
    Dropped
}

enum Window {
    Open,
    Lock
}

struct FixedParams {
    uint128 contribution;
    uint32 epochDuration;
    uint16 lockBps;
    uint64 startTime;
    uint8 minSaveEpochs;
    uint8 totalEpochs;
    uint8 minMembers;
    uint8 maxMembers;
    uint8 maxRepayEpochs;
    uint8 cooldownEpochs;
}

struct Alloc {
    uint16 loan;
    uint16 aave;
    uint16 lp;
    uint16 cash;
}

struct RuleParams {
    uint16 ownLtvBps;
    uint16 ownRateBps;
    uint16 perLoanMaxBps;
    uint16 fastLaneBps;
    uint16 penaltyBps;
    uint16 contribFineBps;
    uint16 installFineBps;
    uint16 exitFeeBps;
    uint16 managerFeeBps;
    Alloc alloc;
}

// Bit k of a bitmap is epoch k (totalEpochs <= 60).
struct Member {
    uint128 savings;
    uint128 pledgedOut;
    uint256 weight;
    uint128 rewards;
    uint128 claimable;
    uint64 paidBitmap;
    uint64 missedBitmap;
    uint32 activeLoanId;
    uint32 pendingRequestId;
    uint8 paidCount;
    uint8 lastAccrual;
    uint8 cooldownUntil;
    MemberStatus status;
    bool everBorrowed;
    bool withdrawn;
    bool leavePending;
    uint16 leaveExitFeeBps;
    address sponsor;
    // The member's latest defaulted loan; debtOf reads its unpaid losses, fines, and penalty.
    uint32 debtLoanId;
    // A reinstated member is collected again from this epoch on (R-N2: rounds missed while paused are not owed).
    uint8 reinstatedEpoch;
}

struct Backing {
    address backer;
    uint128 amount;
    uint128 interest;
    uint128 interestPaid;
    uint128 loss;
}

// vouchers / agreers hold at most MAX_VOUCHERS / MAX_AGREERS distinct addresses (R-D).
struct Loan {
    address borrower;
    uint16 offeredRateBps;
    uint16 extraBps;
    uint16 ownLtvBps;
    uint16 ownRateBps;
    uint16 penaltyBps;
    uint16 installFineBps;
    uint128 amount;
    uint128 ownPart;
    uint128 backedNeed;
    uint128 principalRepaid;
    uint128 saverInterest;
    uint8 repayEpochs;
    uint8 requestedEpoch;
    uint8 age;
    uint8 fundedEpoch;
    uint8 installmentsPaid;
    uint8 missedCount;
    Lane lane;
    LoanStatus status;
    Backing[] vouchers;
    Backing[] agreers;
    uint128 unclaimed;
    uint128 finesOwed;
    uint128 penaltyOwed;
    // The last epoch whose collect pass checked this loan; fines count the settlements that found an installment
    // unpaid (04-ADDENDUM A-1).
    uint8 lastCollectEpoch;
}

// Rule uses `field` (the RuleParams index) and `value`; Manager, Kick, Join use `target`; Allocation uses `alloc`.
struct Proposal {
    ProposalKind kind;
    ProposalStatus status;
    uint8 epoch;
    uint8 field;
    uint16 value;
    uint16 yes;
    uint16 no;
    address proposer;
    address target;
    Alloc alloc;
}

library CircleStorage {
    struct Layout {
        KuberRegistry registry;
        IERC20 token;
        address aaveVault;
        address lpVault;
        address creator;
        uint8 settledEpoch;
        uint16 cursor;
        uint8 wActiveLast;
        uint8 wSaverLast;
        CircleStatus status;
        string name;
        FixedParams fixedParams;
        RuleParams rules;
        uint256 sTotal;
        uint256 sActive;
        uint256 sSaver;
        uint256 wActive;
        uint256 wSaver;
        uint256 outstandingPrincipal;
        uint256 reservedClaims;
        uint256 totalRewardsOwed;
        uint256 saverPot;
        uint256 expenses;
        // Append-only while Active: the settlement cursor indexes it (later phases change status, never remove).
        address[] memberList;
        mapping(address => Member) members;
        mapping(address => bool) invited;
        mapping(address => bool) joinRequested;
        mapping(uint256 => Loan) loans;
        uint256 loanCount;
        int256 finalYieldPot;
        uint256 finalWActive;
        uint256 finalWSaver;
        uint256 finalSaverPot;
        uint256 finalSTotal;
        // Combined Aave and LP value after the latest rebalance, for the M6 manager track record (R-K).
        uint256 vaultValueAfterRebalance;
        // Tokens ensureCash pulled from the vaults since that rebalance, so a payout does not read as a loss.
        uint256 vaultPulledSinceRebalance;
        // Pending request ids in ascending id order, which is D-07's oldest-first order (ids and request epochs
        // only grow); at most one per member.
        uint32[] pendingIds;
        // The fund manager, 0 if none (06-04).
        address manager;
        // Target of the open Kick; it cannot request or back while set (D-07, 06-02).
        address kickTarget;
        // Bit f: a Rule proposal on field f is open; bit 9 Allocation, bit 10 Manager appoint, bit 11 Kick, bit 12
        // Manager fire (R-J2: firing has its own slot).
        uint16 openMask;
        // Open Join proposals (06-03).
        uint8 openJoins;
        // First approvedJoins entry not yet admitted or dropped (06-03).
        uint16 joinHead;
        uint256 proposalCount;
        // Proposals created in the current epoch, oldest first; every settlement tallies and empties it.
        uint32[] openIds;
        // Passed Join proposals, oldest approval first (06-03).
        uint32[] approvedJoins;
        // Members with a pending leave, one entry each (06-02).
        address[] leaveQueue;
        mapping(uint256 => Proposal) proposals;
        // 1 yes, 2 no.
        mapping(uint256 => mapping(address => uint8)) ballots;
        // 1 applied, 2 has an open or approved Join (06-03).
        mapping(address => uint8) applicants;
        // 06-03.
        mapping(address => bool) hasSponsored;
        // R-J2: the last epoch in which the member opened a proposal (one per member per round, a sponsor's Join
        // included).
        mapping(address => uint8) lastProposedEpoch;
        // R-J2: the epoch in which no Kick on this member may be proposed, the round after a failed Kick (06-02).
        mapping(address => uint8) kickBlockedEpoch;
        // 07 D-05: gas reimbursed so far for the epoch being settled, zeroed when that settlement completes.
        uint256 epochReimbursed;
        // Protocol + manager fees credited so far (PAGES P5b).
        uint256 feesCharged;
    }
}

interface IKuberCircleErrors {
    error NotVerified();
    error HasOpenDebt();
    error TooFewInvites();
    error TooManyInvites();
    error InvalidInvite();
    error ZeroAddress();
    error NotCreator();
    error NotForming();
    error FormingClosed();
    error NotInvited();
    error AlreadyMember();
    error CircleFull();
    error NotMember();
    error CreatorCannotLeave();
    error TooEarly();
    error NotActive();
    error EpochNotEnded();
    error ZeroBatch();
    error AlreadyPaid();
    error CycleOver();
    error NotMissed();
    error LockWindow();
    error SettlementPending();
    error NotEnded();
    error AlreadyWithdrawn();
    error NothingToClaim();
    error InvalidContribution();
    error InvalidEpochDuration();
    error InvalidLockBps();
    error InvalidStartTime();
    error InvalidMinSaveEpochs();
    error InvalidTotalEpochs();
    error InvalidMemberBounds();
    error InvalidMaxRepayEpochs();
    error InvalidCooldownEpochs();
    error InvalidOwnLtv();
    error InvalidOwnRate();
    error InvalidPerLoanMax();
    error InvalidFastLane();
    error InvalidAllocation();
    error InvalidPenalty();
    error InvalidContribFine();
    error InvalidInstallFine();
    error InvalidExitFee();
    error InvalidManagerFee();
    error InsufficientLiquidity();
    error InvalidVault();
    error NotEnoughSaved();
    error HasActiveLoan();
    error HasPendingRequest();
    error InCooldown();
    error InvalidRepayEpochs();
    error RepayPastEnd();
    error InvalidOfferedRate();
    error InvalidExtra();
    error ZeroAmount();
    error LeavePending();
    error NotBorrower();
    error NotPending();
    error NothingDue();
    error NoActiveLoan();
    error ExceedsFreeSavings();
    error OverPledged();
    error OtherTier();
    error AgreeCapExceeded();
    error TooManyBackers();
    error NotBacker();
    error GroupLoss();
    error NoDebt();
    error CallerNotCircle();
    error InvalidProposal();
    error InvalidRuleField();
    error ProposalOpen();
    error VotingClosed();
    error AlreadyVoted();
    error AlreadyProposed();
    error HasPledges();
    error NoLeavePending();
    error InvalidTarget();
    error TargetCannotVote();
    error KickPending();
    error KickCooldown();
    error JoinClosed();
    error AlreadyApplied();
    error NotApplicant();
    error AlreadySponsored();
    error TooManyJoins();
    error AtMembershipCap();
    error OnlyManager();
    error IsManager();
}

interface IKuberCircleEvents {
    event Invited(address indexed who);
    event JoinRequested(address indexed who);
    event Joined(address indexed who);
    event Activated();
    event Cancelled();
    event EpochSettled(uint256 indexed epoch);
    event ContributionPaid(address indexed member, uint256 indexed epoch, uint256 amount);
    event ContributionMissed(address indexed member, uint256 indexed epoch);
    event CaughtUp(address indexed member, uint256 indexed epoch, uint256 fine);
    event LoanRequested(
        uint256 indexed id,
        address indexed borrower,
        uint256 amount,
        uint256 repayEpochs,
        uint256 offeredRateBps,
        uint256 extraBps
    );
    event Backed(uint256 indexed id, address indexed backer, BackingTier tier, uint256 amount);
    event Unbacked(uint256 indexed id, address indexed backer, uint256 amount);
    event LoanFunded(uint256 indexed id, Lane lane);
    event RequestExpired(uint256 indexed id);
    event LoanClaimed(uint256 indexed id, address indexed borrower, uint256 amount);
    event InstallmentPaid(uint256 indexed id, uint256 installment, uint256 amount);
    event InstallmentMissed(uint256 indexed id, uint256 installment);
    event FineCharged(uint256 indexed id, address indexed member, uint256 amount);
    event LoanRepaid(uint256 indexed id, bool onTime);
    event MemberSuspended(
        uint256 indexed loanId,
        uint256 owed,
        uint256 fromBorrower,
        uint256 fromVouchers,
        uint256 fromAgreers,
        uint256 penaltyPaid,
        uint256 debt
    );
    event DebtRepaid(address indexed member, uint256 amount, uint256 remaining);
    event LienPaid(address indexed person, address indexed toCircle, uint256 amount);
    event MemberReinstated(address indexed member);
    event Rebalanced(uint256 aaveValue, uint256 lpValue, uint256 cash);
    event ProposalCreated(uint256 indexed id, ProposalKind kind, address indexed proposer, bytes data);
    event Voted(uint256 indexed id, address indexed voter, bool yes);
    event ProposalPassed(uint256 indexed id);
    event ProposalApplied(uint256 indexed id);
    event ManagerChanged(address indexed manager);
    event LeaveRequested(address indexed member);
    event MemberLeft(address indexed member, uint256 payout);
    event MemberKicked(address indexed member, uint256 payout);
    event JoinApplied(address indexed applicant);
    event Sponsored(address indexed sponsor, address indexed applicant, uint256 proposalId);
    event MemberAdmitted(address indexed member);
    event GasReimbursed(address indexed caller, uint256 amount);
    event FeesCharged(uint256 protocolFee, uint256 managerFee);
    event Finalized(int256 yieldPot, uint256 wActive, uint256 wSaver, uint256 saverPot, uint256 sTotal);
    event Withdrawn(address indexed member, uint256 amount);
    event Claimed(address indexed member, uint256 amount);
}
