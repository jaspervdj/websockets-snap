websockets-snap
===============

Provides [Snap] integration for the [websockets] library.

This library must be used with the threaded GHC runtime system. You can do this
by using something like this in your cabal file:

    ghc-options: -Wall -threaded -rtsopts "-with-rtsopts=-N"

[Snap]: http://snapframework.com/
[websockets]: http://jaspervdj.be/websockets/
