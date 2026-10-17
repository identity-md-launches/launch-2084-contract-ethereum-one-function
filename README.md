# WebsiteBuyer

Buy a hosted one-page website on Ethereum with one payable call:

```solidity
bytes32 requestId = websiteBuyer.buyWebsite{value: ethBudget}("a bakery in Lisbon");
```

A buyer who wants a bound on the IMD returned uses the protected form of the same purchase:

```solidity
bytes32 requestId = websiteBuyer.buyWebsiteWithMinimum{value: ethBudget}(words, minSurplus, deadline);
```

It reverts `SurplusTooLow(surplus, minSurplus)` unless at least `minSurplus` IMD comes back after
the live price is paid, and `Expired(deadline)` once `block.timestamp > deadline`. That one floor
covers a sandwich, a stale transaction, and a price raised between quote and inclusion. The
one-argument `buyWebsite(words)` is the same purchase with `minSurplus = 0` and no deadline.

The buyer needs ETH for the purchase and transaction gas. No IMD balance, token approval,
registration transaction, or fixed ETH price is needed. Website creation happens asynchronously;
the swap, payment, request submission, and surplus refund happen atomically in the purchase call.

## Purchase behavior

1. Validate `words`: 1–1000 **bytes**, excluding `"`, `\`, ASCII controls `0x00`–`0x1f`, and DEL
   (`0x7f`), and they must be well-formed UTF-8: no stray or missing continuation bytes, overlong
   forms, UTF-16 surrogates, or code points above U+10FFFF, so the plane is never sent a body it
   cannot parse. `bodyOf(words)` previews the exact request bytes.
2. Read `intake.priceOf(action, IMD)`, where `action` starts as `bytes32("job.open@job-1")` and
   the owner can move it with `setAction`. Zero means unavailable. The quoted
   0.5 IMD is not hardcoded as the price; the live raw-token amount is used on every purchase.
3. Unlock the fixed Uniswap v4 PoolManager and perform a native ETH → IMD exact-input swap of
   **all `msg.value`**, using the fixed pool below. There is no WETH wrapping, router, or Permit2.
   The callback resets the synced currency to native ETH, settles the ETH debt, and takes all IMD.
4. Require a full fill and at least the live Intake price in actual received IMD. A partial fill,
   zero output, insufficient output, or failed downstream operation reverts the entire transaction.
   Gas spent on a reverting transaction is still payable to Ethereum.
5. Create the buyer's `IntakeAccount` on their first successful purchase, reusing it thereafter.
   Transfer exactly the price to that account, which approves and calls Intake v2
   `requestWithFailure`, then explicitly clears the allowance and verifies the price was consumed.
6. Store the returned request ID and its buyer, price, and accepting Intake. Transfer every IMD
   from the swap above that price to the buyer. Emit `WebsiteRequested` with the accounting totals.

The body is exactly:

```json
{"objective":"Build a one-page website: a bakery in Lisbon","skill":"build-website","host":true}
```

Only the words are substituted. There is **no `owner` field**, arbitrary JSON input, configurable
template, platform fee, extra action offered by the hub, or fixed ETH charge.

## Deployment parameters

Deploy **one application**, `src/WebsiteBuyer.sol:WebsiteBuyer`, with a nonpayable constructor:

| Argument | Launch value |
| --- | --- |
| `address owner_` | `$owner`, resolving to `0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7` |

The constructor sets that explicit owner and the initial Intake. It makes no external calls and
does not require any dependencies to exist during deployment. Factory deployment therefore does
not give the factory control. No initializer, constructor ETH, library linking, proxy, or
post-deployment configuration is required for the specified Ethereum deployment.

`IntakeAccount` is a helper created by `WebsiteBuyer` at purchase time, **not a second launch
application**. Its `user` is the buyer and its immutable `hub` is the deploying `WebsiteBuyer`.
Its CREATE2 salt is the buyer address left-padded to 32 bytes. Account addresses depend on the
hub and account creation bytecode; `accountOf(buyer)` and `AccountOpened` are authoritative.

| Fixed parameter | Value |
| --- | --- |
| Supported chain | Ethereum, chain ID 1; Cancun-compatible EVM |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| Initial Intake v2 | `0xa43e6F75ee006411F79Ac1C84120606C2330DE82` |
| PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Currency 0 | Native ETH, `address(0)` |
| Currency 1 | IMD |
| Pool fee | `10000` hundredths of a basis point = 1% |
| Tick spacing | `200` |
| Hooks | None, `address(0)` |
| Pool ID | `0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3` |
| Initial action | Right-padded UTF-8 `job.open@job-1`, **not its hash**; owner-settable |
| `MAX_WORDS_BYTES` | `1000` |
| `MAX_STORED_URI_BYTES` | `128`; longer result URIs are emitted but not stored |
| Swap price boundary | Uniswap `TickMath.MIN_SQRT_PRICE + 1` (`4295128740`) |
| Input bound | Positive ETH amount fitting `int128`, as required by v4 deltas |

The pool ID is checked against `keccak256(abi.encode(poolKey))` in the tests. Native ETH and no
hooks intentionally use zero addresses; no unspecified dependency or owner is filled with a
stand-in. The contract does not enforce a chain-ID restriction in its constructor; deployment on
any other chain is unsupported even if code happens to exist at matching addresses.

The separate launch process supplies the manifest and deploys the application. This repository
does not supply `launch.json`, broadcast transactions, or obtain deployment credentials.

## Results and failures

`buyWebsite` returns the Intake request ID. Off-chain callers should obtain it from the
`WebsiteRequested` transaction log. `requestOf(requestId)` returns:

- `buyer`, `intake`, and `price` from the purchase;
- `state`: `None`, `Pending`, `Done`, or `Failed`;
- `resultHash` and the `uri` after a result (the `uri` is stored when it is at most 128 bytes);
- `status` and `reason` after a refusal or failure.

The accepting Intake calls `onIntakeResult(bytes32,bytes32,string)` on success, or
`onIntakeFailure(bytes32,uint8,bytes32,uint16,uint16,bytes)` on refusal (1), failure without a
result (2), or any other nonzero status the plane defines later, which is recorded as given.
Both require the original accepting Intake, a known request, and a pending state.
Each request settles only once. Unknown requests, replayed callbacks, direct writer calls,
other senders, and a failure status of zero revert. Changing `intake` does not change the
authority over existing requests. Duplicate request IDs revert new purchases rather than
overwriting earlier records.

`WebsiteResult` always emits the hash and the full URI; the state and hash are always stored, and
the URI is stored too when it fits `MAX_STORED_URI_BYTES`, so a long URI cannot push the callback
past its gas stipend. `WebsiteFailure` records and emits
the status and reason. Panel counts and the unused signature parameter are not interpreted.
The supplied protocol describes these callbacks as unsigned statements of the Intake writer;
they never authorize a payout or any execution of result data.

The Intake attempts delivery once with 200,000 gas. Tests deliver a normal 78-byte IPFS result
URI, a 128-byte stored URI and a 4096-byte emitted-only URI under that stipend. Only a URI of
tens of kilobytes (whose log alone costs more than the stipend) is lost; a lost or reverting callback leaves this contract's record pending. Purchases and account
operations never wait on callback completion, and there are no callback-dependent funds to
unlock. Operators should reconcile against the protocol's `GET /intake/{chainId}/{transactionHash}`
and result document when delivery fails. Do not infer a refund entitlement from `Pending`.

The Intake price is forwarded immediately and **is spent even when the job is refused, blocked,
cancelled, or otherwise fails**. Neither the hub nor the payer account escrows it or promises a
refund. A result hash should be checked against the fetched document's bytes off chain.

## Continuing a buyer's project

The protocol identifies the project owner by the payer at the Intake. Different buyers have
different accounts; the hub itself never pays for all users from one shared identity. The account
keeps its buyer and hub immutable. The launch owner cannot execute as someone else's account.

Only the buyer can call their account's
`execute(address target, uint256 value, bytes data)`, which performs a normal CALL and returns
the result, bubbling a revert unchanged. It is payable, can forward ETH, and is protected against
reentrancy. The account can receive ETH separately. The buyer can recover assets sent directly to
their account or continue their project without relying on the hub's owner or pause setting.

To continue:

1. Read the newest `jobId` from the result document and ensure the project's work is finished
   or blocked and any required delivery has completed.
2. Fetch the live `priceOf(bytes32("job.continue@job-1"), IMD)` and fund the **same account** with
   that much IMD. The hub's one-function purchase flow opens new websites; it does not sell
   continuations with ETH.
3. From the buyer wallet, call `account.execute(IMD, 0, abi.encodeCall(IERC20.approve, (intake, price)))`.
4. From the same wallet, call `account.execute(intake, 0, encodedRequestWithFailure)` using the
   continuation action, price, and a JSON body containing `parentJobId`, `objective`,
   `skill: "build-website"`, and `host: true`. Select a callback receiver the buyer controls that
   supports the protocol ABI, or omit callbacks and follow the protocol result endpoint. The hub
   rejects callbacks for these direct requests because it did not register them.
5. Confirm the allowance was consumed, or revoke it through `execute` if the intended request
   was not made. These direct calls are user-managed and are not the atomic `buyWebsite` flow.

The plane enforces continuation ownership off chain. Another buyer cannot execute through the
original payer. Paying through a different account to name someone else's job is refused by the
plane and still spends that payer's price. Tests explicitly model that distinction.

## After launch

| Responsibility | Action |
| --- | --- |
| Launch service | Deploy `WebsiteBuyer` with the specified owner, verify bytecode and publish the confirmed address/ABI. |
| Owner | Monitor the Intake version and action availability. Use `setIntake(IIntake)` only for a verified compatible IMD-paying v2 endpoint obtained from IdentityMD's deployment information. Changes are emitted in `IntakeChanged`. |
| Owner | When IdentityMD retires `job.open@job-1` and prices a newer version at the same Intake, call `setAction(bytes32)` with the new right-padded action id (from the intake-client reference or IdentityMD's deployment information). Changes are emitted in `ActionChanged`; existing payer accounts are kept. |
| Owner | Use `setPaused(true)` to stop new purchases and `setPaused(false)` to resume. Callbacks and buyer account execution remain available. |
| Owner | To transfer administration, call `transferOwnership(next)`, then have `next` call `acceptOwnership()`. Setting pending owner to zero cancels the handover. Inherited `renounceOwnership()` permanently removes administration; if paused, purchases then remain paused forever. |
| Client/operator | Preview and validate the body, quote the real pool, estimate gas (first purchase deploys an account), explain ETH spending and IMD surplus, submit the purchase, and index its request ID and callbacks. |
| Client/operator | Monitor the result endpoint when callbacks are missing, and validate the served content against `resultHash`. |
| Release reviewer | Independently review the fund-moving contracts and verify the production dependencies and pool liquidity before enabling public use. |

The mutable protocol settings are the Intake and the action id. IMD, PoolManager, the pool key
and website JSON template are deliberately fixed by this task (the asset must be the pool's IMD,
since the swap output is what pays). A protocol change to those fixed
values needs a new hub; existing payer accounts remain controlled by their buyers. There is no
asset rescue function or general owner execution function on the hub.

## Assumptions and limits

- **Execution price:** in the one-argument `buyWebsite(string)` the only minimum output is the
  live Intake price, so a trade can succeed at a poor exchange rate, including a sandwich that
  reduces the surplus to nearly zero (reproduced on the real v4 pool in
  `test_realPoolSandwichIsRefusedByBuyerMinimum`). Clients should quote the pool and call
  `buyWebsiteWithMinimum(words, minSurplus, deadline)` instead, which refuses such a trade.
  The full ETH budget is swapped; excess ETH is not returned as ETH. No oracle is used.
- **Dependencies:** this targets the addresses and exact no-hook pool supplied in the assignment.
  Tests execute the pinned real v4 implementation locally with synthetic liquidity and mock IMD
  and Intake; they are not a mainnet fork or a live liquidity/code/treasury verification.
  IMD is assumed to be an ordinary non-rebasing ERC-20 without transfer taxes. Optional empty
  return values are supported; false returns and balance mismatches revert.
- **Trust:** the owner can redirect future payments to a different Intake or pause all purchases.
  Code presence is checked by `setIntake`, but it cannot prove an endpoint's honesty or ABI.
  The Intake and its writer determine admission, work, delivery, result truth, and payment use.
  A malicious replacement could collect the approved price without doing the work, and a live
  price raised by the Intake operator or a replaced Intake is paid up to the swap output; a
  buyer's `minSurplus` bounds that. Pause followed by `renounceOwnership()` leaves purchases
  paused forever. Run the owner as a multisig and monitor `IntakeChanged` and `ActionChanged`.
- **Custody:** a normal purchase started from empty balances ends with zero ETH and IMD in the
  hub and no purchase funds or approval in the account. Callbacks retain no funds. Unsolicited
  ERC-20 transfers and forced ETH cannot be prevented by an EVM contract. Such pre-existing hub
  balances are not used to subsidize purchases and cannot be recovered by the hub. Buyer-funded
  account balances are preserved by purchases and recoverable only by that buyer.
- **Content:** the words are public on chain and subject to the plane's content and admission
  rules. Input safety prevents closing the JSON string; it does not guarantee the plane accepts
  the requested website. The exact task-specified body was tested byte-for-byte. An attempted
  public preflight at `https://identity.md/requests/check` returned HTTP 404; no live HTTP
  acceptance is claimed. The supplied pinned Intake reference defines the schema used here.
- **Review:** local tests and manual code review are included. No independent security audit,
  Slither run, or Mythril run is claimed. See [validation notes](docs/VALIDATION.md).

## Reproduce the checks

All Solidity dependencies are vendored as ordinary files in `lib/`; no submodule, install step,
network, environment-driven test configuration, FFI, or filesystem permission is needed.
The verifier must provide Foundry and the pinned Solidity compiler, 0.8.26.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x47c3314df5f633c89b34152424c75dd0746ecdfbd9985a406034b3fe476f6e95 forge test
forge fmt --check
```

`foundry.toml` pins Cancun, optimizer runs 200, and `bytecode_hash = "none"`. There are 512 runs
per fuzz test. Sources and tests are at the repository root's `src/` and `test/` paths, and no
submitted test imports the supplied temporary `.imd/reads` inputs or `test/scratch`.

See [dependency provenance and licenses](docs/DEPENDENCIES.md) for exact vendored versions.
