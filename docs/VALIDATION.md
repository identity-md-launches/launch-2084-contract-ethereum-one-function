# Validation and review notes

The project is compiled with Solidity **0.8.26**, Cancun, optimizer runs 200, and no bytecode hash.
Local tests use the assignment's fuzz seed:
`0x47c3314df5f633c89b34152424c75dd0746ecdfbd9985a406034b3fe476f6e95`.

Revision note: the review-driven revision (`buyWebsiteWithMinimum`, `setAction`, UTF-8
validation, URI storage budget, any nonzero failure status, `WebsiteRevision.t.sol` and the
real-pool sandwich test) was written on a worker whose shell sandbox could not start any
process, so it was **not compiled or run locally**; the verifier's `forge build` and
`forge test` are its first checks. The figures below are from the previously accepted round.

Previous round's local checks: `forge build` succeeded from a clean cache and empty environment;
`forge test --offline` passed **59 tests in 6 suites**, including 512 cases per fuzz test, with
that seed and an empty environment; `forge fmt --check` passed. The ordinary `forge test`
command also passed the full suite. Runtime sizes are 10,426 bytes for `WebsiteBuyer` and
2,093 bytes for `IntakeAccount`, with no library link references in either creation bytecode.

## Coverage of behavior

| Suite | Checks |
| --- | --- |
| `WebsiteBuyer.t.sol` | Exact action/body/payment/callback registration; fixed pool hash; complete exact-input native swap; all surplus returned; moved/zero price; stable separate payer identities; output/payment/approval/refund failures and rollback; partial fills; callback spoofing at unlock; token/Intake reentrancy; owner controls. |
| `WebsiteWords.t.sol` | Empty/oversized input; quote/backslash; every ASCII control and DEL; 1 and 1000 byte boundaries; multibyte UTF-8 byte limit; fuzzed valid and invalid words. |
| `WebsiteCallbacks.t.sol` | Result hash and URI storage/events; status 1/2 failures and no refunds; both callbacks within 200,000 gas; wrong sender, unknown request, duplicate and cross-kind replay; unsupported status; old/new Intake authorities; paused/missing/failed delivery with later purchases unaffected. |
| `IntakeAccount.t.sol` | Buyer-only arbitrary calls; hub-only purchases; original payer continuing a project; another payer refused; owner cannot use buyer accounts; native/token recovery; payable execution, return/revert data, reentrancy, and preservation of independent user funds. |
| `UniswapIntegration.t.sol` | Real pinned PoolManager, actual liquidity and swap math; full ETH settlement and output conservation; below-price rollback including price/tick state; actual partial fill and empty liquidity; repeated purchases; ERC-20 sync followed by native settlement in the same transaction. |
| `Deployment.t.sol` | Explicit owner through a factory; constructor on an empty chain; zero-owner rejection; EIP-170/EIP-3860 sizes; runtime scan rejects DELEGATECALL, CALLCODE, and SELFDESTRUCT while skipping PUSH operands. |

All tests use independent fixtures and constants, never `vm.env*`, `vm.setEnv`, network forks,
FFI, keys, or sender-dependent script configuration. The real-manager test installs the upstream
constructor and runtime at the brief's fixed address with forge-std `deployCodeTo`; this sets its
`NoDelegateCall` immutable correctly. The manager source and math are not replaced by a mock in
that suite. Synthetic token balances, liquidity, Intake prices, and delivery are local fixtures,
not evidence of live chain conditions.

## Manual review

- The hub only permits buying its fixed action with its fixed body. Manager callback authority
  requires both the fixed manager and a currently active purchase. Its single-use amount is
  cleared before swapping. A missing or repeated unlock callback reverts.
- Every `msg.value` conversion is preceded by an `int128` bound. A negative native delta must
  equal the full input, and the IMD delta must be positive before unsigned conversion. The actual
  token balance increase is checked against that credit, and donated balances cannot satisfy
  the minimum output test.
- Purchases are nonreentrant. Account `ask` and `execute` have their own nonreentrant guard.
  An owner cannot reconfigure the Intake midway through a purchase; the endpoint is also
  snapshotted locally and then stored per request. Callback handlers do no external calls or
  value transfers, so their once-only state transition does not open a reentrancy path.
- The account grants an exact allowance and revokes it after the request. Its IMD balance must
  decrease by the exact price, preserving buyer-funded balances while refusing a missing debit.
  A failed refund unwinds the prior Intake payment, swap, and account creation.
- Account `execute` intentionally allows any CALL, including value transfer, **only for its
  immutable buyer**. It does not delegate execution or expose access to the hub administrator.
  Direct user calls can approve third parties; that is the user's authority over their own account.
- The record is created after Intake returns its request ID, matching its asynchronous protocol.
  A hypothetical synchronous callback before the ID returns is rejected as unknown. New endpoints
  must preserve this protocol. Duplicate IDs are rejected, including across Intake migrations.
- The callback trust and settlement state remain bound to the original Intake. They cannot be
  reassigned by the owner. Callbacks do not automatically consume or interpret result JSON.
- The words filter has bounded cost, prevents string injection, and refuses malformed UTF-8
  (RFC 3629 lead/continuation ranges). Content acceptance remains the plane's. The fixed body
  carries no owner field.
- The requested one-argument buying interface only protects a minimum of the live price; the
  added `buyWebsiteWithMinimum` bounds the buyer's surplus and the inclusion time. MEV on the
  one-argument form, the owner-controlled Intake and action, nonrefundable job prices, callback
  loss, and accidental deposits are documented in README.

Forge's optional linter reports conservative warnings for guarded external calls, explicit numeric
casts, intentional balance equalities, a bounded validation loop, and the temporary unlock flag.
The reentrancy guard is set **before** external calls; the later write the linter flags restores it.
The flag has no long-lived administrative authority. `execute` intentionally permits a buyer's
chosen target, including zero; the hub never does arbitrary execution. These warnings were reviewed
against the call paths and adversarial tests; build success is not presented as an independent audit.

No deployment, live mainnet fork, independent contributor audit, Slither analysis, or Mythril
analysis was performed. Before production use, the launch reviewer/operator must verify live
dependencies, pool availability, protocol admission, and operational monitoring.
