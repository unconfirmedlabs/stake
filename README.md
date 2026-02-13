# Stake

A generic staking primitive for locking fungible assets on Sui.

## Overview

Stake provides a minimal abstraction for locking balances and attaching extensions. It's designed to be a building block for reward pools, governance systems, access control, and other protocols that require locked positions.

## Design Philosophy

### Immutable Balance

Each `Stake` has a fixed balance set at creation. This ensures correct accounting when a stake is registered to multiple extensions (e.g., multiple reward pools tracking the same position).

To add more tokens, create additional stakes rather than modifying existing ones. This mirrors Sui's native staking model where each validator delegation is a separate `StakedSui` object.

### Multiple Positions

Users can hold multiple `Stake` objects. This enables:

- **Partial withdrawals**: Destroy individual stakes without affecting others
- **Flexible UX**: Frontends can split large deposits into chunks for granular control
- **Independent registration**: Each stake can be registered to different combinations of extensions

### Extension Sandboxing

Extensions attach to stakes via a witness pattern. Each extension module defines a witness type and can only read/write its own config. This prevents unintended coupling—Extension A cannot access Extension B's state, even on the same stake.

### Owned Object Model

`Stake` is an owned object. Possession of `&mut Stake` implies authorization. No capability is required.

If shared access is needed, wrap `Stake` in a shared object with capability-based authorization.

## Architecture

```
┌─────────────────────────────────────────────────┐
│                    Stake<Share>                 │
├─────────────────────────────────────────────────┤
│  balance: Balance<Share>     (immutable)        │
│  extensions: VecSet<TypeName> (tracking)        │
│                                                 │
│  ┌─────────────────┐  ┌─────────────────┐       │
│  │ Extension A     │  │ Extension B     │       │
│  │ (dynamic field) │  │ (dynamic field) │       │
│  │                 │  │                 │       │
│  │ ConfigA { ... } │  │ ConfigB { ... } │       │
│  └─────────────────┘  └─────────────────┘       │
└─────────────────────────────────────────────────┘
```

Extensions are stored as dynamic fields keyed by `ExtensionKey<Extension>`. The `extensions` set tracks which types are attached for enumeration and destroy-time validation.

## Usage

### Creating a Stake

```move
use stake::stake;

let balance = coin::into_balance(coin);
let stake = stake::new(balance, ctx);
transfer::transfer(stake, ctx.sender());
```

### Implementing an Extension

```move
module example::reward_pool;

use stake::stake::{Self, Stake};

/// Witness type - only this module can construct it
public struct RewardPoolExtension has drop {}

/// Config stored on the stake
public struct RewardPoolConfig has store, drop {
    pool_id: ID,
    last_claim_index: u256,
}

/// Register a stake with a reward pool
public fun register<Share>(
    pool: &mut RewardPool<Share>,
    stake: &mut Stake<Share>,
) {
    let config = RewardPoolConfig {
        pool_id: object::id(pool),
        last_claim_index: pool.cumulative_index(),
    };
    stake.add_extension(RewardPoolExtension {}, config);
}

/// Read registration data
public fun get_config<Share>(stake: &Stake<Share>): &RewardPoolConfig {
    stake::borrow_extension(RewardPoolExtension {}, stake)
}

/// Update registration data
public fun update_claim_index<Share>(
    stake: &mut Stake<Share>,
    new_index: u256,
) {
    let config = stake::borrow_extension_mut(RewardPoolExtension {}, stake);
    config.last_claim_index = new_index;
}

/// Unregister from the pool
public fun unregister<Share>(stake: &mut Stake<Share>) {
    let _config = stake::remove_extension<Share, RewardPoolExtension, RewardPoolConfig>();
    // Config is dropped; add cleanup logic here if needed
}
```

### Destroying a Stake

```move
// Must unregister from all extensions first
reward_pool::unregister(&mut stake);
governance::unregister(&mut stake);

// Now destroy and reclaim balance
let balance = stake::destroy(stake);
let coin = coin::from_balance(balance, ctx);
```

## API Reference

### Core Functions

| Function | Description |
|----------|-------------|
| `new<Share>(balance, ctx)` | Create a stake with the given balance |
| `destroy<Share>(stake)` | Destroy stake and return balance (requires no extensions) |

### Extension Functions

| Function | Description |
|----------|-------------|
| `add_extension<S, E, C>(stake, witness, config)` | Attach an extension |
| `borrow_extension<S, E, C>(witness, stake)` | Read extension config |
| `borrow_extension_mut<S, E, C>(witness, stake)` | Modify extension config |
| `remove_extension<S, E, C>(stake)` | Remove and return extension config |

### Accessors

| Function | Description |
|----------|-------------|
| `id<Share>(stake)` | Get stake's object ID |
| `balance<Share>(stake)` | Get reference to staked balance |
| `extensions<Share>(stake)` | Get set of attached extension types |
| `has_extension<S, E>(stake)` | Check if extension type is attached |

## Extension Architecture

Stake uses **isolated Bag storage** rather than exposing raw `&mut UID` to extensions. This is a deliberate choice driven by Stake's role as a generic primitive.

### Why Isolated Storage

Stake is designed to be a building block that any third-party module can extend. The stake owner doesn't control which extensions exist in the ecosystem or how they interact. If extensions received `&mut UID`, a registered extension could read, modify, or remove dynamic fields belonging to other extensions on the same stake — since dynamic field keys like `ExtensionKey<phantom E>` are constructible by any module that knows the type parameter.

Isolated Bag storage makes cross-extension interference structurally impossible. Each extension gets its own `Bag`, and only the module that defines the witness type can access it. This is analogous to Rust's ownership model: rather than handing out `&mut self` to every plugin, each plugin gets `&mut its_own_field`.

### Why Cooperative Removal

Extensions control their own data lifecycle through the Bag. The stake owner can remove an extension only when its storage is empty — the extension module decides when cleanup happens. This prevents two failure modes:

- **Orphaned state**: The owner force-removes an extension that has active registrations (e.g., staked in a reward pool), leaving dangling references.
- **Hostage-taking**: An extension refuses to release a stake, permanently locking the user's funds.

The result is a clean separation — the extension controls its data, the owner controls their stake, and neither party can force the other into an inconsistent state.

### Comparison with Other Models

| Model | UID Access | Isolation | Best For |
|-------|-----------|-----------|----------|
| **Stake (Bag)** | None — extensions get `&mut Bag` | Structural | Generic primitives with untrusted extensions |
| **MusicOS (raw UID)** | `&mut UID` via witness + registration | By convention | Permissionless protocols needing full Sui primitive access |
| **Sona Player (registry)** | `&mut UID` via witness + Settings | By convention | Managed systems with centralized extension control |

## Type Parameters

- `Share`: The fungible token type being staked
- `Extension`: Witness type identifying the extension (must have `drop`)
- `Config`: Data stored for the extension (must have `store + drop`)

The `drop` requirement on `Config` ensures stake owners can always remove extensions, even if the extension module doesn't implement graceful cleanup.

## License

Apache-2.0
