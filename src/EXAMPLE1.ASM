;***********************************************************************
;                        Example to interface the
;                  PKWARE Data Compression Library (TM)
;                                 with
;                           Assembly Language
;          Copyright 1990-1991, By PKWARE Inc.  All Rights Reserved.
;***********************************************************************/


CMP_BINARY equ 0
CMP_ASCII  equ 1

CR equ 0dh
LF equ 0ah

extrn IMPLODE:far
extrn EXPLODE:far

_text segment word public 'CODE'
_text ends


dgroup GROUP _const,_DATA,_bss,_stack
assume ds:dgroup,ss:dgroup


_const SEGMENT byte public 'const'
CR_LF      db CR, LF, '$'
TEST_IN    db 'TEST.IN',0
TEST_CMP   db 'TEST.CMP',0
TEST_EXT   db 'TEST.EXT',0
CANTOPEN   db 'Unable to open input file$'
CANTCREATE db 'Unable to create output file$'
CALLING_I  db 'Imploding file   TEST.IN  => TEST.CMP$'
CALLING_E  db 'Exploding file   TEST.CMP => TEST.EXT$'
DONE_EXP   db 'Done!$'
ERREXT     db 'Error in compressed file!$'
HEADER     db CR,LF,'PKWARE Data Compression Library Example',CR,LF,'$'
_const ends

_DATA SEGMENT word public 'data'
_DATA ends

_bss segment word public 'bss'
_bss ends

comm buffer:byte:35256
comm InHandle:word
comm OutHandle:word
comm Ctype:word
comm Dsize:word

_stack segment para stack 'stack'
x db 2048 dup(?)
_stack ends



_text segment
assume cs:_text

frame struc
  savebp dw ?
  retadr dd ?
  count  dd ?
  Buf    dd ?
frame ends

rotator proc near
   mov   bx, offset ms_rotator
   xor   ax, ax
   mov   al,cs:[bx]
   dec   ax
   jnz   $+4
   mov   al, 6

   mov   cs:[bx], al
   add   bx, ax

   mov   ah, 2
   mov   dl,cs:[bx]
   int   21h
   mov   dl, 08h
   int   21h

   ret
ms_rotator db 6, ">-/|\<"
rotator endp

READDATA proc far
public READDATA

   push bp                              ; save
   mov bp,sp                            ; load ptr to parameters on stack
   push ds                              ; save

   call rotator

   mov ah,3fh                           ; Read from TEST.IN

   les bx,[bp+frame.count]
   mov cx,es:[bx]                       ; Bytes to read

   mov bx,InHandle                      ; Handle
   lds dx,[bp+frame.Buf]                ; Buffer Address
   int 21h

   pop ds                               ; restore
   pop bp                               ; restore

ret 8

READDATA endp


WRITEDATA proc far
public WRITEDATA

   push bp                              ; save
   mov bp,sp                            ; load ptr to parameters on stack
   push ds                              ; save

   call rotator

   mov ah,40h                           ; Write data to TEST.CMP

   les bx,[bp+frame.count]
   mov cx,es:[bx]                       ; Bytes to read

   mov bx,OutHandle                     ; Handle
   lds dx,[bp+frame.Buf]                ; Buffer Address
   int 21h

   pop ds                               ; restore
   pop bp                               ; restore

ret 8

WRITEDATA endp


PrintLine proc near

   mov ah,9
   int 21h

   mov ah,9
   mov dx,offset CR_LF
   int 21h
   ret

PrintLine endp


StartExe:
   mov ax,dgroup
   mov ds,ax
   mov bx,ss
   sub bx,ax
   mov cl,4
   shl bx,cl
   cli
   mov ss,ax
   add sp,bx
   sti

   mov dx,offset dgroup:Header          ; Screen Output
   call PrintLine

   mov ax,3d00h                         ; Open input file
   mov dx,offset dgroup:TEST_IN
   int 21h
   jnc INPUT_OPEN                       ; Error opening file

   mov dx,offset dgroup:CANTOPEN
   call PrintLine
   jmp Exit_To_DOS

INPUT_OPEN:
   mov InHandle,ax                      ; Save handle

   mov ah,3ch                           ; Create destination file
   xor cx,cx                            ; File attribute
   mov dx,offset dgroup:TEST_CMP        ; Filename TEST.CMP
   int 21h
   jnc OUTPUT_OPEN                      ; Error creating

   mov dx,offset dgroup:CANTCREATE      ; Error creating message
   call PrintLine

   mov bx,InHandle
   mov ah,3eh                           ; Close TEST.IN
   int 21h
   jmp Exit_To_DOS

OUTPUT_OPEN:
   mov OutHandle,ax                     ; Save handle

   mov dx,offset dgroup:CALLING_I       ; Screen Output
   call PrintLine

;Call Implode
   mov ax,offset _text:READDATA
   push cs
   push ax
   mov ax,offset _text:WRITEDATA
   push cs
   push ax

   mov ax,offset dgroup:buffer
   push ds
   push ax
;****************************************************
   mov Ctype, 1
   mov ax,offset dgroup:Ctype
   push ds
   push ax

   mov Dsize,4096                       ; 4K Dictionary
   mov ax,offset dgroup:Dsize
   push ds
   push ax

   call IMPLODE

   mov bx,InHandle
   mov ah,3eh                           ; Close input
   int 21h

   mov ah,3eh
   mov bx,OutHandle                     ; Close output
   int 21h

; Done Imploding.  Expand TEST.CMP into TEST.EXT

   mov ax,3d00h                         ; Open input file
   mov dx,offset dgroup:TEST_CMP
   int 21h
   jnc CMP_OPEN                         ; Error opening file

   mov dx,offset dgroup:CANTOPEN
   call PrintLine
   jmp short Exit_To_DOS

CMP_OPEN:
   mov InHandle,ax                      ; Save handle

   mov ah,3ch                           ; Create destination file
   xor cx,cx                            ; File attribute
   mov dx,offset dgroup:TEST_EXT        ; Filename TEST.EXT
   int 21h
   jnc EXT_OPEN                         ; Error creating

   mov dx,offset dgroup:CANTCREATE      ; Error creating message
   call PrintLine

   mov bx,InHandle
   mov ah,3eh                           ; Close input file
   int 21h
   jmp short Exit_To_DOS

EXT_OPEN:
   mov OutHandle,ax                     ; Save handle

   mov dx,offset dgroup:CALLING_E       ; Screen Output
   call PrintLine

;Call Explode
   mov ax,offset _text:READDATA
   push cs
   push ax
   mov ax,offset _text:WRITEDATA
   push cs
   push ax

   mov ax,offset dgroup:buffer
   push ds
   push ax

   call EXPLODE

   push ax                              ; save result

   mov dx,offset dgroup:DONE_EXP        ; Screen Output
   call PrintLine

   pop ax
   test ax,ax
   jz Extract_Ok

   mov dx,offset dgroup:ERREXT
   call PrintLine

Extract_Ok:
   mov bx,InHandle
   mov ah,3eh                           ; Close Input file
   int 21h

   mov ah,3eh
   mov bx,OutHandle                     ; Close Output file
   int 21h

Exit_To_DOS:
   mov ax,4c00h
   int 21h                              ; Exit to DOS

_text ends
end StartExe
