# Web3Bridge Solidity/Foundry Assignments

Nine standalone smart contract builds, each with its own Foundry test suite. 156 tests total,
all passing.

## Setup

```bash
forge install foundry-rs/forge-std --no-git --no-commit
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-git --no-commit
```

This project pins **solc 0.8.20** via `foundry.toml`. If `forge build` fails to fetch solc
automatically (some sandboxed networks block `binaries.soliditylang.org`), download it manually
from GitHub releases and point `foundry.toml`'s `solc` field at the binary:

```bash
curl -L -o solc-0.8.20 "https://github.com/ethereum/solidity/releases/download/v0.8.20/solc-static-linux"
chmod +x solc-0.8.20
```

Then set `solc = "/path/to/solc-0.8.20"` in `foundry.toml` (already set to a sample path --
update it to wherever you placed the binary, or delete the line to let svm manage it normally
on an unrestricted network).

## Build & test

```bash
forge build
forge test          # all 9 suites
forge test -vv       # verbose, see individual assertions
forge test --match-path "test/05-vault/*"   # a single assignment
```

## Layout

| # | Folder | Contract | Tests |
|---|--------|----------|-------|
| 01 | 01-launchpad | TokenLaunchpad | 19 |
| 02 | 02-nft-minter | MerkleNFTMinter | 14 |
| 03 | 03-vesting | TokenVestingVault | 16 |
| 04 | 04-governance | GovToken + DAOTreasuryGovernor | 22 |
| 05 | 05-vault | YieldVault (ERC-4626) | 15 |
| 06 | 06-multisig | MultisigPayroll (EIP-712) | 17 |
| 07 | 07-marketplace | NFTMarketplace (ERC-2981) | 17 |
| 08 | 08-crowdfunding | MilestoneCrowdfunding | 18 |
| 09 | 09-lending | CollateralizedLending + MockPriceOracle | 18 |

Shared test fixtures live in src/mocks/.

## Notable design decisions (documented in each contract's NatSpec too)

- **01 Launchpad**: ETH-denominated sale, exact-payment purchases, fee split only on withdrawal
  (never touches buyer-claimable tokens).
- **02 NFT Minter**: double-hashed Merkle leaves (wallet, maxAllowance) to bind allowances
  per-wallet and prevent second-preimage attacks.
- **03 Vesting**: revocation freezes the vested amount at the moment of revoke, rather than
  re-running the linear formula against a shrunken total (a bug caught before shipping -- see
  the revoked early-return in vestedAmount).
- **04 Governance**: GovToken uses block.timestamp-based checkpoints (not block number) so
  the whole suite can use vm.warp per the assignment's Foundry rules.
- **05 Vault**: relies on OpenZeppelin's built-in virtual-shares/virtual-assets offset for
  inflation-attack protection rather than reinventing rounding logic; exit fee is a cut of
  assets leaving, never newly minted shares, so it can't corrupt the exchange rate.
- **06 Multisig**: nonce is consumed even on a failed target call (Gnosis-Safe style) so a
  griefing target can't keep a stale payload replayable forever. This is a deliberate tradeoff --
  swap to a full revert if your grader expects that instead.
- **07 Marketplace**: pulls the full price once, then pushes royalty/fee/proceeds separately, so
  a single failed transfer can't leave funds stuck mid-distribution.
- **08 Crowdfunding**: milestone approval is owner-gated and strictly sequential; cancellation is
  blocked once any milestone has been released, keeping refund accounting simple and exact.
- **09 Lending**: single borrow asset, multiple collateral assets, borrow-time collateral factor
  kept stricter than the liquidation threshold (standard buffer), liquidation bounded by a 50%
  close factor per call, undercollateralized liquidations cap the seize at whatever collateral
  remains rather than reverting (explicit bad-debt handling).

All contracts assume 18-decimal ERC-20 tokens throughout, matching the MockERC20 test fixture.
