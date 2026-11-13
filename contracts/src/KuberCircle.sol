// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    BPS,
    CircleStatus,
    CircleStorage,
    FixedParams,
    IKuberCircleErrors,
    IKuberCircleEvents,
    Member,
    MemberStatus,
    RuleParams,
    Window
} from "./lib/CircleTypes.sol";
import {Forming} from "./lib/Forming.sol";
import {Invest} from "./lib/Invest.sol";
import {Settle} from "./lib/Settle.sol";
import {ShareOut} from "./lib/ShareOut.sol";
import {Weights} from "./lib/Weights.sol";

/// @notice A savings circle. Entry points, guards, and views live here; logic lives in linked libraries
/// that take the single storage struct `$`. No owner.
contract KuberCircle is Initializable, ReentrancyGuardTransient, IKuberCircleErrors, IKuberCircleEvents {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    struct CircleState {
        string name;
        address creator;
        CircleStatus status;
        uint256 memberCount;
        uint256 currentEpoch;
        Window window;
        uint256 settledEpoch;
        uint256 cursor;
        FixedParams fixedParams;
        RuleParams rules;
    }

    struct PublicSummary {
        uint256 cash;
        uint256 sTotal;
        uint256 saverPot;
        uint256 reservedClaims;
        uint256 totalRewardsOwed;
        uint256 outstandingPrincipal;
        uint256 expenses;
        uint256 wActive;
        uint256 wSaver;
        int256 yieldPot;
        uint256 aaveValue;
        uint256 lpValue;
    }

    CircleStorage.Layout internal $;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address creator,
        string calldata name,
        FixedParams calldata fixedParams_,
        RuleParams calldata rules_,
        address[] calldata invites
    ) external initializer {
        Forming.init($, creator, name, fixedParams_, rules_, invites);
    }

    function invite(address who) external {
        Forming.invite($, who);
    }

    function requestToJoin() external {
        Forming.requestToJoin($);
    }

    function join() external {
        Forming.join($);
    }

    function leave() external {
        Forming.leave($);
    }

    function cancel() external {
        Forming.cancel($);
    }

    function activate() external {
        Forming.activate($);
    }

    /// @notice Anyone: collects up to `maxMembers` members of the next ended, unsettled epoch (D-16).
    function settle(uint256 maxMembers) external nonReentrant {
        Settle.run($, maxMembers, currentEpoch());
    }

    /// @notice Pays the clock epoch's contribution; any window, also while settlements are pending (R-F, D-18).
    function payNow() external nonReentrant {
        if ($.status != CircleStatus.Active) revert NotActive();
        Member storage m = $.members[msg.sender];
        if (m.status != MemberStatus.Active) revert NotMember();
        uint256 e = currentEpoch();
        if (e > $.fixedParams.totalEpochs) revert CycleOver();
        uint64 bit = uint64(1 << e);
        if (m.paidBitmap & bit != 0) revert AlreadyPaid();
        uint256 c = $.fixedParams.contribution;
        m.paidBitmap |= bit;
        m.paidCount += 1;
        Weights.changeSavings($, msg.sender, int256(c), e);
        emit ContributionPaid(msg.sender, e, c);
        $.token.safeTransferFrom(msg.sender, address(this), c);
    }

    /// @notice Pays a missed epoch plus a fine per epoch late to the savers' pot; savings count from the clock
    /// epoch (N-2). The missed bit stays as history.
    function catchUp(uint256 epoch) external nonReentrant {
        if ($.status != CircleStatus.Active) revert NotActive();
        Member storage m = $.members[msg.sender];
        if (m.status != MemberStatus.Active) revert NotMember();
        if (epoch == 0 || epoch > $.fixedParams.totalEpochs) revert NotMissed();
        uint64 bit = uint64(1 << epoch);
        if (m.paidBitmap & bit != 0) revert AlreadyPaid();
        if (m.missedBitmap & bit == 0) revert NotMissed();
        uint256 e = currentEpoch();
        uint256 c = $.fixedParams.contribution;
        uint256 fine = c * $.rules.contribFineBps * (e - epoch) / BPS;
        m.paidBitmap |= bit;
        m.paidCount += 1;
        $.saverPot += fine;
        Weights.changeSavings($, msg.sender, int256(c), e);
        emit CaughtUp(msg.sender, epoch, fine);
        $.token.safeTransferFrom(msg.sender, address(this), c + fine);
    }

    /// @notice Ended only, once per Active member: the final share-out from the frozen numbers (D-20, R-F).
    function withdraw() external nonReentrant {
        if ($.status != CircleStatus.Ended) revert NotEnded();
        Member storage m = $.members[msg.sender];
        if (m.status != MemberStatus.Active) revert NotMember();
        if (m.withdrawn) revert AlreadyWithdrawn();
        uint256 amount = ShareOut.payout($, msg.sender);
        emit Withdrawn(msg.sender, amount);
        // Covers the whole payout, including what M5's lien sends elsewhere.
        Invest.ensureCash($, amount);
        uint256 toPerson = ShareOut.lien($, msg.sender, amount);
        $.token.safeTransfer(msg.sender, toPerson);
    }

    /// @notice Pays `claimable` in any window, while settlements are pending, and after Ended (R-F). No member
    /// status check: Left and Kicked members claim exit payouts from M6.
    function claim() external nonReentrant {
        if ($.status != CircleStatus.Active && $.status != CircleStatus.Ended) revert NotActive();
        uint256 amount = Weights.takeClaimable($, msg.sender);
        if (amount == 0) revert NothingToClaim();
        emit Claimed(msg.sender, amount);
        Invest.ensureCash($, amount);
        $.token.safeTransfer(msg.sender, amount);
    }

    /// @notice 0 before startTime, else (t - startTime) / epochDuration + 1 (D-15).
    function currentEpoch() public view returns (uint256) {
        uint256 start = $.fixedParams.startTime;
        if (block.timestamp < start) return 0;
        return (block.timestamp - start) / $.fixedParams.epochDuration + 1;
    }

    /// @notice OPEN for the first (BPS - lockBps) of each epoch, LOCK for the rest; OPEN before startTime.
    function currentWindow() public view returns (Window) {
        uint256 start = $.fixedParams.startTime;
        if (block.timestamp < start) return Window.Open;
        uint256 d = $.fixedParams.epochDuration;
        // Window math on the clock, not randomness.
        // slither-disable-next-line weak-prng
        return (block.timestamp - start) % d < d * (BPS - $.fixedParams.lockBps) / BPS ? Window.Open : Window.Lock;
    }

    /// @notice Action class (R-F): OPEN window and no settlement pending.
    function _checkAction() internal view {
        if ($.status != CircleStatus.Active) revert NotActive();
        if (currentWindow() != Window.Open) revert LockWindow();
        if ($.settledEpoch != currentEpoch() - 1) revert SettlementPending();
    }

    /// @notice Vote class (R-F): any window, no settlement pending.
    function _checkVote() internal view {
        if ($.status != CircleStatus.Active) revert NotActive();
        if ($.settledEpoch != currentEpoch() - 1) revert SettlementPending();
    }

    function getCircleState() external view returns (CircleState memory s) {
        s.name = $.name;
        s.creator = $.creator;
        s.status = $.status;
        s.memberCount = $.memberList.length;
        s.currentEpoch = currentEpoch();
        s.window = currentWindow();
        s.settledEpoch = $.settledEpoch;
        s.cursor = $.cursor;
        s.fixedParams = $.fixedParams;
        s.rules = $.rules;
    }

    /// @notice Live totals while running (weights through `settledEpoch`, yieldPot = V - S_total, R-R); the frozen
    /// share-out numbers once Ended (D-21). Cash and vault values are always live.
    function getPublicSummary() external view returns (PublicSummary memory p) {
        int256 v;
        (v, p.cash, p.aaveValue, p.lpValue) = Invest.valuation($);
        p.reservedClaims = $.reservedClaims;
        p.totalRewardsOwed = $.totalRewardsOwed;
        p.outstandingPrincipal = $.outstandingPrincipal;
        p.expenses = $.expenses;
        if ($.status != CircleStatus.Ended) {
            uint256 e = $.settledEpoch;
            p.sTotal = $.sTotal;
            p.saverPot = $.saverPot;
            p.wActive = Weights.accrued($.wActive, $.sActive, $.wActiveLast, e);
            p.wSaver = Weights.accrued($.wSaver, $.sSaver, $.wSaverLast, e);
            p.yieldPot = v - p.sTotal.toInt256();
        } else {
            p.sTotal = $.finalSTotal;
            p.saverPot = $.finalSaverPot;
            p.wActive = $.finalWActive;
            p.wSaver = $.finalWSaver;
            p.yieldPot = $.finalYieldPot;
        }
    }

    /// @notice The stored member, with the weight shown through at least the last settled epoch.
    function getMember(address who) external view returns (Member memory m) {
        m = $.members[who];
        m.weight = Weights.accrued(m.weight, m.savings, m.lastAccrual, $.settledEpoch);
        if ($.settledEpoch > m.lastAccrual) m.lastAccrual = $.settledEpoch;
    }

    function members() external view returns (address[] memory) {
        return $.memberList;
    }
}
