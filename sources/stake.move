module stake::stake;

use std::type_name::{TypeName, with_defining_ids};
use sui::balance::{Self, Balance};
use sui::dynamic_field as df;
use sui::event::emit;
use sui::vec_set::{Self, VecSet};

//=== Structs ===

public struct Stake<phantom S> has key, store {
    id: UID,
    state: StakeState,
    balance: Balance<S>,
}

public struct StakeExtension<phantom E>() has copy, drop, store;

//=== Enums ===

public enum StakeState has copy, drop, store {
    Unlocked,
    Locked { extensions: VecSet<TypeName> },
}

//=== Events ===

public struct StakeCreatedEvent has copy, drop {
    stake_id: ID,
}

public struct StakeLockedEvent has copy, drop {
    stake_id: ID,
}

public struct StakeUnlockedEvent has copy, drop {
    stake_id: ID,
}

public struct StakeDepositEvent has copy, drop {
    stake_id: ID,
    amount: u64,
}

public struct StakeWithdrawEvent has copy, drop {
    stake_id: ID,
    amount: u64,
}

public struct ExtensionAddedEvent has copy, drop {
    stake_id: ID,
    extension_type: TypeName,
}

public struct ExtensionRemovedEvent has copy, drop {
    stake_id: ID,
    extension_type: TypeName,
}

//=== Errors ===

const ENotUnlocked: u64 = 0;
const ENotLocked: u64 = 1;
const EExtensionsNotEmpty: u64 = 2;
const EExtensionAlreadyExists: u64 = 3;
const EExtensionNotFound: u64 = 4;
const EInsufficientBalance: u64 = 5;

//=== Public Functions ===

public fun new<S>(ctx: &mut TxContext): Stake<S> {
    let stake = Stake {
        id: object::new(ctx),
        state: StakeState::Unlocked,
        balance: balance::zero(),
    };

    emit(StakeCreatedEvent {
        stake_id: stake.id(),
    });

    stake
}

public fun lock<S>(self: &mut Stake<S>) {
    match (&self.state) {
        StakeState::Unlocked => {
            self.state = StakeState::Locked { extensions: vec_set::empty() };

            emit(StakeLockedEvent {
                stake_id: self.id(),
            });
        },
        _ => abort ENotUnlocked,
    }
}

public fun unlock<S>(self: &mut Stake<S>) {
    match (&self.state) {
        StakeState::Locked { extensions } => {
            assert!(extensions.is_empty(), EExtensionsNotEmpty);
            self.state = StakeState::Unlocked;

            emit(StakeUnlockedEvent {
                stake_id: self.id(),
            });
        },
        _ => abort ENotLocked,
    }
}

public fun deposit<S>(self: &mut Stake<S>, balance: Balance<S>) {
    let amount = balance.value();
    self.balance.join(balance);

    emit(StakeDepositEvent {
        stake_id: self.id(),
        amount,
    });
}

public fun withdraw<S>(self: &mut Stake<S>, amount: Option<u64>): Balance<S> {
    match (&self.state) {
        StakeState::Unlocked => {
            let withdraw_amount = amount.destroy_or!(self.balance.value());
            assert!(withdraw_amount <= self.balance.value(), EInsufficientBalance);

            emit(StakeWithdrawEvent {
                stake_id: self.id(),
                amount: withdraw_amount,
            });

            self.balance.split(withdraw_amount)
        },
        _ => abort ENotUnlocked,
    }
}

public fun add_extension<S, E: store>(
    self: &mut Stake<S>,
    extension: E,
) {
    let extension_type = with_defining_ids<E>();

    match (&mut self.state) {
        StakeState::Locked { extensions } => {
            assert!(!extensions.contains(&extension_type), EExtensionAlreadyExists);
            extensions.insert(extension_type);
        },
        _ => abort ENotLocked,
    };

    df::add(&mut self.id, StakeExtension<E>(), extension);

    emit(ExtensionAddedEvent {
        stake_id: self.id(),
        extension_type,
    });
}

public fun borrow_extension<S, E: store>(self: &Stake<S>): &E {
    assert!(has_extension<S, E>(self), EExtensionNotFound);
    df::borrow(&self.id, StakeExtension<E>())
}

public fun borrow_extension_mut<S, E: store>(
    self: &mut Stake<S>,
): &mut E {
    assert!(has_extension<S, E>(self), EExtensionNotFound);
    df::borrow_mut(&mut self.id, StakeExtension<E>())
}

public fun remove_extension<S, E: store>(self: &mut Stake<S>): E {
    let extension_type = with_defining_ids<E>();

    match (&mut self.state) {
        StakeState::Locked { extensions } => {
            assert!(extensions.contains(&extension_type), EExtensionNotFound);
            extensions.remove(&extension_type);
        },
        _ => abort ENotLocked,
    };

    emit(ExtensionRemovedEvent {
        stake_id: self.id(),
        extension_type,
    });

    df::remove(&mut self.id, StakeExtension<E>())
}

public fun has_extension<S, E: store>(self: &Stake<S>): bool {
    df::exists_with_type<StakeExtension<E>, E>(&self.id, StakeExtension<E>())
}

public fun destroy<S>(stake: Stake<S>): Balance<S> {
    let Stake { id, state, balance } = stake;

    match (state) {
        StakeState::Unlocked => {},
        _ => abort ENotUnlocked,
    };

    id.delete();
    balance
}

//=== Public View Functions ===

public fun id<S>(self: &Stake<S>): ID {
    self.id.to_inner()
}

public fun balance<S>(self: &Stake<S>): &Balance<S> {
    &self.balance
}

public fun state<S>(self: &Stake<S>): &StakeState {
    &self.state
}

public fun is_unlocked<S>(self: &Stake<S>): bool {
    match (&self.state) {
        StakeState::Unlocked => true,
        _ => false,
    }
}

public fun is_locked<S>(self: &Stake<S>): bool {
    match (&self.state) {
        StakeState::Locked { .. } => true,
        _ => false,
    }
}

public fun extensions<S>(self: &Stake<S>): &VecSet<TypeName> {
    match (&self.state) {
        StakeState::Locked { extensions } => extensions,
        _ => abort ENotLocked,
    }
}

//=== UID Functions ===

public fun uid<S>(self: &Stake<S>): &UID {
    &self.id
}

public fun uid_mut<S>(self: &mut Stake<S>): &mut UID {
    &mut self.id
}
