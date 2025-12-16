if not exist example0.obj tasm /m9 /oi example0.asm
if not exist example1.obj tasm /m9 /oi example1.asm

tasm /m9 /a /oi implode.asm

tlink example0.obj implode.obj
tlink example1.obj implode.obj

del example0.map
del example1.map
