// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title MerkleNFTMinter
/// @notice ERC-721 minter with a Merkle-allowlist phase and a public-sale phase.
contract MerkleNFTMinter is ERC721, Ownable, Pausable, ReentrancyGuard {
    enum Phase {
        Inactive,
        Allowlist,
        Public
    }

    uint256 public immutable maxSupply;
    uint256 public totalSupply;
    uint256 public nextTokenId = 1;

    uint256 public allowlistPrice;
    uint256 public publicPrice;
    uint256 public publicPerWalletLimit;

    bytes32 public merkleRoot;
    Phase public phase;
    string private _baseTokenURI;

    mapping(address => uint256) public allowlistMinted;
    mapping(address => uint256) public publicMinted;

    event PhaseChanged(Phase newPhase);
    event MerkleRootUpdated(bytes32 newRoot);
    event BaseURIUpdated(string newBaseURI);
    event AllowlistMint(address indexed minter, uint256 amount, uint256 maxAllowance);
    event PublicMint(address indexed minter, uint256 amount);
    event Withdrawal(address indexed to, uint256 amount);

    error PhaseNotActive();
    error InvalidProof();
    error AllowanceExceeded();
    error WalletLimitExceeded();
    error SupplyExceeded();
    error IncorrectPayment();
    error ZeroAmount();
    error WithdrawFailed();
    error ZeroAddress();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        uint256 allowlistPrice_,
        uint256 publicPrice_,
        uint256 publicPerWalletLimit_,
        address initialOwner
    ) ERC721(name_, symbol_) Ownable(initialOwner) {
        if (maxSupply_ == 0) revert ZeroAmount();
        maxSupply = maxSupply_;
        allowlistPrice = allowlistPrice_;
        publicPrice = publicPrice_;
        publicPerWalletLimit = publicPerWalletLimit_;
    }

    // ---------- Owner controls ----------

    function setMerkleRoot(bytes32 newRoot) external onlyOwner {
        merkleRoot = newRoot;
        emit MerkleRootUpdated(newRoot);
    }

    function setPhase(Phase newPhase) external onlyOwner {
        phase = newPhase;
        emit PhaseChanged(newPhase);
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    function setPrices(uint256 newAllowlistPrice, uint256 newPublicPrice) external onlyOwner {
        allowlistPrice = newAllowlistPrice;
        publicPrice = newPublicPrice;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdraw(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = address(this).balance;
        (bool ok,) = to.call{value: balance}("");
        if (!ok) revert WithdrawFailed();
        emit Withdrawal(to, balance);
    }

    // ---------- Minting ----------

    /// @dev Leaf commits to (wallet, maxAllowance) so an altered allowance never matches an honest proof.
    function _leaf(address wallet, uint256 maxAllowance) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(wallet, maxAllowance))));
    }

    function allowlistMint(uint256 amount, uint256 maxAllowance, bytes32[] calldata proof)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        if (phase != Phase.Allowlist) revert PhaseNotActive();
        if (amount == 0) revert ZeroAmount();

        bytes32 leaf = _leaf(msg.sender, maxAllowance);
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert InvalidProof();

        uint256 newMinted = allowlistMinted[msg.sender] + amount;
        if (newMinted > maxAllowance) revert AllowanceExceeded();

        if (totalSupply + amount > maxSupply) revert SupplyExceeded();

        uint256 cost = allowlistPrice * amount;
        if (msg.value != cost) revert IncorrectPayment();

        allowlistMinted[msg.sender] = newMinted;
        _mintBatch(msg.sender, amount);

        emit AllowlistMint(msg.sender, amount, maxAllowance);
    }

    function publicMint(uint256 amount) external payable whenNotPaused nonReentrant {
        if (phase != Phase.Public) revert PhaseNotActive();
        if (amount == 0) revert ZeroAmount();

        uint256 newMinted = publicMinted[msg.sender] + amount;
        if (newMinted > publicPerWalletLimit) revert WalletLimitExceeded();

        if (totalSupply + amount > maxSupply) revert SupplyExceeded();

        uint256 cost = publicPrice * amount;
        if (msg.value != cost) revert IncorrectPayment();

        publicMinted[msg.sender] = newMinted;
        _mintBatch(msg.sender, amount);

        emit PublicMint(msg.sender, amount);
    }

    function _mintBatch(address to, uint256 amount) internal {
        uint256 tokenId = nextTokenId;
        for (uint256 i = 0; i < amount; i++) {
            _safeMint(to, tokenId);
            unchecked {
                tokenId++;
            }
        }
        nextTokenId = tokenId;
        totalSupply += amount;
    }

    // ---------- Metadata ----------

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
}
