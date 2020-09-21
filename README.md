# stm-actor

[![Hackage](https://img.shields.io/hackage/v/stm-actor.svg)](https://hackage.haskell.org/package/stm-actor)
[![Build Status](https://travis-ci.org/SamuelSchlesinger/stm-actor.svg?branch=master)](https://travis-ci.org/SamuelSchlesinger/stm-actor)

An implementation of a basic actor model in Haskell. With a very simple API,
this is meant to serve as a basis for writing simple, message-passing style
of programs. If you want multi-node actors or you care about throughput, this
is not the package for you. The design is optimized to have low latency on
message receipt, and to allow for interactions between in transactions, using
Haskell's software transactional memory.
