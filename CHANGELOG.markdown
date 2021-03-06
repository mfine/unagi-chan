### 0.1.1.0

- support new criterion and GHC 7.8.3
- small performance improvement to boxed unagi

### 0.2.0.0

- implement a bounded variant (See issue #1)
- address issue with stale tickets when running in GHCi

### 0.2.0.1

- conditionally use tryReadMVar (as before) when GHC >= 7.8.3
- set proper CPP flags when running tests

### 0.3.0.0

- fixed build on GHC 7.6 (thanks @Noeda)
- `Unagi.Unboxed` is now polymorphic in a new `UnagiPrim` class, which permits an optimization; defined instances are the same
- add new NoBlocking variants with reads that don't block, omiting some overhead
    - these have a new `Stream` interface for reads with even lower overhead
- revisited memory barriers in light of https://github.com/rrnewton/haskell-lockfree/issues/39, and document them better
- Added `tryReadChan` functions to all variants
- get rid of upper bounds on `atomic-primops`

### 0.3.0.1

- fix upper bounds on atomic-primops again (made as revision to cabal metadata for 0.3.0.0
- fix some docs

### 0.3.0.2

- re-bump atomic-primops version; should now support 7.10
- fix missing other-modules for test suite
- fix getChanContents for GHC 7.10 (see GHC Trac #9965) 

### 0.4.0.0

- `tryReadChan` now returns an `(Element a, IO a)` tuple, where the `snd` is a blocking read action 
- depend atomic-primops >= 0.8
