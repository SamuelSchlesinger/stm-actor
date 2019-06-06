# stm-actor

Leveraging existential type quantification, software transactional memory, Monad
transformers, and the Haskell do notation, I've built a very simple library for
emulating a subset of the Erlang actor model in Haskell.

```haskell
data Pets = Pets

data LaunchCodes = LaunchCodes

data Message = FireTheMissiles | PetTheDog

action :: Address Pets -> Address LaunchCodes -> ActionT Message IO ()
action dog launcher = do
  msg <- next
  case msg of
    FireTheMissles -> send LaunchCodes launcher
    PetTheDog -> send Pets dog
```

In the above case, if we want to send an address to someone which doesn't allow
them to send any missiles, we can achieve this with the following:

```haskell
data JustPets = JustPets

instance JustPets :-> Message where
  convert JustPets = PetTheDog

action :: Address (Address JustPets) -> ActionT Message IO ()
action addr = do
  pettingAddress <- myAddress
  send pettingAddress addr
  doOtherStuff
```

To spawn actors which perform these actions and wait until they're done,
we can write:

```haskell
main = do
  (addr, result) <- spawnIO (action dogPetter)
  atomically $ readTMVar result
  return ()
```

There are a number of issues with this model and at some point I will describe
them in detail and I am in the process of trying to fix them. At the moment, I am just playing around with
the ideas here after learning some Erlang and I would be open to contributions from others.
In the examples folder, there is a longer example of a supervisor which handles processes
which may or may not fail.
