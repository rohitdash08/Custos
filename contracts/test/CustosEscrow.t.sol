// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CustosEscrow, IERC20} from "../src/CustosEscrow.sol";

contract MockUSDC is IERC20 {
    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (balanceOf[from] < amount || allowance[from][msg.sender] < amount) return false;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CustosEscrowTest is Test {
    MockUSDC internal token;
    CustosEscrow internal escrow;

    address internal buyer = address(0xB0B);
    address internal seller = address(0x5E11);
    address internal arbiter = address(0xA8B1);
    uint256 internal constant AMOUNT = 25e6;
    uint256 internal constant TIMEOUT = 1 days;
    bytes32 internal constant REQUEST_ID = keccak256("request-1");

    function setUp() external {
        token = new MockUSDC();
        escrow = new CustosEscrow(IERC20(address(token)), arbiter, TIMEOUT);
        token.mint(buyer, AMOUNT * 5);
        vm.prank(buyer);
        token.approve(address(escrow), type(uint256).max);
    }

    function testDepositAndConfirmDelivery() external {
        vm.expectEmit(true, true, true, true);
        emit CustosEscrow.EscrowDeposited(REQUEST_ID, buyer, seller, AMOUNT, block.timestamp + TIMEOUT);
        vm.prank(buyer);
        escrow.deposit(buyer, seller, REQUEST_ID, AMOUNT);

        assertEq(token.balanceOf(address(escrow)), AMOUNT);
        assertEq(token.balanceOf(buyer), AMOUNT * 4);

        vm.expectEmit(true, true, true, true);
        emit CustosEscrow.DeliveryConfirmed(REQUEST_ID, buyer, seller, AMOUNT);
        vm.prank(buyer);
        escrow.confirmDelivery(REQUEST_ID);

        (, , uint256 amount, , CustosEscrow.Status status) = escrow.escrows(REQUEST_ID);
        assertEq(amount, AMOUNT);
        assertEq(uint256(status), uint256(CustosEscrow.Status.Released));
        assertEq(token.balanceOf(seller), AMOUNT);
    }

    function testOnlyBuyerCanConfirm() external {
        _deposit();

        vm.prank(seller);
        vm.expectRevert(CustosEscrow.Unauthorized.selector);
        escrow.confirmDelivery(REQUEST_ID);
    }

    function testRefundAfterTimeout() external {
        _deposit();
        vm.warp(block.timestamp + TIMEOUT);

        vm.expectEmit(true, true, false, true);
        emit CustosEscrow.EscrowRefunded(REQUEST_ID, buyer, AMOUNT);
        escrow.refund(REQUEST_ID);

        (, , , , CustosEscrow.Status status) = escrow.escrows(REQUEST_ID);
        assertEq(uint256(status), uint256(CustosEscrow.Status.Refunded));
        assertEq(token.balanceOf(buyer), AMOUNT * 5);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function testFacilitatorCanDepositOnBehalfOfBuyer() external {
        address facilitator = address(0xFAC1);

        vm.prank(facilitator);
        escrow.deposit(buyer, seller, REQUEST_ID, AMOUNT);

        (address recordedBuyer, address recordedSeller, uint256 amount,, CustosEscrow.Status status) =
            escrow.escrows(REQUEST_ID);
        assertEq(recordedBuyer, buyer);
        assertEq(recordedSeller, seller);
        assertEq(amount, AMOUNT);
        assertEq(uint256(status), uint256(CustosEscrow.Status.Funded));
    }

    function testRefundBeforeTimeoutReverts() external {
        _deposit();

        vm.expectRevert(CustosEscrow.RefundNotAvailable.selector);
        escrow.refund(REQUEST_ID);
    }

    function testDisputeCanBeResolvedForSeller() external {
        _deposit();

        vm.expectEmit(true, true, false, true);
        emit CustosEscrow.DisputeOpened(REQUEST_ID, seller);
        vm.prank(seller);
        escrow.dispute(REQUEST_ID);

        vm.expectEmit(true, true, false, true);
        emit CustosEscrow.DisputeResolved(REQUEST_ID, true, arbiter, AMOUNT);
        vm.prank(arbiter);
        escrow.resolveDispute(REQUEST_ID, true);

        (, , , , CustosEscrow.Status status) = escrow.escrows(REQUEST_ID);
        assertEq(uint256(status), uint256(CustosEscrow.Status.Released));
        assertEq(token.balanceOf(seller), AMOUNT);
    }

    function testDisputeCanBeResolvedForBuyer() external {
        _deposit();

        vm.prank(buyer);
        escrow.dispute(REQUEST_ID);

        vm.prank(arbiter);
        escrow.resolveDispute(REQUEST_ID, false);

        (, , , , CustosEscrow.Status status) = escrow.escrows(REQUEST_ID);
        assertEq(uint256(status), uint256(CustosEscrow.Status.Refunded));
        assertEq(token.balanceOf(buyer), AMOUNT * 5);
    }

    function testDisputeFreezesConfirmAndRefund() external {
        _deposit();
        vm.prank(buyer);
        escrow.dispute(REQUEST_ID);

        vm.prank(buyer);
        vm.expectRevert(CustosEscrow.InvalidStatus.selector);
        escrow.confirmDelivery(REQUEST_ID);

        vm.warp(block.timestamp + TIMEOUT);
        vm.expectRevert(CustosEscrow.InvalidStatus.selector);
        escrow.refund(REQUEST_ID);
    }

    function testCannotDepositSameRequestTwice() external {
        _deposit();

        vm.prank(buyer);
        vm.expectRevert(CustosEscrow.RequestAlreadyExists.selector);
        escrow.deposit(buyer, seller, REQUEST_ID, AMOUNT);
    }

    function testOnlyArbiterCanResolveDispute() external {
        _deposit();
        vm.prank(buyer);
        escrow.dispute(REQUEST_ID);

        vm.expectRevert(CustosEscrow.Unauthorized.selector);
        escrow.resolveDispute(REQUEST_ID, true);
    }

    function testUnknownRequestReverts() external {
        bytes32 unknownRequestId = keccak256("unknown");

        vm.expectRevert(CustosEscrow.RequestNotFound.selector);
        escrow.confirmDelivery(unknownRequestId);

        vm.expectRevert(CustosEscrow.RequestNotFound.selector);
        escrow.refund(unknownRequestId);

        vm.expectRevert(CustosEscrow.RequestNotFound.selector);
        escrow.dispute(unknownRequestId);

        vm.prank(arbiter);
        vm.expectRevert(CustosEscrow.RequestNotFound.selector);
        escrow.resolveDispute(unknownRequestId, true);
    }

    function testTerminalStatesCannotBeChanged() external {
        _deposit();

        vm.prank(buyer);
        escrow.confirmDelivery(REQUEST_ID);

        vm.expectRevert(CustosEscrow.InvalidStatus.selector);
        escrow.refund(REQUEST_ID);

        vm.expectRevert(CustosEscrow.InvalidStatus.selector);
        escrow.dispute(REQUEST_ID);

        vm.prank(arbiter);
        vm.expectRevert(CustosEscrow.InvalidStatus.selector);
        escrow.resolveDispute(REQUEST_ID, false);
    }

    function testInvalidConstructorArgumentsRevert() external {
        vm.expectRevert(CustosEscrow.ZeroAddress.selector);
        new CustosEscrow(IERC20(address(0)), arbiter, TIMEOUT);

        vm.expectRevert(CustosEscrow.ZeroAddress.selector);
        new CustosEscrow(IERC20(address(token)), address(0), TIMEOUT);

        vm.expectRevert(CustosEscrow.ZeroAmount.selector);
        new CustosEscrow(IERC20(address(token)), arbiter, 0);
    }

    function testInvalidDepositArgumentsRevert() external {
        vm.startPrank(buyer);

        vm.expectRevert(CustosEscrow.ZeroAddress.selector);
        escrow.deposit(address(0), seller, REQUEST_ID, AMOUNT);

        vm.expectRevert(CustosEscrow.ZeroAddress.selector);
        escrow.deposit(buyer, address(0), REQUEST_ID, AMOUNT);

        vm.expectRevert(CustosEscrow.ZeroAmount.selector);
        escrow.deposit(buyer, seller, REQUEST_ID, 0);

        vm.stopPrank();
    }

    function _deposit() internal {
        vm.prank(buyer);
        escrow.deposit(buyer, seller, REQUEST_ID, AMOUNT);
    }
}
