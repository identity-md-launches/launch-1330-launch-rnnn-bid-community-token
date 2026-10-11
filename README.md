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

What "1% of the swap's IMD amount" means for each swap shape:

| Swap | IMD amount the fee is 1% of | Where it is taken | Who bears it |
| --- | --- | --- | --- |
| Buy, exact input (pay N IMD) | N, the IMD the trader pays | `beforeSwap`, specified-delta | Trader pays N, pool receives 0.99 N |
| Buy, exact output (want M RNNN) | G, the IMD the pool charges for M | `afterSwap`, unspecified-delta | Trader pays G + 0.01 G |
| Sell, exact input (pay M RNNN) | G, the IMD the pool pays out | `afterSwap`, unspecified-delta | Trader receives 0.99 G |
| Sell, exact output (want N IMD) | N, the IMD the trader receives | `beforeSwap`, specified-delta | Pool pays 1.01 N, trader receives N |

Rounding is down (`amount * 100 / 10_000`), so a swap of fewer than 100 wei of IMD pays no fee and
still goes through. The fee is taken on the IMD side only; the hook never holds, takes or receives
RNNN, and never overrides the pool's LP fee.

## How the fee reaches the recipient

Inside `afterSwap` the hook holds a credit of the fee inside the PoolManager and settles it:

1. **Paid in the swap.** If the PoolManager's IMD balance covers the fee, the hook calls
   `poolManager.take(imd, feeRecipient, fee)` and the recipient receives IMD in the same
   transaction. This is the case on every sell and on every buy after the pool has traded once.
2. **Deferred as a claim.** On the first buys into a pool seeded with RNNN only, the manager holds
   no IMD yet (the trader's input is settled after the hook runs, and an ERC-20 transfer from an
   empty manager would revert and take the trade with it). The hook then mints itself an ERC-6909
   claim on IMD for the fee. The swap succeeds and the fee is recorded, not lost.
3. **Flushed.** The next swap that finds enough IMD in the manager pays pending claims to the
   recipient together with its own fee, inside that swap. Independently, anyone may call
   `redeemPendingFees()` at any time; it transfers what the manager's IMD balance covers to the
   recipient and emits `PendingFeesRedeemed`. `pendingFees()` shows the outstanding amount.

Since the fee is an ERC-20 transfer, a recipient that cannot receive ETH is not a concern. A
recipient on an IMD blocklist, if IMD ever had one, would make direct payment revert and halt
fee-bearing swaps; the recipient is a plain address fixed by the brief, so this is noted as an
assumption rather than handled.

Partial fills: when IMD is the specified currency and the trader's price limit stops the swap
early, the fee is 1% of the requested IMD amount, fixed in `beforeSwap`, not of the filled amount.
Routers set the limit to the extreme by default, so ordinary swaps are not affected.

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
  IMD, at any LP fee and tick spacing the initializer chose (12500 and 60 for the launch); refuses
  a pool without IMD. It does not check who initializes, so the launch factory can.
- **`beforeSwap` / `afterSwap`**: PoolManager-only; compute and settle the fee as described.
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

- IMD is a standard ERC-20: transfers move exactly the amount asked, no fee on transfer, no
  blocklist that would include the PoolManager or the recipient. The fee is paid by the PoolManager
  transferring IMD, so a transfer the token refuses would revert the swap.
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
  claims. They flush automatically on the next swap that finds enough IMD in the manager, and anyone
  (the recipient, the community, a keeper) may call `redeemPendingFees()` on the hook to transfer
  them sooner. Watch `pendingFees()` and the `FeeTaken(poolId, amount, paidNow)` events.
- **Other pools.** Anyone may open another IMD pool on this hook; it is charged the same way and the
  fee goes to the same recipient. Pools without IMD are refused.
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

Tests (`test/`), 42 in all, run in any order and read no environment variables:

- `RnnnToken.t.sol`: metadata, supply minted to the deployer, exact transfers, allowances, no admin
  entry point changes the supply, no DELEGATECALL/SELFDESTRUCT in the runtime, fuzzed conservation.
- `RnnnFeeHook.t.sol`: permissions match the address bits; constructor rejects zero addresses and
  wrong-flag addresses; every callback refuses callers other than the PoolManager; unused callbacks
  revert even from the manager; no privileged function exists; pool initialization accepts IMD on
  either side, any listed fee, any caller, and refuses pools without IMD; buy and sell (exact input
  and exact output) each send exactly 1% of the IMD side to the recipient on a funded pool; the fee
  is never taken in RNNN and the LP fee is untouched; on a fresh pool seeded with RNNN only, the
  first buy defers the fee as a claim, anyone redeems it, and the next swap flushes it; redemption
  with nothing pending reverts; four fuzz tests check the 1% exactly across sizes; IMD conservation
  (trader + pool + recipient) holds after every swap.
- `DeployRnnnFeeHook.t.sol`: the script's salt mining lands the hook on an address with the declared
  flags, and an unmined salt reverts.

The protected floor suite (`Hook.protected.t.sol`, `Token.protected.t.sol`) was rehearsed against
the built creation code with the launch's pool terms and passed 11 of 11.
