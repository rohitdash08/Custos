// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-20 interface required by CustosEscrow.
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @title CustosEscrow
/// @notice Holds an x402 payment until delivery is confirmed, refunded, or
///         resolved by a designated arbiter.
/// @dev This is intentionally a minimal optimistic escrow for the Custos MVP.
///      A production deployment should receive an independent audit and may
///      need a richer dispute-resolution system.
contract CustosEscrow {
    enum Status {
        None,
        Funded,
        Released,
        Refunded,
        Disputed
    }

    struct Escrow {
        address buyer;
        address seller;
        uint256 amount;
        uint256 refundAfter;
        Status status;
    }

    IERC20 public immutable paymentToken;
    address public immutable arbiter;
    uint256 public immutable refundTimeout;

    mapping(bytes32 requestId => Escrow escrow) public escrows;
    uint256 private _entered;

    error ZeroAddress();
    error ZeroAmount();
    error RequestAlreadyExists();
    error RequestNotFound();
    error Unauthorized();
    error InvalidStatus();
    error RefundNotAvailable();
    error TransferFailed();
    error Reentrancy();

    event EscrowDeposited(
        bytes32 indexed requestId,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 refundAfter
    );
    event DeliveryConfirmed(bytes32 indexed requestId, address indexed buyer, address indexed seller, uint256 amount);
    event EscrowRefunded(bytes32 indexed requestId, address indexed buyer, uint256 amount);
    event DisputeOpened(bytes32 indexed requestId, address indexed openedBy);
    event DisputeResolved(bytes32 indexed requestId, bool releasedToSeller, address indexed arbiter, uint256 amount);

    modifier nonReentrant() {
        if (_entered == 1) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(IERC20 paymentToken_, address arbiter_, uint256 refundTimeout_) {
        if (address(paymentToken_) == address(0) || arbiter_ == address(0)) revert ZeroAddress();
        if (refundTimeout_ == 0) revert ZeroAmount();
        paymentToken = paymentToken_;
        arbiter = arbiter_;
        refundTimeout = refundTimeout_;
    }

    /// @notice Deposits payment for a unique x402 request on behalf of the buyer.
    /// @dev The buyer must approve this contract for `amount` before calling.
    ///      This lets an x402 facilitator submit the settlement transaction while
    ///      the escrow still records and refunds the actual buyer.
    function deposit(address buyer, address seller, bytes32 requestId, uint256 amount) external nonReentrant {
        if (buyer == address(0)) revert ZeroAddress();
        if (seller == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (escrows[requestId].status != Status.None) revert RequestAlreadyExists();

        uint256 refundAfter = block.timestamp + refundTimeout;
        escrows[requestId] = Escrow({
            buyer: buyer,
            seller: seller,
            amount: amount,
            refundAfter: refundAfter,
            status: Status.Funded
        });

        if (!paymentToken.transferFrom(buyer, address(this), amount)) revert TransferFailed();
        emit EscrowDeposited(requestId, buyer, seller, amount, refundAfter);
    }

    /// @notice Releases a funded payment to the seller after buyer confirmation.
    function confirmDelivery(bytes32 requestId) external nonReentrant {
        Escrow storage escrow = _fundedEscrow(requestId);
        if (msg.sender != escrow.buyer) revert Unauthorized();

        escrow.status = Status.Released;
        _safeTransfer(escrow.seller, escrow.amount);
        emit DeliveryConfirmed(requestId, escrow.buyer, escrow.seller, escrow.amount);
    }

    /// @notice Refunds an unconfirmed payment after its timeout.
    /// @dev Anyone may submit the timeout refund so a keeper can automate it.
    function refund(bytes32 requestId) external nonReentrant {
        Escrow storage escrow = _fundedEscrow(requestId);
        if (block.timestamp < escrow.refundAfter) revert RefundNotAvailable();

        escrow.status = Status.Refunded;
        _safeTransfer(escrow.buyer, escrow.amount);
        emit EscrowRefunded(requestId, escrow.buyer, escrow.amount);
    }

    /// @notice Freezes a funded payment pending the designated arbiter's decision.
    function dispute(bytes32 requestId) external {
        Escrow storage escrow = escrows[requestId];
        if (escrow.status == Status.None) revert RequestNotFound();
        if (escrow.status != Status.Funded) revert InvalidStatus();
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert Unauthorized();

        escrow.status = Status.Disputed;
        emit DisputeOpened(requestId, msg.sender);
    }

    /// @notice Resolves a dispute in favor of either the seller or buyer.
    /// @dev The designated arbiter is a trusted v1 fallback, not a decentralized court.
    function resolveDispute(bytes32 requestId, bool releaseToSeller) external nonReentrant {
        if (msg.sender != arbiter) revert Unauthorized();
        Escrow storage escrow = escrows[requestId];
        if (escrow.status == Status.None) revert RequestNotFound();
        if (escrow.status != Status.Disputed) revert InvalidStatus();

        escrow.status = releaseToSeller ? Status.Released : Status.Refunded;
        _safeTransfer(releaseToSeller ? escrow.seller : escrow.buyer, escrow.amount);
        emit DisputeResolved(requestId, releaseToSeller, msg.sender, escrow.amount);
    }

    function _fundedEscrow(bytes32 requestId) internal view returns (Escrow storage escrow) {
        escrow = escrows[requestId];
        if (escrow.status == Status.None) revert RequestNotFound();
        if (escrow.status != Status.Funded) revert InvalidStatus();
    }

    function _safeTransfer(address to, uint256 amount) internal {
        if (!paymentToken.transfer(to, amount)) revert TransferFailed();
    }
}
