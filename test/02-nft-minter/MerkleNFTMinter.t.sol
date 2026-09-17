// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MerkleNFTMinter} from "../../src/02-nft-minter/MerkleNFTMinter.sol";

contract MerkleNFTMinterTest is Test {
    MerkleNFTMinter nft;

    address owner = makeAddr("owner");
    address alice;
    uint256 alicePk;
    address bob = makeAddr("bob");
    address carol = makeAddr("carol"); // not on the allowlist

    uint256 constant MAX_SUPPLY = 100;
    uint256 constant ALLOWLIST_PRICE = 0.05 ether;
    uint256 constant PUBLIC_PRICE = 0.08 ether;
    uint256 constant PUBLIC_LIMIT = 3;

    uint256 constant ALICE_ALLOWANCE = 2;
    uint256 constant BOB_ALLOWANCE = 1;

    bytes32 root;
    bytes32[] aliceProof;
    bytes32[] bobProof;

    function setUp() public {
        (alice, alicePk) = makeAddrAndKey("alice");

        nft = new MerkleNFTMinter("Merkle NFT", "MNFT", MAX_SUPPLY, ALLOWLIST_PRICE, PUBLIC_PRICE, PUBLIC_LIMIT, owner);

        // Build a 2-leaf Merkle tree off-chain style: leaf = keccak256(keccak256(abi.encode(wallet, allowance)))
        bytes32 leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice, ALICE_ALLOWANCE))));
        bytes32 leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob, BOB_ALLOWANCE))));

        // Sort pair for standard OpenZeppelin MerkleProof (sorted pair hashing)
        root = leafAlice < leafBob
            ? keccak256(abi.encodePacked(leafAlice, leafBob))
            : keccak256(abi.encodePacked(leafBob, leafAlice));

        aliceProof = new bytes32[](1);
        aliceProof[0] = leafBob;
        bobProof = new bytes32[](1);
        bobProof[0] = leafAlice;

        vm.prank(owner);
        nft.setMerkleRoot(root);

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }

    // ---------- Phase gating ----------

    function test_RevertWhen_AllowlistMintInactivePhase() public {
        // phase defaults to Inactive
        vm.prank(alice);
        vm.expectRevert(MerkleNFTMinter.PhaseNotActive.selector);
        nft.allowlistMint{value: ALLOWLIST_PRICE}(1, ALICE_ALLOWANCE, aliceProof);
    }

    function test_RevertWhen_PublicMintDuringAllowlistPhase() public {
        vm.prank(owner);
        nft.setPhase(MerkleNFTMinter.Phase.Allowlist);

        vm.prank(bob);
        vm.expectRevert(MerkleNFTMinter.PhaseNotActive.selector);
        nft.publicMint{value: PUBLIC_PRICE}(1);
    }

    // ---------- Allowlist proof correctness ----------

    function test_AllowlistMint_ValidProofSucceeds() public {
        vm.prank(owner);
        nft.setPhase(MerkleNFTMinter.Phase.Allowlist);

        vm.prank(alice);
        nft.allowlistMint{value: ALLOWLIST_PRICE}(1, ALICE_ALLOWANCE, aliceProof);

        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.allowlistMinted(alice), 1);
    }

    function test_RevertWhen_InvalidProof() public {
        vm.prank(owner);
        nft.setPhase(MerkleNFTMinter.Phase.Allowlist);

        // Carol is not in the tree; using Alice's proof with Carol's address fails.
        vm.prank(carol);
        vm.expectRevert(MerkleNFTMinter.InvalidProof.selector);
        nft.allowlistMint{value: ALLOWLIST_PRICE}(1, ALICE_ALLOWANCE, aliceProof);
    }

    function test_RevertWhen_AllowanceAltered() public {
        vm.prank(owner);
        nft.setPhase(MerkleNFTMinter.Phase.Allowlist);

        // Alice tries to claim a bigger allowance than her committed leaf using her real proof.
        vm.prank(alice);
        vm.expectRevert(MerkleNFTMinter.InvalidProof.selector);
        nft.allowlistMint{value: ALLOWLIST_PRICE * 5}(5, ALICE_ALLOWANCE + 3, aliceProof);
    }

    // ---------- Repeat claims / allowance exceeded ----------

    function test_RevertWhen_AllowlistAllowanceExceeded() public {
        vm.prank(owner);
        nft.setPhase(MerkleNFTMinter.Phase.Allowlist);

        vm.startPrank(alice);
        nft.allowlistMint{value: ALLOWLIST_PRICE * ALICE_ALLOWANCE}(ALICE_ALLOWANCE, ALICE_ALLOWANCE, aliceProof);

        vm.expectRevert(MerkleNFTMinter.AllowanceExceeded.selector);
        nft.allowlistMint{value: ALLOWLIST_PRICE}(1, ALICE_ALLOWANCE, aliceProof);
        vm.stopPrank();
    }

    // ---------- Supply exhaustion ----------

    function test_RevertWhen_OverMintingPastMaxSupply() public {
        MerkleNFTMinter small = new MerkleNFTMinter("Small", "SM", 1, ALLOWLIST_PRICE, PUBLIC_PRICE, PUBLIC_LIMIT, owner);
        vm.startPrank(owner);
        small.setPhase(MerkleNFTMinter.Phase.Public);
        vm.stopPrank();

        vm.prank(alice);
        small.publicMint{value: PUBLIC_PRICE}(1);

        vm.prank(bob);
        vm.expectRevert(MerkleNFTMinter.SupplyExceeded.selector);
        small.publicMint{value: PUBLIC_PRICE}(1);
    }

    // ---------- Payment checks ----------

    function test_RevertWhen_IncorrectPayment_Public() public {
        vm.prank(owner);
        nft.setPhase(MerkleNFTMinter.Phase.Public);

        vm.prank(bob);
        vm.expectRevert(MerkleNFTMinter.IncorrectPayment.selector);
        nft.publicMint{value: PUBLIC_PRICE - 1}(1);
    }

    function test_RevertWhen_PublicWalletLimitExceeded() public {
        vm.prank(owner);
        nft.setPhase(MerkleNFTMinter.Phase.Public);

        vm.startPrank(bob);
        nft.publicMint{value: PUBLIC_PRICE * PUBLIC_LIMIT}(PUBLIC_LIMIT);

        vm.expectRevert(MerkleNFTMinter.WalletLimitExceeded.selector);
        nft.publicMint{value: PUBLIC_PRICE}(1);
        vm.stopPrank();
    }

    // ---------- Phase transitions ----------

    function test_PhaseTransition_AllowlistThenPublic() public {
        vm.startPrank(owner);
        nft.setPhase(MerkleNFTMinter.Phase.Allowlist);
        vm.stopPrank();

        vm.prank(alice);
        nft.allowlistMint{value: ALLOWLIST_PRICE}(1, ALICE_ALLOWANCE, aliceProof);

        vm.prank(owner);
        nft.setPhase(MerkleNFTMinter.Phase.Public);

        vm.prank(carol);
        nft.publicMint{value: PUBLIC_PRICE}(1);

        assertEq(nft.totalSupply(), 2);

        // Allowlist path is now closed even though Alice has remaining allowance.
        vm.prank(alice);
        vm.expectRevert(MerkleNFTMinter.PhaseNotActive.selector);
        nft.allowlistMint{value: ALLOWLIST_PRICE}(1, ALICE_ALLOWANCE, aliceProof);
    }

    // ---------- Pausing ----------

    function test_RevertWhen_MintWhilePaused() public {
        vm.startPrank(owner);
        nft.setPhase(MerkleNFTMinter.Phase.Public);
        nft.pause();
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert();
        nft.publicMint{value: PUBLIC_PRICE}(1);
    }

    // ---------- Withdrawal access control ----------

    function test_RevertWhen_UnauthorizedWithdraw() public {
        vm.prank(alice);
        vm.expectRevert();
        nft.withdraw(alice);
    }

    function test_Withdraw_SendsFullBalanceToOwnerChosenAddress() public {
        vm.prank(owner);
        nft.setPhase(MerkleNFTMinter.Phase.Public);
        vm.prank(bob);
        nft.publicMint{value: PUBLIC_PRICE}(1);

        address treasury = makeAddr("treasury");
        vm.prank(owner);
        nft.withdraw(treasury);

        assertEq(treasury.balance, PUBLIC_PRICE);
    }

    // ---------- Fuzz: allowlist allowance boundary ----------

    function testFuzz_AllowlistNeverExceedsCommittedAllowance(uint256 amount) public {
        amount = bound(amount, 1, 20);

        vm.prank(owner);
        nft.setPhase(MerkleNFTMinter.Phase.Allowlist);

        vm.prank(alice);
        if (amount > ALICE_ALLOWANCE) {
            vm.expectRevert(MerkleNFTMinter.AllowanceExceeded.selector);
            nft.allowlistMint{value: ALLOWLIST_PRICE * amount}(amount, ALICE_ALLOWANCE, aliceProof);
        } else {
            nft.allowlistMint{value: ALLOWLIST_PRICE * amount}(amount, ALICE_ALLOWANCE, aliceProof);
            assertEq(nft.allowlistMinted(alice), amount);
        }
    }
}
