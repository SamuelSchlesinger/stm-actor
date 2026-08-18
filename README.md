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
and `actFinallyBounded capacity` instead create a bounded FIFO mailbox. Both
use `stm-queue`'s incremental-rotation real-time queue; bounded mailboxes add
transactional occupancy accounting. Sending and lifecycle operations are STM
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
Actor shutdown drains messages which were already queued.

`receive` removes one message and then runs its handler. `receiveSTM` combines
mailbox removal and a caller-supplied STM action in one transaction, so either
both commit or both roll back.

## Lifecycle and completion effects

An actor transitions exactly once from `Alive` to either `Completed` or
`ThrewException`. `livenessCheck` reads the current state without blocking;
`await` retries in STM until the action has stopped, so it composes with other
transactions without polling.

The transition also closes checked after-effect registration. A registration
racing completion is therefore either committed and later run, or rejected;
it is never silently lost. As with sending, three registration modes are
available:

| Operation | Result if the actor has already stopped |
| --- | --- |
| `addAfterEffect` | Registers unchecked; the effect cannot run |
| `addAfterEffectChecked` | Throws `ActorDead` in STM |
| `tryAddAfterEffect` | Returns `False` without registering |

After the lifecycle transition, queued messages are drained and link
notifications are initiated. The completion handler passed to `actFinally`
then runs, followed by registered after-effects in registration order. Every
effect is attempted even if an earlier one throws; after draining the list, the
first effect exception is re-thrown in the actor's terminating thread. User
effects run sequentially, so a blocking effect delays later user effects.

`await` returns after the actor's action result has been recorded and checked
registration has closed. Completion handlers and after-effects may still be
running, and their failures do not change the recorded `Liveness` result.

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

`murder` requests cancellation by synchronously using `throwTo` with a
`MurderKill` exception. Like any synchronous `throwTo`, it can block while the
target is uninterruptibly masking asynchronous exceptions.

## Scope and compatibility

This package deliberately does not provide distributed actors, durable
mailboxes, supervision trees, or automatic restart. Unbounded actors still
require applications to control producer rates; bounded actors provide
transactional backpressure but no priority, dropping, or dynamic resizing.

The supported compiler range is GHC 9.6 through GHC 9.14. The CI matrix builds
with warnings treated as errors, runs the tests with two runtime capabilities,
validates the oldest compatible dependency plan, and checks Haddock and the
source distribution on the newest compiler.

For local development:

```console
cabal build --enable-tests all
cabal test all --test-options='+RTS -N2 -RTS'
cabal haddock all
cabal check
```
