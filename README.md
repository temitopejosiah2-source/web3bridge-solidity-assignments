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

## Deploying with the Foundry scripts

Every assignment has a deploy script under script/, which deploys the main contract plus any
demo tokens/oracles it needs to be immediately usable. Each script reads the deployer's private
key from the PRIVATE_KEY environment variable -- never hardcode a key in the script and never
commit a .env file containing one.

```bash
# 1. In one terminal, start a local chain:
anvil

# 2. In another terminal, export a private key (use one of anvil's printed demo keys locally --
#    never do this with a real key on a real network):
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# 3. Run any script, e.g.:
forge script script/01-launchpad/DeployTokenLaunchpad.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Each script prints the deployed contract addresses via console2.log so you can copy them
straight into cast call / cast send commands. The full list:

```
script/01-launchpad/DeployTokenLaunchpad.s.sol
script/02-nft-minter/DeployMerkleNFTMinter.s.sol
script/03-vesting/DeployTokenVestingVault.s.sol
script/04-governance/DeployDAOTreasuryGovernor.s.sol
script/05-vault/DeployYieldVault.s.sol
script/06-multisig/DeployMultisigPayroll.s.sol
script/07-marketplace/DeployNFTMarketplace.s.sol
script/08-crowdfunding/DeployMilestoneCrowdfunding.s.sol
script/09-lending/DeployCollateralizedLending.s.sol
```

To deploy to a real testnet instead of a local chain, swap --rpc-url http://127.0.0.1:8545 for
your testnet RPC URL (e.g. from Alchemy or Infura) and use a funded testnet-only private key.

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
