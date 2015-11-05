main : configure recv send

configure :
	cabal update && cabal install network hashable split random

recv :
	ghc 3700recv.hs

send :
	ghc 3700send.hs

clean :
	rm 3700send 3700recv 3700send.hi 3700send.o 3700recv.hi 3700recv.o TCP.o TCP.hi
