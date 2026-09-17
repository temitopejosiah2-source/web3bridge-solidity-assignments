// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MultisigPayroll
/// @notice M-of-N owner treasury. Owners sign EIP-712 typed payment messages off-chain; any
///         relayer can submit the collected signatures to execute the payment on-chain.
/// @dev Nonce is a single, strictly-incrementing counter consumed on every execution attempt
///      (whether the target call succeeds or fails), Gnosis-Safe style. This guarantees a signed
///      payload can never be replayed, including after a failed target call.
contract MultisigPayroll is EIP712, ReentrancyGuard {
    using ECDSA for bytes32;

    bytes32 public constant PAYMENT_TYPEHASH = keccak256(
        "Payment(address to,uint256 value,bytes data,uint256 nonce,uint256 deadline,uint256 chainId,address verifyingContract)"
    );

    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public threshold;
    uint256 public nonce;

    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event ThresholdChanged(uint256 newThreshold);
    event ExecutionSuccess(uint256 indexed nonce, address indexed to, uint256 value, bytes32 payloadHash);
    event ExecutionFailed(uint256 indexed nonce, address indexed to, uint256 value, bytes32 payloadHash);
    event Received(address indexed from, uint256 amount);

    error InvalidThreshold();
    error DuplicateOwner();
    error ZeroAddressOwner();
    error NotSelf();
    error WrongChain();
    error WrongContract();
    error Expired();
    error InvalidNonce();
    error NotOwnerSigner(address recovered);
    error UnsortedOrDuplicateSignature();
    error InsufficientSignatures();
    error OwnerNotFound();
    error CannotDropBelowThreshold();

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    constructor(address[] memory _owners, uint256 _threshold, string memory eip712Name) EIP712(eip712Name, "1") {
        if (_owners.length == 0 || _threshold == 0 || _threshold > _owners.length) revert InvalidThreshold();

        for (uint256 i = 0; i < _owners.length; i++) {
            address o = _owners[i];
            if (o == address(0)) revert ZeroAddressOwner();
            if (isOwner[o]) revert DuplicateOwner();
            isOwner[o] = true;
            owners.push(o);
        }
        threshold = _threshold;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    // ---------- Signature hashing ----------

    struct Payment {
        address to;
        uint256 value;
        bytes data;
        uint256 nonce;
        uint256 deadline;
        uint256 chainId;
        address verifyingContract;
    }

    function hashPayment(Payment calldata p) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                PAYMENT_TYPEHASH, p.to, p.value, keccak256(p.data), p.nonce, p.deadline, p.chainId, p.verifyingContract
            )
        );
        return _hashTypedDataV4(structHash);
    }

    // ---------- Execution ----------

    /// @notice Any relayer may call this with a payment payload and the owners' signatures over it.
    /// @param signatures Must be sorted strictly ascending by recovered signer address, with no
    ///        duplicates -- this lets us detect repeated/duplicate signers in a single pass.
    function execute(Payment calldata p, bytes[] calldata signatures) external nonReentrant returns (bool success) {
        if (p.chainId != block.chainid) revert WrongChain();
        if (p.verifyingContract != address(this)) revert WrongContract();
        if (block.timestamp > p.deadline) revert Expired();
        if (p.nonce != nonce) revert InvalidNonce();
        if (signatures.length < threshold) revert InsufficientSignatures();

        bytes32 digest = hashPayment(p);

        address lastSigner = address(0);
        uint256 validSignatures = 0;
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (!isOwner[signer]) revert NotOwnerSigner(signer);
            if (signer <= lastSigner) revert UnsortedOrDuplicateSignature();
            lastSigner = signer;
            validSignatures++;
        }
        if (validSignatures < threshold) revert InsufficientSignatures();

        uint256 executedNonce = nonce;
        nonce++; // consumed regardless of call outcome, so a failed call can never be replayed

        bytes32 payloadHash = keccak256(p.data);
        (bool ok,) = p.to.call{value: p.value}(p.data);

        if (ok) {
            emit ExecutionSuccess(executedNonce, p.to, p.value, payloadHash);
        } else {
            emit ExecutionFailed(executedNonce, p.to, p.value, payloadHash);
        }
        return ok;
    }

    // ---------- Self-governed owner management (must be routed through execute()) ----------

    function addOwner(address newOwner) external onlySelf {
        if (newOwner == address(0)) revert ZeroAddressOwner();
        if (isOwner[newOwner]) revert DuplicateOwner();
        isOwner[newOwner] = true;
        owners.push(newOwner);
        emit OwnerAdded(newOwner);
    }

    function removeOwner(address ownerToRemove) external onlySelf {
        if (!isOwner[ownerToRemove]) revert OwnerNotFound();
        if (owners.length - 1 < threshold) revert CannotDropBelowThreshold();

        isOwner[ownerToRemove] = false;
        uint256 len = owners.length;
        for (uint256 i = 0; i < len; i++) {
            if (owners[i] == ownerToRemove) {
                owners[i] = owners[len - 1];
                owners.pop();
                break;
            }
        }
        emit OwnerRemoved(ownerToRemove);
    }

    function changeThreshold(uint256 newThreshold) external onlySelf {
        if (newThreshold == 0 || newThreshold > owners.length) revert InvalidThreshold();
        threshold = newThreshold;
        emit ThresholdChanged(newThreshold);
    }

    function ownerCount() external view returns (uint256) {
        return owners.length;
    }
}
