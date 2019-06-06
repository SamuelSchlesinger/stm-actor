# stm-actor

Leveraging existential type quantification, software transactional memory, Monad
transformers, and the Haskell do notation, I've built a very simple library for
emulating a subset of the Erlang actor model in Haskell.

```haskell
data Pets = Pets

data LaunchCodes = LaunchCodes

data Message = FireTheMissiles | PetTheDog

actor :: Address Pets -> Address LaunchCodes -> ActionT Message IO ()
actor dog launcher = do
  msg <- next
  case msg of
    FireTheMissles -> send LaunchCodes launcher
    PetTheDog -> send Pets dog
```

In the example folder, Main.hs contains an example of a supervisor written in
our model.
