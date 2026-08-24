# Revision history for stm-actor

## 0.4.0.0 -- 2026-08-23

* Add `actWith` and `ActorConfig`, which configure the mailbox capacity, the
  completion handler, an `onUndelivered` handler that receives the messages
  still queued when the actor stopped, and an `onEffectFailure` handler that
  is called for each completion effect that throws. `act`, `actBounded`,
  `actFinally`, and `actFinallyBounded` are specialisations.
* Make `addAfterEffect` lifecycle-checked by default, matching `send`; the
  previous unchecked behaviour is available as `addAfterEffectUnchecked`, and
  `addAfterEffectChecked` remains as an alias.
* Add `monitor` and `monitorSTM`, which deliver an actor's completion to the
  monitoring actor's mailbox as an ordinary message instead of an asynchronous
  exception. Monitoring an actor that has already stopped delivers the message
  immediately.
* Add `awaitEffects`, which waits until the completion handler and
  after-effects have finished running.
* Make `murder` a no-op once the actor has stopped, so completion effects are
  not interrupted.
* Document that an actor blocked in `receive` whose handles have all been
  dropped is stopped by the runtime with `BlockedIndefinitelyOnSTM`.
* Add a fan-in throughput benchmark comparing unbounded and bounded mailboxes.

* Make linking to an already-stopped actor fail reliably rather than silently
  installing an after-effect that can never run.
* Reject `linkSTM` when either endpoint is already stopped.
* Ensure every registered after-effect is attempted even when an earlier effect
  throws an exception.
* Store and drain after-effects explicitly so large callback sets do not build a
  deeply nested function chain.
* Deliver link exceptions from a helper thread so a masked linked actor cannot
  block the dying actor's remaining after-effects.
* Initiate link notifications before completion handlers and user after-effects,
  so blocking target cleanup cannot postpone link delivery.
* Make `send` lifecycle-safe so stopped actors cannot accumulate dead-letter
  messages.
* Make `trySend` genuinely non-blocking, with `Sent`, `MailboxFull`, and
  `ActorStopped` results.
* Drain queued messages during actor shutdown so a retained dead actor handle
  does not retain its existing backlog.
* Add `await`, `sendChecked`, `addAfterEffectChecked`, and `tryAddAfterEffect`
  lifecycle operations.
* Add opt-in bounded actor mailboxes with transactional backpressure through
  `actBounded` and `actFinallyBounded`.
* Use `stm-queue`'s incremental real-time queue for unbounded and bounded
  mailboxes. Bounded mailboxes are `stm-queue-0.2.2`'s bounded queues, whose
  split read and write credits let senders and the actor conflict on
  capacity accounting once per `capacity` sends rather than on every message.
* Require `stm-queue >= 0.2.2.0`.
* Add deterministic lifecycle regression tests and bounded test waits.
* Run the concurrency suite with multiple runtime capabilities.
* Validate the oldest compatible dependency plan in CI.
* Test modern GHC releases through GHC 9.14.1.
* Repair the README example and package documentation metadata.
* Rebuild the generated source distribution in CI outside the development
  project so unpublished dependency pins cannot hide release failures.
* Set GHC 9.6 (`base-4.18`) as the minimum supported toolchain.

## 0.3.1.1 -- 2024-12-05

* Expand the supported `base` range for newer GHC releases.

## 0.3.1.0 -- 2023-04-20

* Add an `Alternative` instance for `ActionT`.

## 0.3.0.0 -- 2023-01-17

* Update the package for newer compiler and dependency releases.

## 0.1.0.0 -- 2019-06-30

* Initial release.
