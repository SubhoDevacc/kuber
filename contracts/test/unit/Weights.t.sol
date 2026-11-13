// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Weights} from "../../src/lib/Weights.sol";
import {CircleStorage, Member, MemberStatus} from "../../src/lib/CircleTypes.sol";

contract WeightsHarness {
    struct Totals {
        uint256 sTotal;
        uint256 sActive;
        uint256 sSaver;
        uint256 wActive;
        uint256 wSaver;
        uint256 wActiveLast;
        uint256 wSaverLast;
        uint256 reservedClaims;
    }

    CircleStorage.Layout internal $;

    function setTotalEpochs(uint8 t) external {
        $.fixedParams.totalEpochs = t;
    }

    function makeActive(address who) external {
        $.members[who].status = MemberStatus.Active;
    }

    function change(address who, int256 delta, uint256 x) external {
        Weights.changeSavings($, who, delta, x);
    }

    function removeActive(address who, uint256 e, MemberStatus s) external {
        Weights.removeFromActive($, who, e, s);
    }

    function removeSaver(address who, uint256 e) external {
        Weights.removeFromSaver($, who, e);
    }

    function credit(address who, uint256 amount) external {
        Weights.creditClaimable($, who, amount);
    }

    function take(address who) external returns (uint256) {
        return Weights.takeClaimable($, who);
    }

    function weightAt(address who, uint256 e) external view returns (uint256) {
        return Weights.weightOf($, who, e);
    }

    function wActiveAt(uint256 e) external view returns (uint256) {
        return Weights.accrued($.wActive, $.sActive, $.wActiveLast, e);
    }

    function wSaverAt(uint256 e) external view returns (uint256) {
        return Weights.accrued($.wSaver, $.sSaver, $.wSaverLast, e);
    }

    function member(address who) external view returns (Member memory) {
        return $.members[who];
    }

    function totals() external view returns (Totals memory t) {
        t = Totals($.sTotal, $.sActive, $.sSaver, $.wActive, $.wSaver, $.wActiveLast, $.wSaverLast, $.reservedClaims);
    }
}

contract WeightsTest is Test {
    uint256 internal constant C = 100e6;
    WeightsHarness internal h;

    // Brute-force record of every applied change, for the fuzz test.
    mapping(address => int256[]) internal deltas;
    mapping(address => uint256[]) internal xs;

    function setUp() public {
        h = new WeightsHarness();
        h.setTotalEpochs(7);
    }

    function _members(uint256 n) internal returns (address[] memory ms) {
        ms = new address[](n);
        for (uint256 i; i < n; ++i) {
            ms[i] = makeAddr(string.concat("m", vm.toString(i)));
            h.makeActive(ms[i]);
        }
    }

    function _plus(address who, uint256 x) internal {
        h.change(who, int256(C), x);
    }

    // Σ member weights == accumulator (Active, and Active + never borrowed), and the savings totals match.
    function _assertSums(address[] memory ms, uint256 e) internal view {
        uint256 wA;
        uint256 wS;
        uint256 sA;
        uint256 sS;
        uint256 sAll;
        for (uint256 i; i < ms.length; ++i) {
            Member memory m = h.member(ms[i]);
            sAll += m.savings;
            if (m.status != MemberStatus.Active) continue;
            wA += h.weightAt(ms[i], e);
            sA += m.savings;
            if (m.everBorrowed) continue;
            wS += h.weightAt(ms[i], e);
            sS += m.savings;
        }
        WeightsHarness.Totals memory t = h.totals();
        assertEq(wA, h.wActiveAt(e), "sum w != W_active");
        assertEq(wS, h.wSaverAt(e), "sum w != W_saver");
        assertEq(sA, t.sActive, "sActive");
        assertEq(sS, t.sSaver, "sSaver");
        assertEq(sAll, t.sTotal, "sTotal");
    }

    function test_weights_V1_sixMembersSevenEpochs() public {
        address[] memory ms = _members(6);
        for (uint256 x = 1; x <= 7; ++x) {
            for (uint256 i; i < 6; ++i) {
                _plus(ms[i], x);
            }
        }
        for (uint256 i; i < 6; ++i) {
            assertEq(h.weightAt(ms[i], 7), 2_800e6);
        }
        assertEq(h.wActiveAt(7), 16_800e6);
        assertEq(h.wSaverAt(7), 16_800e6);
        WeightsHarness.Totals memory t = h.totals();
        assertEq(t.sTotal, 4_200e6);
        assertEq(t.sActive, 4_200e6);
        assertEq(t.sSaver, 4_200e6);
        _assertSums(ms, 7);
    }

    function test_weights_V2_prePayOrderIndependent() public {
        address[] memory ms = _members(2);
        (address x, address y) = (ms[0], ms[1]);
        _plus(x, 2);
        _plus(x, 1);
        _plus(y, 1);
        _plus(y, 2);
        for (uint256 i; i < 2; ++i) {
            Member memory m = h.member(ms[i]);
            assertEq(m.weight, 100e6);
            assertEq(m.lastAccrual, 1);
            assertEq(m.savings, 200e6);
            assertEq(h.weightAt(ms[i], 7), 1_300e6);
        }
        WeightsHarness.Totals memory t = h.totals();
        assertEq(t.wActive, 200e6);
        assertEq(t.wActiveLast, 1);
        assertEq(t.sActive, 400e6);
        assertEq(h.wActiveAt(7), 2_600e6);
        _assertSums(ms, 7);
    }

    function test_weights_V3_signedBackfill() public {
        address[] memory ms = _members(1);
        address z = ms[0];
        _plus(z, 1);
        _plus(z, 2);
        _plus(z, 4);
        h.change(z, -50e6, 2);
        Member memory m = h.member(z);
        assertEq(m.weight, 400e6);
        assertEq(m.lastAccrual, 3);
        assertEq(m.savings, 250e6);
        assertEq(h.weightAt(z, 7), 1_400e6);
        _assertSums(ms, 7);
    }

    function test_weights_V4_clampAfterCycle() public {
        address[] memory ms = _members(1);
        address q = ms[0];
        _plus(q, 1);
        _plus(q, 10);
        Member memory m = h.member(q);
        assertEq(m.weight, 700e6);
        assertEq(m.lastAccrual, 7);
        assertEq(m.savings, 200e6);
        assertEq(h.weightAt(q, 7), 700e6);
        assertEq(h.wActiveAt(7), 700e6);
        assertEq(h.totals().wActiveLast, 7);
        _assertSums(ms, 7);
    }

    function test_D23e_removeFromActiveKeepsSum() public {
        address[] memory ms = _members(3);
        (address a, address b, address c) = (ms[0], ms[1], ms[2]);
        for (uint256 x = 1; x <= 3; ++x) {
            for (uint256 i; i < 3; ++i) {
                _plus(ms[i], x);
            }
        }
        h.removeActive(b, 3, MemberStatus.Suspended);
        for (uint256 x = 4; x <= 7; ++x) {
            _plus(a, x);
            _plus(c, x);
        }
        Member memory mb = h.member(b);
        assertEq(uint8(mb.status), uint8(MemberStatus.Suspended));
        assertEq(mb.weight, 600e6);
        assertEq(mb.lastAccrual, 3);
        assertEq(h.weightAt(a, 7), 2_800e6);
        assertEq(h.weightAt(c, 7), 2_800e6);
        assertEq(h.wActiveAt(7), 5_600e6);
        assertEq(h.wSaverAt(7), 5_600e6);
        WeightsHarness.Totals memory t = h.totals();
        assertEq(t.sActive, 1_400e6);
        assertEq(t.sTotal, 1_700e6); // B's 300e6 stays in sTotal (R-N)
        _assertSums(ms, 7);

        // A change to a non-Active member moves sTotal and its own fields only.
        _plus(b, 5);
        assertEq(h.totals().sTotal, 1_800e6);
        assertEq(h.wActiveAt(7), 5_600e6);
        assertEq(h.wSaverAt(7), 5_600e6);
        assertEq(h.member(b).savings, 400e6);
        _assertSums(ms, 7);
    }

    function test_D23e_removeFromSaverKeepsSum() public {
        address[] memory ms = _members(2);
        (address a, address b) = (ms[0], ms[1]);
        for (uint256 x = 1; x <= 4; ++x) {
            _plus(a, x);
            _plus(b, x);
        }
        h.removeSaver(a, 4);
        for (uint256 x = 5; x <= 7; ++x) {
            _plus(a, x);
            _plus(b, x);
        }
        assertTrue(h.member(a).everBorrowed);
        assertEq(h.weightAt(a, 7), 2_800e6);
        assertEq(h.weightAt(b, 7), 2_800e6);
        assertEq(h.wActiveAt(7), 5_600e6);
        assertEq(h.wSaverAt(7), 2_800e6);
        WeightsHarness.Totals memory t = h.totals();
        assertEq(t.sSaver, 700e6);
        assertEq(t.sActive, 1_400e6);
        _assertSums(ms, 7);

        // Removing a borrower from W_active does not subtract it from W_saver a second time.
        h.removeActive(a, 7, MemberStatus.Suspended);
        assertEq(h.wActiveAt(7), 2_800e6);
        assertEq(h.wSaverAt(7), 2_800e6);
        _assertSums(ms, 7);
    }

    // A-3: a second removal is a no-op, and an epoch past totalEpochs is capped (no uint8 wrap).
    function test_D23e_removalsIdempotentAndCapped() public {
        address[] memory ms = _members(4);
        for (uint256 x = 1; x <= 3; ++x) {
            for (uint256 i; i < 4; ++i) {
                _plus(ms[i], x);
            }
        }

        h.removeSaver(ms[0], 3);
        WeightsHarness.Totals memory t1 = h.totals();
        Member memory m1 = h.member(ms[0]);
        h.removeSaver(ms[0], 5);
        assertEq(abi.encode(h.totals()), abi.encode(t1), "second removeSaver changed totals");
        assertEq(abi.encode(h.member(ms[0])), abi.encode(m1), "second removeSaver changed member");
        _assertSums(ms, 7);

        h.removeActive(ms[1], 3, MemberStatus.Suspended);
        t1 = h.totals();
        m1 = h.member(ms[1]);
        h.removeActive(ms[1], 6, MemberStatus.Kicked);
        assertEq(abi.encode(h.totals()), abi.encode(t1), "second removeActive changed totals");
        assertEq(abi.encode(h.member(ms[1])), abi.encode(m1), "second removeActive changed member");
        assertEq(uint8(h.member(ms[1]).status), uint8(MemberStatus.Suspended));
        _assertSums(ms, 7);

        // A non-Active member is not in W_saver: removeSaver only marks it borrowed.
        t1 = h.totals();
        h.removeSaver(ms[1], 4);
        assertTrue(h.member(ms[1]).everBorrowed);
        assertEq(abi.encode(h.totals()), abi.encode(t1), "removeSaver on non-Active changed totals");

        // 256 would wrap to 0 and 1000 to 232 under a plain uint8 cast; both cap at totalEpochs = 7.
        h.removeSaver(ms[2], 256);
        assertEq(h.member(ms[2]).lastAccrual, 7);
        assertEq(h.totals().wSaverLast, 7);
        h.removeActive(ms[3], 1000, MemberStatus.Suspended);
        assertEq(h.member(ms[3]).lastAccrual, 7);
        assertEq(h.totals().wActiveLast, 7);
        _assertSums(ms, 7);
    }

    function test_weights_V7_claimableLedger() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        h.credit(a, 5e6);
        h.credit(b, 3e6);
        assertEq(h.totals().reservedClaims, 8e6);
        assertEq(h.take(a), 5e6);
        assertEq(h.totals().reservedClaims, 3e6);
        assertEq(h.member(a).claimable, 0);
        assertEq(h.member(b).claimable, 3e6);
        assertEq(h.take(a), 0);
        assertEq(h.totals().reservedClaims, 3e6);
    }

    // Random changes (both signs, any order, any epoch incl. past the cycle) and removals: every member's
    // weight equals the brute-force Σ delta × (T − x + 1), and the accumulators equal the member sums.
    function testFuzz_weights_randomOpsMatchBruteForce(uint256 seed, uint8 tRaw) public {
        uint256 t = 6 + uint256(tRaw) % 55; // 6..60
        h.setTotalEpochs(uint8(t));
        address[] memory ms = _members(6);
        for (uint256 step; step < 120; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address m = ms[(r >> 8) % 6];
            uint256 op = r % 10;
            if (op <= 5) {
                _tryChange(m, int256(1 + (r >> 32) % 300e6), 1 + (r >> 16) % (t + 3), t);
            } else if (op <= 7) {
                Member memory mm = h.member(m);
                if (mm.savings == 0) continue;
                uint256 d = 1 + (r >> 32) % mm.savings;
                // Half the time hit the retroactive branch (x - 1 < last).
                uint256 x = (r >> 64) % 2 == 0 && mm.lastAccrual > 0 ? mm.lastAccrual : 1 + (r >> 16) % (t + 1);
                _tryChange(m, -int256(d), x, t);
            } else if (op == 8) {
                h.removeActive(m, 1 + (r >> 16) % (t + 3), MemberStatus.Suspended);
            } else {
                h.removeSaver(m, 1 + (r >> 16) % (t + 3));
            }
            _checkBrute(ms, t);
        }
    }

    function _tryChange(address m, int256 d, uint256 x, uint256 t) internal {
        try h.change(m, d, x) {
            deltas[m].push(d);
            xs[m].push(x > t + 1 ? t + 1 : x);
        } catch {
            // Only a negative delta may revert (savings or weight would go below zero).
            assertLt(d, 0, "positive change reverted");
        }
    }

    function _checkBrute(address[] memory ms, uint256 t) internal view {
        for (uint256 i; i < ms.length; ++i) {
            int256 expected;
            for (uint256 j; j < deltas[ms[i]].length; ++j) {
                expected += deltas[ms[i]][j] * int256(t + 1 - xs[ms[i]][j]);
            }
            assertEq(int256(h.weightAt(ms[i], t)), expected, "member weight != brute force");
        }
        _assertSums(ms, t);
    }
}
