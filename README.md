# rnnn.bid (RNNN) launch: token and 1% IMD fee hook

Foundry project for the rnnn.bid community token and its Uniswap v4 hook on Robinhood Chain
(chain id 4663), paired with IMD.

| Contract | File | Role |
| --- | --- | --- |
| `RnnnToken` | `src/RnnnToken.sol` | The launch token: name `rnnn.bid`, symbol `RNNN`, 18 decimals, 1,000,000,000 tokens minted once to the deployer. |
| `RnnnFeeHook` | `src/RnnnFeeHook.sol` | The pool's hook. One rule: 1% of every swap's IMD amount goes, as IMD, to the fixed fee recipient. |
| `HookFlags` | `src/HookFlags.sol` | Internal library with the v4 permission bits and address checks (used by tests and the script). |
| `DeployRnnnFeeHook` | `script/DeployRnnnFeeHook.s.sol` | Manual deployment path with salt mining; not used by the IMD launch factory. |

## The one rule

On every swap in a pool this hook serves, the hook takes 1% of the swap's IMD amount and transfers
it as IMD to `0x45C89d0CF0B8a05218506236FcfcB18DA1D3ebE4`. Nothing is swapped, sold or converted.
The recipient is a constructor argument stored in an `immutable`; there is no setter, no owner, no
pause, no mint, no other fee and no way to block or alter a swap beyond that 1%.

What "1% of the swap's IMD amount" means for each swap shape, when the pool fills the request:

| Swap | IMD amount the fee is 1% of | Where it is taken | Who bears it |
| --- | --- | --- | --- |
| Buy, exact input (pay N IMD) | N, the IMD the trader pays | `beforeSwap`, specified-delta | Trader pays N, pool receives 0.99 N |
| Buy, exact output (want M RNNN) | G, the IMD the pool charges for M | `afterSwap`, unspecified-delta | Trader pays G + 0.01 G |
| Sell, exact input (pay M RNNN) | G, the IMD the pool pays out | `afterSwap`, unspecified-delta | Trader receives 0.99 G |
| Sell, exact output (want N IMD) | N, the IMD the trader receives | `beforeSwap`, specified-delta | Pool pays 1.01 N, trader receives N |

The base is deliberate and the same in every row: 1% of the IMD figure the swap is denominated in
when the trader specifies IMD, and 1% of the IMD the pool computes otherwise. On an exact-input buy
that is 1% of what the trader pays, which is 1.0101% of what the pool receives; on an exact-output
buy it is exactly 1% of what the pool receives. Both are what the tests assert.

**Short fills.** A swap can move less IMD than requested: the trader set a price limit the pool
reaches first, or liquidity in that direction runs out (on the launch pool, seeded with RNNN only,
nothing can be sold before the first buy). The fee is then 1% of the IMD the pool actually moved,
and a swap that moves no IMD pays nothing: the pool's delta and the trader's balances are exactly
what they would be without a hook, less 1% of the IMD side. For the two shapes where IMD is the
specified currency the hook has to commit its delta before the pool runs, so `beforeSwap` first
simulates the swap (see "How the fee is computed" below) and charges on the simulated fill.

Rounding is down (`amount * 100 / 10_000`), so a swap of fewer than 100 wei of IMD pays no fee and
still goes through. The fee is taken on the IMD side only; the hook never holds, takes or receives
RNNN, and never overrides the pool's LP fee.

## How the fee is computed

- **IMD unspecified** (exact-output buy, exact-input sell): `afterSwap` reads the IMD component of
  the pool's delta, takes 1% of it and returns it as the unspecified-currency delta. Whatever the
  pool filled, the fee is 1% of that.
- **IMD specified** (exact-input buy, exact-output sell): only `beforeSwapReturnDelta` can touch
  the specified currency, and it runs before the pool does. `beforeSwap` therefore calls
  `simulateSwap` on itself. That function runs `poolManager.swap` with the amount the pool would
  trade on a full fill (the request less the 1% on a buy, plus the 1% on a sell) and always reverts,
  carrying the resulting delta out as revert data, so nothing it touched persists. The hook is the
  swapper in that inner call, and the PoolManager skips a hook's own callbacks for its own swaps
  (`Hooks.beforeSwap` / `afterSwap` return early when `msg.sender == hook`), so the simulation is a
  plain pool swap with no fee logic in it. If the simulated swap moved the full amount, the fee is
  1% of the request; otherwise the pool stopped early at the trader's limit or the end of
  liquidity, the real swap moves the same amount whatever the fee deducted, and the fee is 1% of
  that amount. `beforeSwap` keeps the fee in transient storage; `afterSwap` reads and clears it, so
  the two always agree and the hook's delta nets to zero. If the simulated swap reverts for a reason
  of its own (a price limit already exceeded, for one) that revert is passed through unchanged: the
  real swap would have failed the same way.
- `simulateSwap` can be called only by the hook itself (`NotSelf` otherwise) and never completes,
  so it is not an administrative entry point: no caller can make it do anything.
- Cost: an IMD-specified swap runs the pool's swap math twice, so it costs roughly the pool's
  swap gas again on top of a hookless swap. The IMD-unspecified shapes pay no such overhead.

## How the fee reaches the recipient

Inside `afterSwap` the hook holds a credit of the fee inside the PoolManager and settles it:

1. **Paid in the swap.** If the IMD the PoolManager holds *at that moment* covers the fee, the hook
   calls `poolManager.take(imd, feeRecipient, fee)` and the recipient receives IMD in the same
   transaction. The swap's own input is not in the manager yet when `afterSwap` runs (routers settle
   after the hook), so the condition is met on every sell (the manager holds the IMD it is paying
   out), and on a buy only when the manager already holds at least the fee in IMD from earlier
   trades and liquidity. On the launch pool, seeded with RNNN only, the manager starts with no IMD:
   the first buys, and any later buy whose 1% exceeds the IMD then in the manager, are deferred.
2. **Deferred as a claim.** When the manager's IMD does not cover the fee, or when the IMD token
   refuses the transfer to the recipient (see below), the hook mints itself an ERC-6909 claim on
   IMD for the fee. The swap succeeds and the fee is recorded, not lost. `FeeTaken(poolId, amount,
   paidNow)` says which of the two happened.
3. **Flushed.** The next swap that finds enough IMD in the manager pays pending claims to the
   recipient together with its own fee, inside that swap. Independently, anyone may call
   `redeemPendingFees()` at any time; it transfers what the manager's IMD balance covers to the
   recipient and emits `PendingFeesRedeemed`. `pendingFees()` shows the outstanding amount.

Since the fee is an ERC-20 transfer, a recipient that cannot receive ETH is not a concern.

**IMD's blocklist.** The live IMD on Robinhood Chain (`0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`)
is an owner-controlled token: it answers `owner()`, `transfersEnabled()` (true at the time of
writing) and `blocked(address)` (false for the recipient at the time of writing), and the recipient
address holds code. Read from the chain's public RPC on 2026-10-11. If IMD's admin ever blocks the
recipient, the direct `take` inside the swap reverts; the hook catches that and defers the fee as a
claim instead, so trading continues and the fee accrues. Claims cannot be redeemed while the
recipient is blocked (`redeemPendingFees` fails with the token's error) and are paid out, by the
next swap or by anyone calling `redeemPendingFees()`, once it is unblocked. If IMD's admin disables
transfers altogether, swaps themselves cannot settle and trading stops regardless of this hook. The
same catch means a caller who starves the inner transfer of gas only turns a direct payment into a
claim; the fee is still owed and redeemable.

## Hook configuration (Wizard canonical shape)

```json
{
  "hook": "BaseHook",
  "name": "RnnnFeeHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": true,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterAddLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": true,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": true,
    "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "none",
  "info": { "license": "MIT" }
}
```

Address flags: `0x20CC` (8396), that is `BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP |
BEFORE_SWAP_RETURN_DELTA | AFTER_SWAP_RETURN_DELTA`. The hook is written directly against the
v4-core interfaces (the current v4-periphery no longer ships `BaseHook`); it validates its own
address bits in the constructor, so a deployment at an address without exactly these bits reverts.
`access` is "none" on purpose: the brief forbids an owner. `beforeSwapReturnDelta` is enabled
because an exact-input buy and an exact-output sell specify IMD, and only the before-swap delta can
touch the specified side. It never no-ops a swap: the delta is always exactly the 1% fee, and
`PoolManager` reverts if a hook delta ever flipped the swap direction.

Key sections of `src/RnnnFeeHook.sol`:

- **Constructor** `(IPoolManager poolManager, address imd, address feeRecipient)`: stores three
  immutables, rejects zero addresses, validates the address bits. It calls no other contract.
- **`getHookPermissions`**: the five permissions above.
- **`beforeInitialize`**: PoolManager-only; admits any pool whose `currency0` or `currency1` is
  IMD, at any static LP fee and tick spacing the initializer chose (12500 and 60 for the launch);
  refuses a pool without IMD and a dynamic-fee pool (the hook never sets an LP fee, so such a pool
  would trade at 0 LP fee forever). It does not check who initializes, so the launch factory can.
- **`beforeSwap` / `afterSwap`**: PoolManager-only; compute and settle the fee as described.
- **`simulateSwap`**: self-only, always reverts; the swap simulation `beforeSwap` relies on.
- **`redeemPendingFees` / `unlockCallback`**: permissionless redemption of deferred fees; the
  callback accepts only the PoolManager and re-reads the amount rather than trusting calldata.
- Unused callbacks revert with `HookNotImplemented` (and are never called: their bits are unset).

## Launch parameters and assumptions

Decided by the launch and used as given:

- Chain: Robinhood Chain, chain id 4663.
- Pair: IMD, `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` (18 decimals).
- LP fee 12500 (1.25%), tick spacing 60. The hook's 1% is on top of the LP fee.
- Supply 1,000,000,000 RNNN minted to the factory; the factory splits it (10% distributor, 80% pool,
  10% payer). No contract here is allocated any of it.
- Owner `0xe8238EE50535F26b290Bb919B2b149B9808B11a6`: not used. Neither contract has an owner or
  any admin argument, as the brief requires.

Constructor arguments the manifest step fills for `RnnnFeeHook`, in order:

| Argument | Value |
| --- | --- |
| `poolManager` | `$poolManager` (the chain's Uniswap v4 PoolManager; never hardcoded) |
| `imd` | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` (IMD on Robinhood Chain) |
| `feeRecipient` | `0x45C89d0CF0B8a05218506236FcfcB18DA1D3ebE4` (fixed by the brief) |

`RnnnToken` takes no constructor arguments.

Assumptions:

- IMD transfers move exactly the amount asked, with no fee on transfer. IMD is owner-controlled and
  has a blocklist and a transfer switch (verified on chain, see "IMD's blocklist" above). A blocked
  recipient defers fees as claims and does not stop trading; a blocked PoolManager or disabled
  transfers stop every swap in the pool, hook or no hook.
- The recipient address is the one the brief gives. It receives IMD only; no ETH or RNNN.
- The hook is deployed by CREATE2 at an address carrying flags `0x20CC`. The factory mines the salt.
- The brief's instruction that the fee "cannot be swapped for ETH" is followed literally: this hook
  departs from the IMD default of settling hook fees in ETH, on the requester's explicit
  instruction, and holds nothing in any token between swaps except deferred claims on IMD.

What the brief asked that the token does not do: nothing. The token is standard and fee-free; the
only requested behaviour, the 1% IMD fee, lives in the hook.

## Operational responsibilities

- **Nobody administers the hook.** There is no key to keep, rotate or hand to a multisig.
- **Pending fees.** After the launch, the first buys into the RNNN-only pool defer their fee as
  claims, and so does any buy whose fee exceeds the IMD the manager holds at the time. They flush
  automatically on the next swap that finds enough IMD in the manager, and anyone (the recipient,
  the community, a keeper) may call `redeemPendingFees()` on the hook to transfer them sooner.
  Watch `pendingFees()` and the `FeeTaken(poolId, amount, paidNow)` events. If `pendingFees()`
  keeps growing while the manager holds IMD, check `blocked(recipient)` on the IMD token.
- **Other pools.** Anyone may open another IMD pool on this hook; it is charged the same way and the
  fee goes to the same recipient. Pools without IMD and dynamic-fee pools are refused.
- **Explorer verification and the fork rehearsal** of the live pool (seed, trade both ways) belong
  to the network's deployer and the launch policy; this repository does not deploy or broadcast.
- **Security.** Tests passing is not an audit. The hook enables `beforeSwapReturnDelta`, which the
  v4 security guide rates critical; an independent adversarial review before release is recommended.
  Slither and Mythril were not run here (not provided in this environment); `forge test` with fuzzing
  was.

## Building and testing

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, `bytecode_hash = "none"`,
optimizer on with 200 runs, no `via_ir`, no `ffi`, no filesystem permissions. Dependencies are
vendored as plain files under `lib/` (no submodules): v4-core (`src/`, `test/utils/CurrencySettler.sol`),
forge-std, and solmate's `Owned.sol` that v4-core's `ProtocolFees` imports. Each `lib/*/VENDORED.md`
records the source commit.

Tests (`test/`), 57 in all, run in any order and read no environment variables:

- `RnnnToken.t.sol`: metadata, supply minted to the deployer, exact transfers, allowances, no admin
  entry point changes the supply, no DELEGATECALL/SELFDESTRUCT in the runtime, fuzzed conservation.
- `RnnnFeeHook.t.sol`: permissions match the address bits; constructor rejects zero addresses and
  wrong-flag addresses; every callback refuses callers other than the PoolManager; `simulateSwap`
  refuses everyone but the hook; unused callbacks revert even from the manager; no privileged
  function exists; pool initialization accepts IMD on either side, any listed fee, any caller, and
  refuses pools without IMD and dynamic-fee pools; buy and sell (exact input and exact output) each
  send exactly 1% of the IMD side to the recipient on a funded pool; the fee is never taken in RNNN
  and the LP fee is untouched; on a fresh pool seeded with RNNN only, the first buy defers the fee
  as a claim, anyone redeems it, the next swap flushes it, and a later buy larger than the manager's
  IMD is deferred too; short fills (price-limited exact-input buys on funded and RNNN-only pools,
  price-limited exact-output sells, an exact-output sell that fills nothing) pay 1% of the IMD the
  pool moved and nothing when it moved none, with the pool ending exactly at the limit; an enormous
  exact input with a limit fills exactly as on a hookless pool; an exceeded limit reverts as on a
  hookless pool; redemption with nothing pending reverts; six fuzz tests check the 1% exactly across
  sizes and limits; IMD conservation (trader + pool + recipient) holds after every swap.
- `RnnnFeeHookBlocklist.t.sol`: with a blocklisted stand-in for IMD, blocking the recipient leaves
  buys and sells executing with fees deferred as claims, redemption fails while blocked and pays
  every deferred fee once unblocked, and later swaps leave claims pending until then.
- `DeployRnnnFeeHook.t.sol`: the script's salt mining lands the hook on an address with the declared
  flags, and an unmined salt reverts.

The protected floor suite (`Hook.protected.t.sol`, `Token.protected.t.sol`) was rehearsed against
the built creation code with the launch's pool terms and passed.
