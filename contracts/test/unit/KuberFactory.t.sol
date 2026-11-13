// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {CircleTestBase} from "../utils/CircleTestBase.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {KuberFactory} from "../../src/KuberFactory.sol";
import {KuberRegistry} from "../../src/KuberRegistry.sol";
import {
    Alloc,
    CircleStatus,
    FixedParams,
    IKuberCircleErrors,
    MemberStatus,
    RuleParams
} from "../../src/lib/CircleTypes.sol";

contract KuberFactoryTest is CircleTestBase {
    function _expectCreateRevert(
        address creator,
        FixedParams memory f,
        RuleParams memory r,
        address[] memory inv,
        bytes memory err
    ) internal {
        uint256 before = factory.circleCount();
        vm.expectRevert(err);
        vm.prank(creator);
        factory.createCircle("circle", f, r, inv);
        assertEq(factory.circleCount(), before);
    }

    function _expectFixed(address[] memory ms, FixedParams memory f, bytes4 sel) internal {
        _expectCreateRevert(ms[0], f, _rules(), _tail(ms), abi.encodeWithSelector(sel));
    }

    function _expectRules(address[] memory ms, RuleParams memory r, bytes4 sel) internal {
        _expectCreateRevert(ms[0], _fixed(), r, _tail(ms), abi.encodeWithSelector(sel));
    }

    function _rulesWithAlloc(uint16 loan, uint16 aave_, uint16 lp_, uint16 cash)
        internal
        pure
        returns (RuleParams memory r)
    {
        r = _rules();
        r.alloc = Alloc(loan, aave_, lp_, cash);
    }

    // Fresh verified creator per case: one creator would hit the 5-circle cap (A-5).
    function _createOk(FixedParams memory f, RuleParams memory r) internal {
        address[] memory ms = _newMembers(5);
        address[] memory inv = _tail(ms);
        vm.prank(ms[0]);
        KuberCircle c = KuberCircle(factory.createCircle("circle", f, r, inv));
        KuberCircle.CircleState memory s = c.getCircleState();
        assertEq(abi.encode(s.fixedParams), abi.encode(f), "fixed params stored");
        assertEq(abi.encode(s.rules), abi.encode(r), "rules stored");
    }

    function _addrs(uint256 n) internal pure returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = address(uint160(0x10_000 + i));
        }
    }

    function test_T_FAC_1_fewerThanFourDistinctInvitees() public {
        address[] memory ms = _newMembers(5);
        address[] memory inv = new address[](3);
        (inv[0], inv[1], inv[2]) = (ms[1], ms[2], ms[3]);
        bytes memory err = abi.encodeWithSelector(IKuberCircleErrors.TooFewInvites.selector);
        _expectCreateRevert(ms[0], _fixed(), _rules(), inv, err);

        inv = new address[](4);
        (inv[0], inv[1], inv[2], inv[3]) = (ms[1], ms[2], ms[3], ms[1]);
        _expectCreateRevert(ms[0], _fixed(), _rules(), inv, err);

        inv[3] = ms[4];
        FixedParams memory f = _fixed();
        vm.prank(ms[0]);
        factory.createCircle("circle", f, _rules(), inv);
        assertEq(factory.circleCount(), 1);
    }

    function test_T_FAC_1_zeroOrSelfInvite() public {
        address[] memory ms = _newMembers(5);
        address[] memory inv = new address[](5);
        (inv[0], inv[1], inv[2], inv[3]) = (ms[1], ms[2], ms[3], ms[4]);
        bytes memory err = abi.encodeWithSelector(IKuberCircleErrors.InvalidInvite.selector);
        _expectCreateRevert(ms[0], _fixed(), _rules(), inv, err); // inv[4] is address(0)
        inv[4] = ms[0];
        _expectCreateRevert(ms[0], _fixed(), _rules(), inv, err);
    }

    function test_T_FAC_1_tooManyInvites() public {
        address[] memory ms = _newMembers(1);
        _expectCreateRevert(
            ms[0], _fixed(), _rules(), _addrs(51), abi.encodeWithSelector(IKuberCircleErrors.TooManyInvites.selector)
        );
        FixedParams memory f = _fixed();
        address[] memory inv = _addrs(50);
        vm.prank(ms[0]);
        factory.createCircle("circle", f, _rules(), inv);
        assertEq(factory.circleCount(), 1);
    }

    function test_T_FAC_1_unverifiedCreator() public {
        address[] memory ms = _newMembers(5);
        registry.setVerified(ms[0], false);
        _expectFixed(ms, _fixed(), IKuberCircleErrors.NotVerified.selector);
    }

    function test_T_FAC_1_indebtedCreator() public {
        address[] memory ms = _newMembers(5);
        _debt(ms[0]);
        _expectFixed(ms, _fixed(), IKuberCircleErrors.HasOpenDebt.selector);
    }

    function _sixthCreateReverts() internal {
        address[] memory ms = _newMembers(5);
        for (uint256 i; i < 5; ++i) {
            _create(ms);
        }
        assertEq(registry.activeMemberships(ms[0]), 5);
        _expectCreateRevert(
            ms[0],
            _fixed(),
            _rules(),
            _tail(ms),
            abi.encodeWithSelector(KuberRegistry.MembershipCapReached.selector, ms[0])
        );
        assertEq(registry.activeMemberships(ms[0]), 5);
    }

    function test_T_FAC_1_creatorAtMembershipCap() public {
        _sixthCreateReverts();
    }

    function test_T_REG_2_createAtCapReverts() public {
        _sixthCreateReverts();
    }

    function test_T_FAC_1_fixedParamBounds() public {
        address[] memory ms = _newMembers(5);
        FixedParams memory f;

        f = _fixed();
        f.contribution = 0;
        _expectFixed(ms, f, IKuberCircleErrors.InvalidContribution.selector);
        f = _fixed();
        f.epochDuration = 29;
        _expectFixed(ms, f, IKuberCircleErrors.InvalidEpochDuration.selector);
        f = _fixed();
        f.lockBps = 999;
        _expectFixed(ms, f, IKuberCircleErrors.InvalidLockBps.selector);
        f.lockBps = 4_001;
        _expectFixed(ms, f, IKuberCircleErrors.InvalidLockBps.selector);
        f = _fixed();
        f.startTime = uint64(block.timestamp);
        _expectFixed(ms, f, IKuberCircleErrors.InvalidStartTime.selector);
        f = _fixed();
        f.minSaveEpochs = 2;
        _expectFixed(ms, f, IKuberCircleErrors.InvalidMinSaveEpochs.selector);
        f = _fixed();
        f.totalEpochs = 5; // minSaveEpochs 3 needs at least 6
        _expectFixed(ms, f, IKuberCircleErrors.InvalidTotalEpochs.selector);
        f.totalEpochs = 61;
        _expectFixed(ms, f, IKuberCircleErrors.InvalidTotalEpochs.selector);
        // One error covers both member bounds and their order (A-5).
        f = _fixed();
        f.minMembers = 4;
        _expectFixed(ms, f, IKuberCircleErrors.InvalidMemberBounds.selector);
        f = _fixed();
        f.maxMembers = 51;
        _expectFixed(ms, f, IKuberCircleErrors.InvalidMemberBounds.selector);
        f = _fixed();
        f.minMembers = 31;
        _expectFixed(ms, f, IKuberCircleErrors.InvalidMemberBounds.selector);
        f = _fixed();
        f.maxRepayEpochs = 0;
        _expectFixed(ms, f, IKuberCircleErrors.InvalidMaxRepayEpochs.selector);
        f.maxRepayEpochs = 4;
        _expectFixed(ms, f, IKuberCircleErrors.InvalidMaxRepayEpochs.selector);
        f = _fixed();
        f.cooldownEpochs = 4;
        _expectFixed(ms, f, IKuberCircleErrors.InvalidCooldownEpochs.selector);
    }

    function test_T_FAC_1_ruleParamBounds() public {
        address[] memory ms = _newMembers(5);
        RuleParams memory r;

        r = _rules();
        r.ownLtvBps = 10_001;
        _expectRules(ms, r, IKuberCircleErrors.InvalidOwnLtv.selector);
        r = _rules();
        r.ownRateBps = 2_001;
        _expectRules(ms, r, IKuberCircleErrors.InvalidOwnRate.selector);
        r = _rules();
        r.perLoanMaxBps = 999;
        _expectRules(ms, r, IKuberCircleErrors.InvalidPerLoanMax.selector);
        r.perLoanMaxBps = 10_001;
        _expectRules(ms, r, IKuberCircleErrors.InvalidPerLoanMax.selector);
        r = _rules();
        r.fastLaneBps = 5_001;
        _expectRules(ms, r, IKuberCircleErrors.InvalidFastLane.selector);
        bytes4 badAlloc = IKuberCircleErrors.InvalidAllocation.selector;
        _expectRules(ms, _rulesWithAlloc(500, 5_000, 3_500, 999), badAlloc); // sum 9_999
        _expectRules(ms, _rulesWithAlloc(4_001, 4_499, 500, 1_000), badAlloc); // loan > 4_000
        _expectRules(ms, _rulesWithAlloc(0, 3_999, 5_001, 1_000), badAlloc); // lp > 5_000
        _expectRules(ms, _rulesWithAlloc(500, 5_001, 4_000, 499), badAlloc); // cash < 500
        r = _rules();
        r.penaltyBps = 5_001;
        _expectRules(ms, r, IKuberCircleErrors.InvalidPenalty.selector);
        r = _rules();
        r.contribFineBps = 1_001;
        _expectRules(ms, r, IKuberCircleErrors.InvalidContribFine.selector);
        r = _rules();
        r.installFineBps = 2_001;
        _expectRules(ms, r, IKuberCircleErrors.InvalidInstallFine.selector);
        r = _rules();
        r.exitFeeBps = 2_001;
        _expectRules(ms, r, IKuberCircleErrors.InvalidExitFee.selector);
        r = _rules();
        r.managerFeeBps = 1_001;
        _expectRules(ms, r, IKuberCircleErrors.InvalidManagerFee.selector);
    }

    function test_T_FAC_1_validEdgesAccepted() public {
        FixedParams memory f;
        RuleParams memory r = _rules();

        f = _fixed();
        f.lockBps = 1_000;
        _createOk(f, r);
        f.lockBps = 4_000;
        _createOk(f, r);
        f = _fixed();
        f.epochDuration = 30;
        _createOk(f, r);
        f = _fixed();
        (f.minSaveEpochs, f.totalEpochs) = (3, 6);
        _createOk(f, r);
        f = _fixed();
        f.totalEpochs = 60;
        _createOk(f, r);
        f = _fixed();
        f.maxMembers = 50;
        _createOk(f, r);
        f = _fixed();
        f.maxRepayEpochs = 1;
        _createOk(f, r);
        f.maxRepayEpochs = 3;
        _createOk(f, r);
        f = _fixed();
        f.cooldownEpochs = 3;
        _createOk(f, r);
        r.ownLtvBps = 10_000;
        _createOk(_fixed(), r);
        assertEq(factory.circleCount(), 10);
    }

    function test_T_FAC_2_cloneAuthorizedAndListed() public {
        address[] memory ms = _newMembers(5);
        FixedParams memory f = _fixed();
        RuleParams memory r = _rules();
        address[] memory inv = _tail(ms);
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        vm.expectEmit(address(factory));
        emit KuberFactory.CircleCreated(predicted, ms[0], "circle");
        vm.prank(ms[0]);
        address circle = factory.createCircle("circle", f, r, inv);

        assertEq(circle, predicted);
        assertTrue(registry.isCircle(circle));
        address[] memory all = factory.allCircles();
        assertEq(all.length, 1);
        assertEq(all[0], circle);
        assertEq(factory.circleCount(), 1);
        assertTrue(circle != factory.IMPLEMENTATION());
        assertEq(registry.activeMemberships(ms[0]), 1);

        KuberCircle c = KuberCircle(circle);
        KuberCircle.CircleState memory s = c.getCircleState();
        assertEq(uint8(s.status), uint8(CircleStatus.Forming));
        assertEq(s.creator, ms[0]);
        assertEq(s.memberCount, 1);
        assertEq(s.name, "circle");
        assertEq(abi.encode(s.fixedParams), abi.encode(f));
        assertEq(abi.encode(s.rules), abi.encode(r));
        address[] memory mem = c.members();
        assertEq(mem.length, 1);
        assertEq(mem[0], ms[0]);
        assertEq(uint8(c.getMember(ms[0]).status), uint8(MemberStatus.Active));
    }

    function test_T_FAC_2_implementationCannotBeInitialized() public {
        KuberCircle impl = KuberCircle(factory.IMPLEMENTATION());
        address[] memory ms = _newMembers(5);
        FixedParams memory f = _fixed();
        RuleParams memory r = _rules();
        address[] memory inv = _tail(ms);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(address(factory));
        impl.initialize(ms[0], "circle", f, r, inv);
    }

    function test_T_FAC_2_cloneCannotBeReinitialized() public {
        address[] memory ms = _newMembers(5);
        KuberCircle c = _create(ms);
        FixedParams memory f = _fixed();
        RuleParams memory r = _rules();
        address[] memory inv = _tail(ms);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(address(factory));
        c.initialize(ms[0], "circle", f, r, inv);
    }

    function test_T_REG_2_joinAtCapReverts() public {
        address person = _newMembers(1)[0];
        KuberCircle[] memory cs = new KuberCircle[](6);
        for (uint256 i; i < 6; ++i) {
            address[] memory ms = _newMembers(5);
            ms[1] = person;
            cs[i] = _create(ms);
        }
        for (uint256 i; i < 5; ++i) {
            vm.prank(person);
            cs[i].join();
        }
        assertEq(registry.activeMemberships(person), 5);
        vm.expectRevert(abi.encodeWithSelector(KuberRegistry.MembershipCapReached.selector, person));
        vm.prank(person);
        cs[5].join();
        assertEq(registry.activeMemberships(person), 5);
        assertEq(cs[5].members().length, 1);
    }

    function test_factory_zeroAddressConstructorReverts() public {
        IERC20 token = IERC20(address(usdc));
        address impl = factory.IMPLEMENTATION();
        bytes4 err = IKuberCircleErrors.ZeroAddress.selector;
        vm.expectRevert(err);
        new KuberFactory(KuberRegistry(address(0)), token, address(aave), address(lp), impl);
        vm.expectRevert(err);
        new KuberFactory(registry, IERC20(address(0)), address(aave), address(lp), impl);
        vm.expectRevert(err);
        new KuberFactory(registry, token, address(0), address(lp), impl);
        vm.expectRevert(err);
        new KuberFactory(registry, token, address(aave), address(0), impl);
        vm.expectRevert(err);
        new KuberFactory(registry, token, address(aave), address(lp), address(0));
    }
}
