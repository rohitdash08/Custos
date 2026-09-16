// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CustosPolicyModule
/// @notice Account-scoped spending policy hook for ERC-4337-compatible smart accounts.
/// @dev A smart account should call `validatePayment` from its user-operation
///      validation flow before executing a payment. The module intentionally
///      keeps the account adapter small so it can be used by a Light Account,
///      Safe module adapter, or another standard smart-account implementation.
///      This MVP uses a trusted signed score oracle; production use requires an
///      audit, replay/domain-separation review, and a stronger oracle design.
contract CustosPolicyModule {
    uint256 public constant DAY = 1 days;
    uint256 public constant SIG_VALIDATION_FAILED = 1;

    enum RejectionReason {
        None,
        PolicyNotInitialized,
        PayeeNotAllowed,
        PerTransactionLimit,
        DailyLimit,
        ScoreRequired,
        InvalidScoreAttestation,
        UnauthorizedCaller
    }

    struct Policy {
        address owner;
        uint256 maxPerTx;
        uint256 maxPerDay;
        uint256 spentToday;
        uint256 dayStart;
        uint256 scoreThresholdAmount;
        uint256 minCustosScore;
        bool initialized;
    }

    /// @notice Signed score supplied by the off-chain EAS/indexer oracle.
    /// @dev The signature covers this module address, seller, score, deadline,
    ///      and nonce to prevent cross-module and cross-request replay.
    struct ScoreAttestation {
        address seller;
        uint256 score;
        uint256 deadline;
        uint256 nonce;
        bytes signature;
    }

    address public immutable scoreOracle;
    address public immutable entryPoint;

    mapping(address account => Policy policy) public policies;
    mapping(address account => mapping(address payee => bool approved)) public approvedPayees;
    mapping(address account => mapping(uint256 nonce => bool used)) public usedScoreAttestations;

    error ZeroAddress();
    error InvalidPolicy();
    error PolicyAlreadyInitialized();
    error Unauthorized();

    event PolicyInitialized(address indexed account, address indexed owner);
    event SpendingLimitsUpdated(address indexed account, uint256 maxPerTx, uint256 maxPerDay);
    event ScorePolicyUpdated(address indexed account, uint256 scoreThresholdAmount, uint256 minCustosScore);
    event PayeeApprovalUpdated(address indexed account, address indexed payee, bool approved);
    event PaymentApproved(address indexed account, address indexed payee, uint256 amount, uint256 spentToday);
    event PaymentRejected(
        address indexed account,
        address indexed payee,
        uint256 amount,
        RejectionReason reason
    );

    constructor(address scoreOracle_, address entryPoint_) {
        if (scoreOracle_ == address(0)) revert ZeroAddress();
        scoreOracle = scoreOracle_;
        entryPoint = entryPoint_;
    }

    /// @notice Initializes an account's policy.
    /// @dev The account itself must make this call, which is compatible with a
    ///      smart account executing module configuration through its own wallet.
    function initializePolicy(
        address owner_,
        uint256 maxPerTx_,
        uint256 maxPerDay_,
        uint256 scoreThresholdAmount_,
        uint256 minCustosScore_
    ) external {
        if (msg.sender == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (policies[msg.sender].initialized) revert PolicyAlreadyInitialized();
        _validateLimits(maxPerTx_, maxPerDay_);

        policies[msg.sender] = Policy({
            owner: owner_,
            maxPerTx: maxPerTx_,
            maxPerDay: maxPerDay_,
            spentToday: 0,
            dayStart: _currentDay(),
            scoreThresholdAmount: scoreThresholdAmount_,
            minCustosScore: minCustosScore_,
            initialized: true
        });

        emit PolicyInitialized(msg.sender, owner_);
        emit SpendingLimitsUpdated(msg.sender, maxPerTx_, maxPerDay_);
        emit ScorePolicyUpdated(msg.sender, scoreThresholdAmount_, minCustosScore_);
    }

    /// @notice Updates an account's per-transaction and per-day limits.
    function setSpendingLimits(address account, uint256 maxPerTx_, uint256 maxPerDay_) external {
        _onlyPolicyAdmin(account);
        _validateLimits(maxPerTx_, maxPerDay_);
        Policy storage policy = policies[account];
        policy.maxPerTx = maxPerTx_;
        policy.maxPerDay = maxPerDay_;
        emit SpendingLimitsUpdated(account, maxPerTx_, maxPerDay_);
    }

    /// @notice Sets the amount above which a signed Custos Score is required.
    function setScorePolicy(address account, uint256 scoreThresholdAmount_, uint256 minCustosScore_) external {
        _onlyPolicyAdmin(account);
        Policy storage policy = policies[account];
        policy.scoreThresholdAmount = scoreThresholdAmount_;
        policy.minCustosScore = minCustosScore_;
        emit ScorePolicyUpdated(account, scoreThresholdAmount_, minCustosScore_);
    }

    /// @notice Adds or removes a payment recipient from an account's allowlist.
    function setPayeeApproval(address account, address payee, bool approved) external {
        _onlyPolicyAdmin(account);
        if (payee == address(0)) revert ZeroAddress();
        approvedPayees[account][payee] = approved;
        emit PayeeApprovalUpdated(account, payee, approved);
    }

    /// @notice Preflights a payment without consuming quota or a score nonce.
    /// @return approved Whether the payment can be approved.
    /// @return reason The first policy rule that rejects it, if any.
    /// @return dailyRemaining Remaining daily budget at the time of the call.
    function checkPayment(
        address account,
        address payee,
        uint256 amount,
        ScoreAttestation calldata attestation
    ) external view returns (bool approved, RejectionReason reason, uint256 dailyRemaining) {
        return _checkPayment(account, payee, amount, attestation);
    }

    /// @notice Consumes quota and records an approved payment attempt.
    /// @dev The account or configured EntryPoint must call this hook. Rejected
    ///      attempts return false instead of reverting so their event survives.
    function validatePayment(
        address account,
        address payee,
        uint256 amount,
        ScoreAttestation memory attestation
    ) public returns (bool approved) {
        if (msg.sender != account && msg.sender != entryPoint) {
            emit PaymentRejected(account, payee, amount, RejectionReason.UnauthorizedCaller);
            return false;
        }

        RejectionReason reason;
        (approved, reason,) = _checkPayment(account, payee, amount, attestation);
        if (!approved) {
            emit PaymentRejected(account, payee, amount, reason);
            return false;
        }

        Policy storage policy = policies[account];
        _rollDay(policy);
        policy.spentToday += amount;
        if (attestation.signature.length != 0) usedScoreAttestations[account][attestation.nonce] = true;
        emit PaymentApproved(account, payee, amount, policy.spentToday);
        return true;
    }

    /// @notice ERC-4337 adapter-shaped validation hook.
    /// @dev A smart-account adapter can map this result to validationData. A
    ///      zero result means valid; one means SIG_VALIDATION_FAILED.
    function validateUserOp(
        address account,
        address payee,
        uint256 amount,
        bytes calldata encodedAttestation
    ) external returns (uint256 validationData) {
        ScoreAttestation memory attestation = abi.decode(encodedAttestation, (ScoreAttestation));
        return validatePayment(account, payee, amount, attestation) ? 0 : SIG_VALIDATION_FAILED;
    }

    function _checkPayment(
        address account,
        address payee,
        uint256 amount,
        ScoreAttestation memory attestation
    ) internal view returns (bool approved, RejectionReason reason, uint256 dailyRemaining) {
        Policy storage policy = policies[account];
        if (!policy.initialized) return (false, RejectionReason.PolicyNotInitialized, 0);
        if (!approvedPayees[account][payee]) return (false, RejectionReason.PayeeNotAllowed, _dailyRemaining(policy));
        if (amount == 0 || amount > policy.maxPerTx) {
            return (false, RejectionReason.PerTransactionLimit, _dailyRemaining(policy));
        }

        dailyRemaining = _dailyRemaining(policy);
        if (amount > dailyRemaining) return (false, RejectionReason.DailyLimit, dailyRemaining);

        if (amount > policy.scoreThresholdAmount) {
            if (attestation.seller != payee || attestation.score < policy.minCustosScore) {
                return (false, RejectionReason.ScoreRequired, dailyRemaining);
            }
            if (!_validScoreAttestation(account, attestation)) {
                return (false, RejectionReason.InvalidScoreAttestation, dailyRemaining);
            }
        }
        return (true, RejectionReason.None, dailyRemaining);
    }

    function _validScoreAttestation(address account, ScoreAttestation memory attestation) internal view returns (bool) {
        if (attestation.signature.length != 65 || attestation.deadline < block.timestamp) return false;
        if (usedScoreAttestations[account][attestation.nonce]) return false;
        bytes32 structHash = keccak256(
            abi.encode(address(this), account, attestation.seller, attestation.score, attestation.deadline, attestation.nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
        (uint8 v, bytes32 r, bytes32 s) = _splitSignature(attestation.signature);
        return ecrecover(digest, v, r, s) == scoreOracle;
    }

    function _splitSignature(bytes memory signature) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        if (v < 27) v += 27;
    }

    function _onlyPolicyAdmin(address account) internal view {
        Policy storage policy = policies[account];
        if (!policy.initialized) revert InvalidPolicy();
        if (msg.sender != account && msg.sender != policy.owner) revert Unauthorized();
    }

    function _validateLimits(uint256 maxPerTx_, uint256 maxPerDay_) internal pure {
        if (maxPerTx_ == 0 || maxPerDay_ == 0 || maxPerTx_ > maxPerDay_) revert InvalidPolicy();
    }

    function _currentDay() internal view returns (uint256) {
        return block.timestamp / DAY * DAY;
    }

    function _rollDay(Policy storage policy) internal {
        uint256 currentDay = _currentDay();
        if (policy.dayStart != currentDay) {
            policy.dayStart = currentDay;
            policy.spentToday = 0;
        }
    }

    function _dailyRemaining(Policy storage policy) internal view returns (uint256) {
        if (policy.dayStart != _currentDay()) return policy.maxPerDay;
        return policy.spentToday >= policy.maxPerDay ? 0 : policy.maxPerDay - policy.spentToday;
    }
}
