# stm-actor

[![Hackage](https://img.shields.io/hackage/v/stm-actor.svg)](https://hackage.haskell.org/package/stm-actor)

`stm-actor` provides lightweight, process-local actors with transactional
mailboxes. It is designed for small concurrent programs that benefit from
composing message sends with other STM state.

```haskell
import Control.Concurrent.Actor
import Control.Concurrent.STM (atomically)
import Control.Monad.IO.Class (liftIO)

main :: IO ()
main = do
  logger <- act $ receive $ \message -> liftIO (putStrLn message)
  atomically $ send logger "hello from an actor"
  print =<< atomically (await logger)
```

The example prints the message and then `Completed`. An `ActionT message IO a`
runs in its own lightweight thread; its `Actor message` handle can be shared
with other threads and actors.

## Mailboxes and sending

`act` and `actFinally` create an unbounded FIFO mailbox. `actBounded capacity`
and `actFinallyBounded capacity` instead create a bounded FIFO mailbox. All
four are specialisations of `actWith`, which takes an `ActorConfig` describing
the mailbox capacity and the handlers run when the actor stops. Both kinds of
mailbox use `stm-queue`'s incremental-rotation real-time queue. Bounded mailboxes
add transactional occupancy accounting, keeping compatibility with the
published `stm-queue-0.2.0.0`. Sending and lifecycle operations are STM
transactions, so they can be combined atomically with application state. A
committed `send` means that the actor was alive at that transaction's
linearization point; it does not promise that the actor will eventually process
the message.

Here, “real-time” describes the queue algorithm's bounded structural work per
operation. It is not a hard wall-clock scheduling guarantee from GHC or STM.

A send to a full bounded mailbox retries, applying backpressure without
blocking an operating-system thread and composing normally with `orElse`.
When retrying is undesirable, `trySend` reports both capacity and lifecycle
without blocking:

```haskell
result <- atomically (trySend worker message)
case result of
  Sent -> messageAccepted
  MailboxFull -> handleBackpressure
  ActorStopped reason -> handleShutdown reason
```

The capacity counts queued messages, not the message currently being handled.
A capacity of zero admits no sends. `send` and `sendChecked` wake and reject
when a full actor stops.

Choose the sending operation based on how the caller handles lifecycle races:

| Operation | Actor already stopped | Live bounded mailbox full |
| --- | --- | --- |
| `send actor message` | Throws `ActorDead` | Retries |
| `sendChecked actor message` | Throws `ActorDead` | Retries |
| `trySend actor message` | Returns `ActorStopped` | Returns `MailboxFull` |

`trySend` returns `Sent` after enqueueing and never retries because of capacity.
Actor shutdown drains messages which were already queued and hands them, in
mailbox order, to the `onUndelivered` handler of the actor's `ActorConfig`:

```haskell
worker <- actWith defaultActorConfig
  { mailboxCapacity = Just 256
  , onUndelivered = mapM_ requeueElsewhere
  }
  workerLoop
```

The default handler discards these messages. Messages already dequeued are not
included, even if cancellation interrupts the actor before or during their
handler. Applications that require processing guarantees need acknowledgements.

`receive` removes one message and then runs its handler. `receiveSTM` combines
mailbox removal and a caller-supplied STM action in one transaction, so either
both commit or both roll back.

## Lifecycle and completion effects

An actor transitions exactly once from `Alive` to either `Completed` or
`ThrewException`. `livenessCheck` reads the current state without blocking;
`await` retries in STM until the action has stopped, so it composes with other
transactions without polling.

The transition also closes after-effect registration. A registration racing
completion is therefore either committed and later run, or rejected; it is
never silently lost. As with sending, three registration modes are available:

| Operation | Result if the actor has already stopped |
| --- | --- |
| `addAfterEffect` | Throws `ActorDead` in STM |
| `tryAddAfterEffect` | Returns `False` without registering |
| `addAfterEffectUnchecked` | Registers without checking; the effect cannot run |

After the lifecycle transition, queued messages are drained and link
notifications are initiated. The completion handler then runs, followed
by `onUndelivered` if any messages were queued, and then registered
after-effects in registration order. Every effect is attempted even if an
earlier one throws: each failure is passed to the `onEffectFailure` handler,
which by default rethrows, so after draining the list the first exception is
re-thrown in the actor's terminating thread. Supply a logging handler to keep
effect failures out of the default uncaught-exception output. User effects run
sequentially, so a blocking effect delays later user effects.

`await` returns after the actor's action result has been recorded and
registration has closed. Completion handlers and after-effects may still be
running, and their failures do not change the recorded `Liveness` result;
`awaitEffects` additionally waits until every effect has finished.

## Links and cancellation

`link target`, called inside an actor, establishes a one-way link: when `target`
stops normally or exceptionally, the calling actor receives `LinkKill`.
Link delivery is initiated at the target's lifecycle transition, before its
completion handler and user after-effects, so blocking cleanup does not postpone
the notification. `linkSTM recipient target` provides the same operation
directly in STM. A late `linkSTM` throws `ActorDead` if either endpoint has
already stopped; `link` translates a stopped-target race into an immediate
`LinkKill`.

Link delivery happens in a helper thread. This prevents a recipient that masks
asynchronous exceptions from blocking the target's completion effects. The
helper itself can remain blocked while the recipient uses
`uninterruptibleMask`.

Links interrupt the recipient, which suits cancellation. Use `await` to
observe an actor's completion in STM without interrupting another actor.

`murder` requests cancellation by synchronously using `throwTo` with a
`MurderKill` exception. Like any synchronous `throwTo`, it can block while the
target is uninterruptibly masking asynchronous exceptions. Once the actor has
stopped, `murder` does nothing, so completion effects are not interrupted.

An actor blocked in `receive` whose mailbox is no longer reachable from any
other thread can never receive another message. The runtime detects this at
the next major garbage collection and throws `BlockedIndefinitelyOnSTM` to the
actor, which stops with `ThrewException` and runs its links and
completion effects like any other failure. Dropping every handle to an actor
therefore reclaims it, but the failure cascades through links.

## Scope and compatibility

This package deliberately does not provide distributed actors, durable
mailboxes, supervision trees, or automatic restart. Unbounded actors still
require applications to control producer rates; bounded actors provide
transactional backpressure but no priority, dropping, or dynamic resizing.

The supported compiler range is GHC 9.6 through GHC 9.14. The CI matrix builds
with warnings treated as errors, runs the tests with two runtime capabilities,
validates the oldest compatible dependency plan, and checks Haddock and the
source distribution on the newest compiler.

### Upgrading from 0.3.1.1

Version 0.4 retains the existing function signatures but changes lifecycle
behavior. It also raises the minimum compiler version to GHC 9.6.

- `send` and `addAfterEffect` now throw `ActorDead` when the actor has stopped.
  Use `trySend` and `tryAddAfterEffect` when shutdown is an expected outcome.
  `addAfterEffectUnchecked` retains the old registration behavior, including
  retaining an effect that cannot run if registered after completion.
- Linking to a stopped actor now fails promptly. Link notifications begin
  before completion handlers and user after-effects; do not rely on cleanup
  finishing before a linked actor is interrupted.
- All registered after-effects are attempted even if an earlier effect throws.
  They still run in registration order. Use `onEffectFailure` to handle errors.
- `murder` does nothing after the actor's action has stopped. Use `awaitEffects`
  to wait for cleanup; `await` and `livenessCheck` only observe the action's
  result. Neither message admission nor cleanup provides exactly-once processing.

For local development:

```console
cabal build --enable-tests all
cabal test all --test-options='+RTS -N2 -RTS'
cabal haddock all
cabal check
```
