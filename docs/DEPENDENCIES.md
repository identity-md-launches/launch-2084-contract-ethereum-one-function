# Dependency provenance

Dependencies are ordinary source files in `lib/`. There are no git submodules, compiler binaries,
runtime downloads, or external library links. Imported source files are unmodified; unused files
have been omitted.

| Dependency | Version / exact commit | Included portion | License |
| --- | --- | --- | --- |
| [forge-std](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | v1.9.7 / `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | Full `src/` and licenses; tests only | MIT / Apache-2.0 |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/69c8def5f222ff96f2b5beff05dfba996368aa79) | v5.1.0 / `69c8def5f222ff96f2b5beff05dfba996368aa79` | Ownable2Step, Pausable, ReentrancyGuard, SafeERC20, ERC20, and their import closure | MIT |
| [Uniswap v4 core](https://github.com/Uniswap/v4-core/tree/e50237c43811bd9b526eff40f26772152a42daba) | v4.0.0 / `e50237c43811bd9b526eff40f26772152a42daba` | Runtime `src/` excluding upstream test fixtures; `licenses/` | Per-file MIT / BUSL-1.1 |
| [Solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | v4 core's pinned dependency / `4b47a19038b798b4a33d9749d25e570443520647` | `src/auth/Owned.sol`, used by the test PoolManager; license | AGPL-3.0-only file header / repository AGPL license |

The application imports v4 interfaces/types and its MIT TickMath library. The actual PoolManager
and its BUSL implementation are used only by offline integration tests. Production calls the
existing PoolManager address; this launch neither deploys a PoolManager nor creates a pool.

`src/interfaces/IIntake.sol` was copied from the supplied canonical Intake v2 reference.
`src/IntakeAccount.sol` adapts its MIT example with exact payment consumption checks, explicit
approval cleanup, a nonzero-user check, a reentrancy guard, and payable `execute`. Tests adapt the
protocol's examples for this specific website purchase flow and add local v4 integration.

The task's fixed asset, pool, action, template, 1000-byte limit, and owner-settable Intake take
precedence over the general reference's configurable multipurpose hub. `job.open` has no `owner`
field. The full result URI is stored as well as emitted, unlike the example's event-only URI.

Uniswap settlement behavior was cross-checked against the pinned source and the official
[unlock and delta documentation](https://developers.uniswap.org/docs/protocols/v4/guides/unlock-callback-and-deltas).
`sync(native)` before settling ETH also covers a preceding ERC-20 sync within the same transaction.

The upstream `forge-std` console implements the logging assembly in a `view` helper. Its upstream
function-type conversion supports the pure logging wrappers; the invalid pure staticcall helper
from the rejected attempt was not recreated.
