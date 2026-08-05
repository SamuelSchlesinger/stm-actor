# Revision history for stm-actor

## 0.4.0.0 -- UNRELEASED

* Make linking to an already-stopped actor fail reliably rather than silently
  installing an after-effect that can never run.
* Reject `linkSTM` when either endpoint is already stopped.
* Ensure every registered after-effect is attempted even when an earlier effect
  throws an exception.
* Store and drain after-effects explicitly so large callback sets do not build a
  deeply nested function chain.
* Deliver link exceptions from a helper thread so a masked linked actor cannot
  block the dying actor's remaining after-effects.
* Add `await`, `sendChecked`, `trySend`, `addAfterEffectChecked`, and
  `tryAddAfterEffect` lifecycle operations.
* Add opt-in bounded actor mailboxes with transactional backpressure through
  `actBounded` and `actFinallyBounded`.
* Upgrade to `stm-queue-0.2.1` and use its incremental real-time queue for both
  unbounded and bounded mailboxes.
* Add deterministic lifecycle regression tests and bounded test waits.
* Run the concurrency suite with multiple runtime capabilities.
* Validate the oldest compatible dependency plan in CI.
* Test modern GHC releases through GHC 9.14.1.
* Repair the README example and package documentation metadata.
* Set GHC 9.6 (`base-4.18`) as the minimum supported toolchain.

## 0.3.1.1 -- 2024-12-05

* Expand the supported `base` range for newer GHC releases.

## 0.3.1.0 -- 2023-04-20

* Add an `Alternative` instance for `ActionT`.

## 0.3.0.0 -- 2023-01-17

* Update the package for newer compiler and dependency releases.

## 0.1.0.0 -- 2019-06-30

* Initial release.
