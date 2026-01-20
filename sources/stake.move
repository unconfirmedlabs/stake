// Copyright (c) Studio Mirai, LLC
// SPDX-License-Identifier: Apache-2.0

/// A generic staking primitive for locking fungible assets.
///
/// Stake provides a simple model for locking balances and attaching extensions.
/// Each Stake is an independent position with immutable balance - to increase
/// total stake, create additional Stake objects. This mirrors Sui's native
/// staking model where each delegation is a separate `StakedSui` object.
///
/// Extensions are isolated: each extension module can only read/write its own
/// config via a witness pattern. This prevents unintended coupling between
/// extensions operating on the same stake.
///
/// ## Design Principles
///
/// - **Immutable balance**: Set at creation, never modified. Ensures correct
///   accounting when registered to multiple extensions (e.g., reward pools).
/// - **Multiple positions**: Instead of modifying existing stakes, create new ones.
///   Enables partial withdrawals by destroying individual stakes.
/// - **Extension sandboxing**: Witness-gated access ensures extensions operate
///   in isolation without reading or interfering with each other's state.
/// - **Owned object model**: No capability required; object ownership provides
///   authorization. Wrap in a shared object with caps if shared access is needed.
module stake::stake;

use std::type_name::{TypeName, with_defining_ids};
use sui::balance::Balance;
use sui::dynamic_field as df;
use sui::event::emit;
use sui::vec_set::{Self, VecSet};

// === Structs ===

/// A stake position holding a fixed balance of `Share` tokens.
///
/// The balance is immutable after creation. Extensions can be attached
/// to enable functionality like reward distribution or governance.
public struct Stake<phantom Share> has key, store {
    id: UID,
    /// Tracks attached extension types for enumeration and destroy-time validation.
    extensions: VecSet<TypeName>,
    /// The staked balance. Immutable after creation.
    balance: Balance<Share>,
}

/// Dynamic field key for storing extension configs.
public struct ExtensionKey<phantom Extension: drop>() has copy, drop, store;

// === Events ===

/// Emitted when a stake is created.
public struct StakeCreatedEvent has copy, drop {
    stake_id: ID,
    amount: u64,
}

/// Emitted when a stake is destroyed.
public struct StakeDestroyedEvent has copy, drop {
    stake_id: ID,
    amount: u64,
}

/// Emitted when an extension is added to a stake.
public struct ExtensionAddedEvent<phantom Extension: drop> has copy, drop {
    stake_id: ID,
}

/// Emitted when an extension is removed from a stake.
public struct ExtensionRemovedEvent<phantom Extension: drop> has copy, drop {
    stake_id: ID,
}

// === Errors ===

/// Extension of this type is already attached.
const EExtensionAlreadyExists: u64 = 0;
/// Extension of this type is not attached.
const EExtensionNotFound: u64 = 1;
/// Cannot destroy stake with active extensions.
const EExtensionsNotEmpty: u64 = 2;
/// Cannot create stake with zero balance.
const EZeroBalance: u64 = 3;

// === Public Functions ===

/// Create a new stake with the given balance.
///
/// Aborts if `balance` is zero.
public fun new<Share>(balance: Balance<Share>, ctx: &mut TxContext): Stake<Share> {
    assert!(balance.value() > 0, EZeroBalance);

    let stake = Stake {
        id: object::new(ctx),
        extensions: vec_set::empty(),
        balance,
    };

    emit(StakeCreatedEvent {
        stake_id: stake.id(),
        amount: stake.balance.value(),
    });

    stake
}

/// Destroy a stake and reclaim the balance.
///
/// Aborts if any extensions are still attached.
public fun destroy<Share>(stake: Stake<Share>): Balance<Share> {
    let Stake { id, extensions, balance } = stake;

    assert!(extensions.is_empty(), EExtensionsNotEmpty);

    emit(StakeDestroyedEvent {
        stake_id: id.to_inner(),
        amount: balance.value(),
    });

    id.delete();
    balance
}

/// Attach an extension to the stake.
///
/// - `Extension`: Witness type identifying the extension. Only the module
///   defining this type can call extension functions.
/// - `Config`: Data stored for this extension. Requires `drop` so the stake
///   owner can always remove extensions, even without graceful cleanup.
///
/// Aborts if an extension of this type is already attached.
public fun add_extension<Share, Extension: drop, Config: store + drop>(
    self: &mut Stake<Share>,
    _: Extension,
    config: Config,
) {
    let extension_type = with_defining_ids<Extension>();
    assert!(!self.extensions.contains(&extension_type), EExtensionAlreadyExists);

    df::add(&mut self.id, ExtensionKey<Extension>(), config);
    self.extensions.insert(extension_type);

    emit(ExtensionAddedEvent<Extension> {
        stake_id: self.id(),
    });
}

/// Borrow an extension's config immutably.
///
/// Requires the `Extension` witness, ensuring only the extension module
/// can read its own config.
///
/// Aborts if the extension is not attached.
public fun borrow_extension<Share, Extension: drop, Config: store + drop>(
    _: Extension,
    self: &Stake<Share>,
): &Config {
    assert!(has_extension<Share, Extension>(self), EExtensionNotFound);
    df::borrow(&self.id, ExtensionKey<Extension>())
}

/// Borrow an extension's config mutably.
///
/// Requires the `Extension` witness, ensuring only the extension module
/// can modify its own config.
///
/// Aborts if the extension is not attached.
public fun borrow_extension_mut<Share, Extension: drop, Config: store + drop>(
    _: Extension,
    self: &mut Stake<Share>,
): &mut Config {
    assert!(has_extension<Share, Extension>(self), EExtensionNotFound);
    df::borrow_mut(&mut self.id, ExtensionKey<Extension>())
}

/// Remove an extension from the stake and return its config.
///
/// The returned `Config` has `drop`, so callers can discard it if cleanup
/// isn't needed. Extension modules should provide their own unregister
/// functions that perform proper cleanup before calling this.
///
/// Aborts if the extension is not attached.
public fun remove_extension<Share, Extension: drop, Config: store + drop>(
    self: &mut Stake<Share>,
): Config {
    let extension_type = with_defining_ids<Extension>();
    assert!(self.extensions.contains(&extension_type), EExtensionNotFound);

    self.extensions.remove(&extension_type);

    emit(ExtensionRemovedEvent<Extension> {
        stake_id: self.id(),
    });

    df::remove(&mut self.id, ExtensionKey<Extension>())
}

// === Accessors ===

/// Returns the stake's object ID.
public fun id<Share>(self: &Stake<Share>): ID {
    self.id.to_inner()
}

/// Returns a reference to the staked balance.
public fun balance<Share>(self: &Stake<Share>): &Balance<Share> {
    &self.balance
}

/// Returns the set of attached extension types.
public fun extensions<Share>(self: &Stake<Share>): &VecSet<TypeName> {
    &self.extensions
}

/// Check if an extension type is attached.
public fun has_extension<Share, Extension: drop>(self: &Stake<Share>): bool {
    let extension_type = with_defining_ids<Extension>();
    self.extensions.contains(&extension_type)
}
