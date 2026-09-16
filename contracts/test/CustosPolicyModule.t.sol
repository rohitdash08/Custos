// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CustosPolicyModule} from "../src/CustosPolicyModule.sol";

contract CustosPolicyModuleTest is Test {
    CustosPolicyModule internal module;

    uint256 internal constant ORACLE_KEY = 0xA11CE;
    address internal oracle;
    address internal account = address(0xCAFE);
    address internal owner = address(0xB0B);
    address internal goodSeller = address(0x5E11);
    address internal otherSeller = address(0xBAD);
    uint256 internal constant MAX_PER_TX = 100e6;
    uint256 internal constant MAX_PER_DAY = 250e6;

    function setUp() external {
        oracle = vm.addr(ORACLE_KEY);
        module = new CustosPolicyModule(oracle, address(0xE11));

        vm.prank(account);
        module.initializePolicy(owner, MAX_PER_TX, MAX_PER_DAY, 50e6, 700);

        vm.prank(owner);
        module.setPayeeApproval(account, goodSeller, true);
    }

    function testApprovedPaymentConsumesDailyQuota() external {
        CustosPolicyModule.ScoreAttestation memory empty;
        (bool approved, CustosPolicyModule.RejectionReason reason, uint256 remaining) =
            module.checkPayment(account, goodSeller, 20e6, empty);
        assertTrue(approved);
        assertEq(uint256(reason), uint256(CustosPolicyModule.RejectionReason.None));
        assertEq(remaining, MAX_PER_DAY);

        vm.prank(account);
        assertTrue(module.validatePayment(account, goodSeller, 20e6, empty));
        (,,, uint256 spentToday,,,,) = module.policies(account);
        assertEq(spentToday, 20e6);
    }

    function testRejectsNonAllowlistedPayee() external {
        CustosPolicyModule.ScoreAttestation memory empty;
        (bool approved, CustosPolicyModule.RejectionReason reason,) =
            module.checkPayment(account, otherSeller, 20e6, empty);
        assertFalse(approved);
        assertEq(uint256(reason), uint256(CustosPolicyModule.RejectionReason.PayeeNotAllowed));
    }

    function testRejectsPerTransactionLimit() external {
        CustosPolicyModule.ScoreAttestation memory empty;
        vm.prank(account);
        assertFalse(module.validatePayment(account, goodSeller, MAX_PER_TX + 1, empty));
    }

    function testRejectsDailyLimit() external {
        CustosPolicyModule.ScoreAttestation memory empty;
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(account);
            assertTrue(module.validatePayment(account, goodSeller, 50e6, empty));
        }
        vm.prank(account);
        assertFalse(module.validatePayment(account, goodSeller, 1, empty));
    }

    function testRequiresAndVerifiesScoreForLargePayment() external {
        uint256 deadline = block.timestamp + 1 hours;
        CustosPolicyModule.ScoreAttestation memory invalid = CustosPolicyModule.ScoreAttestation({
            seller: goodSeller, score: 800, deadline: deadline, nonce: 1, signature: "bad"
        });

        vm.prank(account);
        assertFalse(module.validatePayment(account, goodSeller, 60e6, invalid));

        bytes memory signature = _sign(goodSeller, 800, deadline, 1);
        CustosPolicyModule.ScoreAttestation memory valid = CustosPolicyModule.ScoreAttestation({
            seller: goodSeller, score: 800, deadline: deadline, nonce: 1, signature: signature
        });
        vm.prank(account);
        assertTrue(module.validatePayment(account, goodSeller, 60e6, valid));
    }

    function testRejectsReplayedScoreAttestation() external {
        uint256 deadline = block.timestamp + 1 hours;
        CustosPolicyModule.ScoreAttestation memory attestation = CustosPolicyModule.ScoreAttestation({
            seller: goodSeller, score: 800, deadline: deadline, nonce: 9, signature: _sign(goodSeller, 800, deadline, 9)
        });

        vm.prank(account);
        assertTrue(module.validatePayment(account, goodSeller, 60e6, attestation));
        vm.prank(account);
        assertFalse(module.validatePayment(account, goodSeller, 60e6, attestation));
    }

    function testOwnerCanChangePolicyButCannotSpendForAccount() external {
        vm.prank(owner);
        module.setSpendingLimits(account, 10e6, 20e6);

        CustosPolicyModule.ScoreAttestation memory empty;
        vm.prank(owner);
        assertFalse(module.validatePayment(account, goodSeller, 1e6, empty));
    }

    function testDailyQuotaResetsOnNextDay() external {
        CustosPolicyModule.ScoreAttestation memory empty;
        vm.prank(account);
        assertTrue(module.validatePayment(account, goodSeller, 50e6, empty));

        vm.warp(block.timestamp + 1 days);
        vm.prank(account);
        assertTrue(module.validatePayment(account, goodSeller, 1e6, empty));
    }

    function testEntryPointCanValidatePayment() external {
        CustosPolicyModule.ScoreAttestation memory empty;

        vm.prank(address(0xE11));
        assertEq(module.validateUserOp(account, goodSeller, 1e6, abi.encode(empty)), 0);
    }

    function testValidateUserOpReturnsFailureForRejectedPayment() external {
        CustosPolicyModule.ScoreAttestation memory empty;

        vm.prank(address(0xE11));
        assertEq(module.validateUserOp(account, otherSeller, 1e6, abi.encode(empty)), 1);
    }

    function testUnauthorizedCallerIsRejectedWithoutConsumingQuota() external {
        CustosPolicyModule.ScoreAttestation memory empty;

        vm.expectEmit(true, true, false, true);
        emit CustosPolicyModule.PaymentRejected(
            account, goodSeller, 1e6, CustosPolicyModule.RejectionReason.UnauthorizedCaller
        );
        assertFalse(module.validatePayment(account, goodSeller, 1e6, empty));

        (,,, uint256 spentToday,,,,) = module.policies(account);
        assertEq(spentToday, 0);
    }

    function testOwnerCanUpdateLimitsScorePolicyAndAllowlist() external {
        vm.expectEmit(true, false, false, true);
        emit CustosPolicyModule.SpendingLimitsUpdated(account, 20e6, 40e6);
        vm.prank(owner);
        module.setSpendingLimits(account, 20e6, 40e6);

        vm.expectEmit(true, false, false, true);
        emit CustosPolicyModule.ScorePolicyUpdated(account, 10e6, 900);
        vm.prank(owner);
        module.setScorePolicy(account, 10e6, 900);

        vm.expectEmit(true, true, false, true);
        emit CustosPolicyModule.PayeeApprovalUpdated(account, goodSeller, false);
        vm.prank(owner);
        module.setPayeeApproval(account, goodSeller, false);

        (,,,,, uint256 threshold, uint256 score, bool initialized) = module.policies(account);
        assertEq(threshold, 10e6);
        assertEq(score, 900);
        assertTrue(initialized);
        assertFalse(module.approvedPayees(account, goodSeller));
    }

    function testOnlyAccountOrOwnerCanChangePolicy() external {
        vm.startPrank(otherSeller);

        vm.expectRevert(CustosPolicyModule.Unauthorized.selector);
        module.setSpendingLimits(account, 10e6, 20e6);

        vm.expectRevert(CustosPolicyModule.Unauthorized.selector);
        module.setScorePolicy(account, 10e6, 900);

        vm.expectRevert(CustosPolicyModule.Unauthorized.selector);
        module.setPayeeApproval(account, goodSeller, false);

        vm.stopPrank();
    }

    function testInvalidPolicyChangesRevert() external {
        vm.prank(owner);
        vm.expectRevert(CustosPolicyModule.InvalidPolicy.selector);
        module.setSpendingLimits(account, 0, MAX_PER_DAY);

        vm.prank(owner);
        vm.expectRevert(CustosPolicyModule.InvalidPolicy.selector);
        module.setSpendingLimits(account, MAX_PER_DAY + 1, MAX_PER_DAY);

        vm.prank(owner);
        vm.expectRevert(CustosPolicyModule.ZeroAddress.selector);
        module.setPayeeApproval(account, address(0), true);
    }

    function testCannotInitializePolicyTwice() external {
        vm.prank(account);
        vm.expectRevert(CustosPolicyModule.PolicyAlreadyInitialized.selector);
        module.initializePolicy(owner, MAX_PER_TX, MAX_PER_DAY, 50e6, 700);
    }

    function testUninitializedPolicyIsRejected() external {
        CustosPolicyModule.ScoreAttestation memory empty;
        address newAccount = address(0x1234);

        (bool approved, CustosPolicyModule.RejectionReason reason, uint256 remaining) =
            module.checkPayment(newAccount, goodSeller, 1e6, empty);
        assertFalse(approved);
        assertEq(uint256(reason), uint256(CustosPolicyModule.RejectionReason.PolicyNotInitialized));
        assertEq(remaining, 0);
    }

    function testConstructorRejectsZeroAddresses() external {
        vm.expectRevert(CustosPolicyModule.ZeroAddress.selector);
        new CustosPolicyModule(address(0), address(0xE11));

        vm.expectRevert(CustosPolicyModule.ZeroAddress.selector);
        new CustosPolicyModule(oracle, address(0));
    }

    function _sign(address seller, uint256 score, uint256 deadline, uint256 nonce) internal returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(address(module), account, seller, score, deadline, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORACLE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }
}
