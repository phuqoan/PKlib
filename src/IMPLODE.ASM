; ==========================================================================
; PKlib contains x86 16-bit Assembly sources for the PKWARE-style data compression library (Implode/Explode) and
;       example programs demonstrating how to call the compression/decompression routines from assembly.
;       These are historical sources (circa early 1990s) intended as reference or for educational use.
;       They may require adaptation for modern assemblers or environments.
;       Copyright (c) 1990-1993 PKWARE, Inc.   All Rights Reserved.
;       PKWARE is a registered trademark of PKWARE, Inc.
;       This source code is provided "as is" without express or implied warranty of any kind.
;       Code optimizations by Phuqoan, 2022.
; ==========================================================================

ifdef   ??version
locals  @@
endif

; --- Error Codes ---
CMP_INVALID_DICTSIZE = 1        ; Error: The provided dictionary size is not supported (not 1024, 2048, or 4096)
CMP_INVALID_MODE = 2            ; Error: The provided compression type is not supported (not 0 or 1)
CMP_BAD_DATA    = 3             ; Error: The compressed data is corrupt
CMP_ABORT       = 4             ; Error: Decompression was aborted (e.g., write error)

; --- Constants ---
h_204           equ 204h        ; Hex 204h = 516. Used as max repetition length + 2.
h_306           equ 306h        ; Hex 306h = 774. Used as a special error/stop code.

d_2048          equ 2048        ; 2KB, used for buffer sizes
d_2304          equ 2304        ; 2304 = 2KB + 256, used for hash table size
d_4096          equ 4096

; This structure holds all the data and state for a COMPRESSION operation.
sCOM    struc                   ; Compression workspace

distance dw     ?               ; Backward distance of the currently found repetition, decreased by 1.
out_bytes dw    ?               ; Number of bytes currently used in out_buf.
out_bits dw     ?               ; Number of bits used in the *last* byte of out_buf (0-7).
dictsize_bits dw ?              ; Number of bits needed to represent the dictionary size (4=1KB, 5=2KB, 6=4KB).
dictsize_mask dw ?              ; Bit mask for the dictionary offset (e.g., 0x3FF for 1KB, 0x7FF for 2KB).
ctype   dw      ?               ; Compression type: 0 for binary, 1 for ASCII.
dictsize_bytes dw ?             ; Dictionary size in bytes (1024, 2048, or 4096).

; --- Huffman-like encoding tables for compression ---
; These are built at initialization.

; Table of bit lengths for distances (64 entries)
dist_bits db    64 dup(?)
; Table of codes for distances (64 entries)
dist_codes db   64 dup(?)

; Table of bit lengths for literals (0-255) and lengths (256-772)
nChBits db      h_306 dup(?)    ; Bit lengths for literals

; Table of codes for literals (0-255) and lengths (256-772)
nChCodes dw     h_306 dup(?)    ; Codes for literals

; --- I/O Function Pointers ---
COMread dd      ?               ; Pointer to function to read a block of data. (in: buffer, size; ret: ax=bytes_read)
COMwrite dd     ?               ; Pointer to function to write a block of data. (in: buffer, size)

; --- Buffers ---
phash_to_index dw d_2304 dup(?) ; Hash table for string matching. Maps 2-byte hash to an offset in phash_offs.
	dw      ?               ; Padding/undefined.
out_buf db      d_2048 dup(?)   ; Primary output buffer (2KB) for compressed data.
	dw      ?               ; Buffer to hold overflow bytes when flushing out_buf.
work_buff db    h_204 dup(?)    ; Work buffer used in compression (related to h_204)
phash_offs db   8192 dup(?)     ; Sliding window buffer (dictionary + lookahead). Max size (4KB dict + 4KB lookahead).

sCOM    ends


; This structure holds all the data and state for a DECOMPRESSION operation.
sDEC    struc                   ; Decompression workspace
c_type  dw      ?               ; Compression type read from header.
outpos  dw      ?               ; Current position in the output circular buffer (outbuff).
dsizebits dw    ?               ; Dictionary size bits from header (4, 5, or 6).
dsizemask dw    ?               ; Dictionary size bitmask (e.g., 0x3FF, 0x7FF).
bitbuff dw      ?               ; 16-bit buffer for reading compressed data bits.
extrabits dw    ?               ; Number of valid bits currently in bitbuff.
in_pos  dw      ?               ; Current read position in in_buff.
inbytes dw      ?               ; Number of valid bytes available in in_buff.

; --- I/O Function Pointers ---
DECread dd      ?               ; Pointer to function to read a block of data.
DECwrite dd     ?               ; Pointer to function to write a block of data.

; --- Buffers ---
outbuff db      d_4096 dup(?)   ; Primary output circular buffer (4KB) for decompressed data.
	db      d_4096 dup(?), h_204 dup(?); This appears to be the *start* of the 4KB buffer, used as a temporary write buffer.
inbuff  db      d_2048 dup(?)   ; Buffer (2KB) for compressed data read from input.

; --- Decoding Tables ---
; These are "fast" lookup tables built by GenDecodeTab/GenAscTab
; to quickly find a value from the first N bits of the input stream.
DistPosCode db  256 dup(?)      ; Fast decode table for distance codes.
LengthCode db   256 dup(?)      ; Fast decode table for length codes (binary mode).
ASC_lvl_01 db   256 dup(?)      ; Fast decode table for ASCII mode, level 1.
ASC_lvl_02 db   256 dup(?)      ; Fast decode table for ASCII mode, level 2.
ASC_lvl_03 db   128 dup(?)      ; Fast decode table for ASCII mode, level 3.
ASC_lvl_04 db   256 dup(?)      ; Fast decode table for ASCII mode, level 4.

; --- Source Tables for Decompression ---
; These are copied from the static data segment at initialization.
ChBitsAsc db    256 dup(?)      ; Table of literal bit lengths for ASCII mode.
Dst_Bits db     64 dup(?)       ; Table of bit lengths for distance codes.
LenBits db      16 dup(?)       ; Table of bit lengths for length codes.
ExLenBits db    16 dup(?)       ; Table of *extra* bits for length codes.
LenBase dw      16 dup(?)       ; Table of base values for length codes.
sDEC    ends

.8086
.model  small

; Segment type: Group
;DGROUP  group   _DATA

; Segment type: Pure data
;_DATA   segment word public 'DATA'
;_DATA   ends

; Segment type: Pure code
PK_TEXT segment word private 'CODE'
	assume  cs:PK_TEXT

; Pointers to the workspace structures.
; These are set by Implode/Explode entry points.
ptrCOM  dd      0
ptrDEC  dd      0
saveDS  dw      ?
KMP_buff dw     ?               ; Temp buffer used in FindRep's - Knuth-Morris-Pratt (KMP) KMP-like search

; --- Static Data Tables for Compression & Decompression ---
; These define the "shape" of the compressed data.

; Bit lengths for each of the 64 distance codes
TabDistBits db  2, 2 dup(4), 4 dup(5), 15 dup(6), 26 dup(7), 16 dup(8)

; Codes for each of the 64 distances
TabDistCode db  3, 13, 5, 25, 9, 17, 1, 62, 30, 46, 14, 54, 22, 38
	db      6, 58, 26, 42, 10, 50, 18, 34, 66, 2, 124, 60, 92, 28
	db      108, 44, 76, 12, 116, 52, 84, 20, 100, 36, 68, 4, 120
	db      56, 88, 24, 104, 40, 72, 8, 240, 112, 176, 48, 208
	db      80, 144, 16, 224, 96, 160, 32, 192, 64, 128, 0

; Number of *extra* bits for each of the 16 length codes
TabExLenBits db 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8

; Base values for each of the 16 length codes
TabLenBase dw   0, 1, 2, 3, 4, 5, 6, 7, 8, 0Ah, 0Eh, 16h, 26h, 46h
	dw      86h, 106h

; Bit lengths for each of the 16 length codes
TabLenBits db   3, 2, 3, 3, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 7, 7

; Codes for each of the 16 lengths
TabLenCode db   5, 3, 1, 6, 0Ah, 2, 0Ch, 14h, 4, 18h, 8, 30h, 10h, 20h
	db      40h, 0

; --- Static Tables for ASCII Mode ---
; Bit lengths for ASCII literals
TabChBitsAsc db 0Bh, 8 dup(0Ch), 8, 7, 2 dup(0Ch), 7, 0Ch dup(0Ch)
	db      0Dh, 5 dup(0Ch), 4, 0Ah, 8, 0Ch, 0Ah, 0Ch, 0Ah, 8, 2 dup(7)
	db      8, 9, 7, 6, 7, 8, 7, 6, 4 dup(7), 8, 2 dup(7), 2 dup(8)
	db      0Ch, 0Bh, 7, 9, 0Bh, 0Ch, 6, 7, 2 dup(6), 5, 7, 2 dup(8)
	db      6, 0Bh, 9, 6, 7, 2 dup(6), 7, 0Bh, 3 dup(6), 7, 9, 8
	db      2 dup(9), 0Bh, 8, 0Bh, 9, 0Ch, 8, 0Ch, 5, 3 dup(6)
	db      5, 3 dup(6), 5, 0Bh, 7, 5, 6, 2 dup(5), 6, 0Ah, 4 dup(5)
	db      8, 7, 2 dup(8), 0Ah, 2 dup(0Bh), 3 dup(0Ch), 30h dup(0Dh)
	db      30h dup(0Ch), 0Dh, 0Ch, 3 dup(0Dh), 0Ch, 3 dup(0Dh)
	db      0Ch, 4 dup(0Dh), 0Ch, 3 dup(0Dh), 3 dup(0Ch), 0Bh dup(0Dh)

; Codes for ASCII literals
TabChCodeAsc dw 490h, 0FE0h, 7E0h, 0BE0h, 3E0h, 0DE0h, 5E0h, 9E0h, 1E0h
	dw      0B8h, 62h, 0EE0h, 6E0h, 22h, 0AE0h, 2E0h, 0CE0h, 4E0h
	dw      8E0h, 0E0h, 0F60h, 760h, 0B60h, 360h, 0D60h, 560h, 1240h
	dw      960h, 160h, 0E60h, 660h, 0A60h, 0Fh, 250h, 38h, 260h
	dw      50h, 0C60h, 390h, 0D8h, 42h, 2, 58h, 1B0h, 7Ch, 29h
	dw      3Ch, 98h, 5Ch, 9, 1Ch, 6Ch, 2Ch, 4Ch, 18h, 0Ch, 74h
	dw      0E8h, 68h, 460h, 90h, 34h, 0B0h, 710h, 860h, 31h, 54h
	dw      11h, 21h, 17h, 14h, 0A8h, 28h, 1, 310h, 130h, 3Eh, 64h
	dw      1Eh, 2Eh, 24h, 510h, 0Eh, 36h, 16h, 44h, 30h, 0C8h
	dw      1D0h, 0D0h, 110h, 48h, 610h, 150h, 60h, 88h, 0FA0h
	dw      7, 26h, 6, 3Ah, 1Bh, 1Ah, 2Ah, 0Ah, 0Bh, 210h, 4, 13h
	dw      32h, 3, 1Dh, 12h, 190h, 0Dh, 15h, 5, 19h, 8, 78h, 0F0h
	dw      70h, 290h, 410h, 10h, 7A0h, 0BA0h, 3A0h, 240h, 1C40h
	dw      0C40h, 1440h, 440h, 1840h, 840h, 1040h, 40h, 1F80h
	dw      0F80h, 1780h, 780h, 1B80h, 0B80h, 1380h, 380h, 1D80h
	dw      0D80h, 1580h, 580h, 1980h, 980h, 1180h, 180h, 1E80h
	dw      0E80h, 1680h, 680h, 1A80h, 0A80h, 1280h, 280h, 1C80h
	dw      0C80h, 1480h, 480h, 1880h, 880h, 1080h, 80h, 1F00h
	dw      0F00h, 1700h, 700h, 1B00h, 0B00h, 1300h, 0DA0h, 5A0h
	dw      9A0h, 1A0h, 0EA0h, 6A0h, 0AA0h, 2A0h, 0CA0h, 4A0h, 8A0h
	dw      0A0h, 0F20h, 720h, 0B20h, 320h, 0D20h, 520h, 920h, 120h
	dw      0E20h, 620h, 0A20h, 220h, 0C20h, 420h, 820h, 20h, 0FC0h
	dw      7C0h, 0BC0h, 3C0h, 0DC0h, 5C0h, 9C0h, 1C0h, 0EC0h, 6C0h
	dw      0AC0h, 2C0h, 0CC0h, 4C0h, 8C0h, 0C0h, 0F40h, 740h, 0B40h
	dw      340h, 300h, 0D40h, 1D00h, 0D00h, 1500h, 540h, 500h
	dw      1900h, 900h, 940h, 1100h, 100h, 1E00h, 0E00h, 140h
	dw      1600h, 600h, 1A00h, 0E40h, 640h, 0A40h, 0A00h, 1200h
	dw      200h, 1C00h, 0C00h, 1400h, 400h, 1800h, 800h, 1000h
	dw      0

; ==========================================================================
;
; Main entry point for COMPRESSION
;
; In:
;   [bp+6]  (DWORD) -> Dictionary size (1024, 2048, or 4096)
;   [bp+0Ah] (DWORD) -> Compression type (0=binary, 1=ASCII)
;   [bp+0Eh] (DWORD) -> Pointer to sCOM compression workspace buffer
;   [bp+12h] (DWORD) -> FAR pointer to Write function
;   [bp+16h] (DWORD) -> FAR pointer to Read function
;
; Out:
;   AX = 0 on success, or an error code (CMP_...)
;
public  Implode
Implode proc    far

_a_dictsize     = dword ptr  6
_a_comtype      = dword ptr  0Ah
_a_buffer       = dword ptr  0Eh
_a_blockwrite   = dword ptr  12h
_a_blockread    = dword ptr  16h

	push    bp
	mov     bp, sp

	sub     sp, (h_204*2)   ; allocate temp KMP-buffer on stack
	mov     cs:KMP_buff, sp

	push    ds
	push    di
	push    si

	mov     ax, ds
	mov     cs:saveDS, ax

; Load pointer to the sCOM workspace buffer
	lds     bx, [bp+_a_buffer]; DS:BX = pointer to sCOM
; DS = segment _a_buffer

; Save the sCOM pointer globally
	mov     word ptr cs:ptrCOM, bx
	mov     word ptr cs:ptrCOM[2], ds

; Copy Read function pointer into sCOM
	les     ax, [bp+_a_blockread]
	mov     word ptr [bx+sCOM.COMread], ax
	mov     word ptr [bx+(sCOM.COMread+2)], es

; Copy Write function pointer into sCOM
	les     ax, [bp+_a_blockwrite]
	mov     word ptr [bx+sCOM.COMwrite], ax
	mov     word ptr [bx+(sCOM.COMwrite+2)], es

; Get Dictionary size
	les     di, [bp+_a_dictsize]
	mov     ax, es:[di]
	mov     [bx+sCOM.dictsize_bytes], ax; Dictionary size in bytes

; Get Compression type
	les     di, [bp+_a_comtype]
	mov     cx, es:[di]     ; cx = compression type
	mov     [bx+sCOM.ctype], cx

; --- Set dictionary bits and mask based on size ---
; Default to 1KB (1024 bytes)
	mov     [bx+sCOM.dictsize_bits], 4; Default dictionary bits (4=1KB)
	mov     [bx+sCOM.dictsize_mask], 01111b; Default dictionary mask (0x3FF)

	push    ds
	pop     es
; ES = segment _a_buffer

	cmp     ax, 1024
	jz      @@dictsize_1k
	cmp     ax, 2048
	jz      @@dictsize_2k
	cmp     ax, 4096
	jz      @@dictsize_4k

; Not a valid size
	mov     ax, CMP_INVALID_DICTSIZE
	jmp     @@ret

@@dictsize_4k:
	inc     [bx+sCOM.dictsize_bits]; 4 -> 5 -> 6 bits
	or      byte ptr [bx+sCOM.dictsize_mask], 100000b; Mask 0x7FF -> 0xFFF

@@dictsize_2k:
	inc     [bx+sCOM.dictsize_bits]; 4 -> 5 bits
	or      byte ptr [bx+sCOM.dictsize_mask], 10000b; Mask 0x3FF -> 0x7FF

@@dictsize_1k:
; --- Check compression type ---
	jcxz    @@ModeBinary    ; If CX=0, it's Binary mode

	dec     cx
	jz      @@ModeASCII     ; If CX=1, it's ASCII mode

	mov     ax, CMP_INVALID_MODE
	jmp     @@ret

; --- Initialize encoding tables for BINARY mode ---
@@ModeBinary:
	cld
; Fill literal bit lengths table (nChBits)
	lea     di, [bx+sCOM.nChBits]; Table of literal bit lengths
	mov     ax, 909h        ; Fill with 09h (all literals are 9 bits)
	mov     cx, 128
	rep     stosw           ; 128 * 2 = 256 bytes

; Fill literal codes table (nChCodes)
	mov     ch, 1           ; cx = 100h = 256
	lea     di, [bx+sCOM.nChCodes]; Table of literal codes
	xor     ax, ax
@@_1:
; Loop to fill codes 0, 2, 4, 6...
	stosw
	add     ax, 2
	loop    @@_1

	jmp     @@init_tables

; --- Initialize encoding tables for ASCII mode ---
@@ModeASCII:
	mov     si, 255         ; Loop from 255 down to 0
@@_2:
; Copy bit length from static table
	mov     al, cs:TabChBitsAsc[si]
	inc     al              ; (Stored as N-1)
	mov     [bx+si+sCOM.nChBits], al; Table of literal bit lengths

; Copy code from static table
	shl     si, 1           ; index*2
	mov     ax, cs:TabChCodeAsc[si]
	shl     ax, 1           ; (Stored as Code/2)
	mov     [bx+si+sCOM.nChCodes], ax; Table of literal codes
	shr     si, 1           ; restore index

	dec     si
	jge     @@_2            ; loop 255 downto 0

; --- Common initialization for Length tables ---
@@init_tables:
	xor     di, di          ; DI = index for static tables (0-15)
	mov     si, 256         ; SI = index into nChBits/nChCodes for lengths

	push    bp              ; save bp

@@loop_1:
; Get number of extra bits for this length code
	mov     cl, cs:TabExLenBits[di]
	mov     dx, 1
	shl     dx, cl          ; DX = 2^CL = number of entries for this base length
	mov     bp, dx          ; BP = loop counter
	xor     dx, dx          ; DX = extra bit value (0 to BP-1)

@@_3:
; Get base bit length
	mov     al, cs:TabLenBits[di]
	mov     cl, al
	inc     al
; Total bits = base_bits + extra_bits + 1 (for code)
	add     al, cs:TabExLenBits[di]
	mov     [bx+si+sCOM.nChBits], al; Store total bit length

; Calculate the code
	mov     ax, dx
	shl     ax, cl
	or      al, cs:TabLenCode[di]
	add     ax, ax
	inc     ax

	shl     si, 1
	mov     [bx+si+sCOM.nChCodes], ax; Store the code
	shr     si, 1
	inc     si              ; Next entry in nCh...

	inc     dx
	cmp     bp, dx
	ja      @@_3            ; Loop for all extra bit values

	inc     di
	cmp     di, 16          ; loop 16 times (for 16 base lengths)
	jb      @@loop_1

	pop     bp              ; load bp

; Copy static distance tables to workspace
	push    ds

	lea     di, [bx+sCOM.dist_codes]
	mov     si, offset TabDistCode
	mov     cx, 32
; ES Already as DS
	push    cs
	pop     ds
	rep     movsw

	lea     di, [bx+sCOM.dist_bits]
	mov     si, offset TabDistBits
	mov     cx, 32
	rep     movsw

	pop     ds

; --- All tables built, start compression ---
	call    WriteCmpData
	xor     ax, ax          ; Return 0 (Success)

@@ret:
; Standard function exit
	pop     si
	pop     di
	pop     ds

	mov     sp, bp
	pop     bp

	retf    5*4             ; Far return, popping 5*4=20 bytes of args

Implode endp

; ==========================================================================
;
; The main compression loop
;
; This function reads blocks of data, finds matches,
; and writes the compressed bitstream.
;
WriteCmpData proc near

; --- Local variables on stack ---
v_phase         = word ptr -0Eh ; Phase for dictionary sliding
v_inp_data_ended= word ptr -0Ch ; Flag: 1 if end of input file reached
v_bytes_to_load = word ptr -0Ah ; Number of bytes left to read in this block
v_input_end     = word ptr -8   ; Pointer to end of valid data in current block
v_src           = word ptr -6   ; Pointer to start of current data in sliding window
v_savedist      = word ptr -4   ; Temp storage for distance during lookahead
v_total_loaded  = word ptr -2   ; Total bytes loaded in this block

	push    bp
	mov     bp, sp
	sub     sp, 7*2         ; Allocate space for locals

	mov     di, bx          ; DI = sCOM pointer

	add     di, [bx+sCOM.dictsize_bytes]; Dictionary size in bytes
	lea     ax, [di+sCOM.phash_offs]
	mov     [bp+v_src], ax  ; v_src = pointer to start of phash_offs buffer

; Write 2-byte header
	mov     al, byte ptr [bx+sCOM.ctype]
	mov     ah, byte ptr [bx+sCOM.dictsize_bits]; Dictionary size bits
	lea     di, [bx+sCOM.out_buf]
	mov     [di], ax
	mov     [bx+sCOM.out_bytes], 2; Header is 2 bytes

	add     di, 2
	xor     ax, ax
	mov     [bp+v_phase], ax
	mov     [bp+v_inp_data_ended], ax
	mov     cx, (d_2048-2)/2
	rep     stosw           ; clear out_buf

	mov     [bx+sCOM.out_bits], 0; No bits in last output byte yet

@@mainloop:
; --- Read a block of data ---
	mov     [bp+v_bytes_to_load], d_4096; Try to read 4KB
	xor     si, si          ; SI = bytes loaded so far this block

@@re_read:
	push    [bp+v_bytes_to_load]
	push    si

; Calculate buffer address to read into
	lea     di, [bx+si+sCOM.phash_offs]
	add     di, [bx+sCOM.dictsize_bytes]; Dictionary size in bytes
	push    ds
	push    di

	lea     di, [bp+v_bytes_to_load]
	push    ss
	push    di

	push    ds
	pop     es
	mov     ax, cs:saveDS
	mov     ds, ax
	call    es:[bx+sCOM.COMread]; Read data from source.
	mov     di, ax          ; DI = total bytes read.

; Reload sCOM pointer
	lds     bx, cs:ptrCOM
	pop     si
	pop     [bp+v_bytes_to_load]

	test    di, di          ; DI = total bytes read.
	jz      @@EOF           ; If 0 bytes read, end of file

	add     si, di          ; Add to total bytes in buffer

	sub     [bp+v_bytes_to_load], di; Decrement bytes needed
	jnz     @@re_read       ; Loop if we haven't read 4096

	mov     [bp+v_total_loaded], si; SI = total bytes in buffer

	mov     cx, si
	jmp     @@process_block ; Go process this block

@@EOF:
; 0 bytes read, end of file
	mov     [bp+v_total_loaded], si
	mov     cx, si

	test    cx, cx
	jnz     @@_4            ; If there's still data left, process it

	cmp     [bp+v_phase], 0
	jnz     @@_4            ; If there's still data left, process it

	jmp     _wcd_exit       ; No data left, exit

@@_4:
	jmp     _wcd_set_end_flag; Mark end and process remaining data

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
@@LoopCompress:
; Main compression loop for the current block
	mov     [bp+v_input_end], di; DI = end of data

_wcd_find_rep_loop:
; Find best repetition at current position (SI)
	call    FindRep         ; si=index
; ret ax=length, sCOM.distance=distance
	mov     di, ax          ; DI = length of match

@@chk_matchlen:

	test    di, di
	jz      _wcd_output_literal; If no repetition found (length=0)

; Check for "bad" repetitions
	cmp     di, 2           ; If length=2
	jnz     @@_5
	cmp     [bx+sCOM.distance], 100h; and distance is > 255
	jnb     _wcd_output_literal; then treat as a literal

@@_5:
; Check if we're at the end of the input
	cmp     [bp+v_inp_data_ended], 0
	jz      _wcd_lookahead  ; di=rep_length

; We are at the end, so truncate match if it runs past the end
	mov     ax, si
	add     ax, di
	cmp     ax, [bp+v_input_end]
	jbe     _wcd_lookahead  ; di=rep_length

	mov     di, [bp+v_input_end]
	sub     di, si
	cmp     di, 2
	jb      _wcd_output_literal
	jnz     _flushrepetition; Flush if length > 2

	cmp     [bx+sCOM.distance], 100h; or if length=2 and distance is small
	jb      _flushrepetition

_wcd_output_literal:
; No usable repetition found, output a literal
	xor     ax, ax
	mov     al, [si]        ; BL = literal value
	mov     di, ax
	mov     al, [bx+di+sCOM.nChBits]; Get bit length for this literal
	shl     di, 1
	mov     dx, [bx+di+sCOM.nChCodes]; Get code for this literal

	mov     di, 1           ; Length of 1 byte (the literal)

	jmp     _wcd_output_and_advance; Go write bits and advance SI

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Look ahead one byte to see if a better match is available
_wcd_lookahead:
; di=rep_length
	cmp     di, 8           ; If match is long, just take it
	jnb     _flushrepetition

	inc     si
	cmp     si, [bp+v_input_end]; Check if we're at the end
	dec     si
	jnb     _flushrepetition

; Save current match
	mov     ax, [bx+sCOM.distance]
	mov     [bp+v_savedist], ax
	mov     [bp+v_total_loaded], di; Use v_total_loaded as temp for length

; Find repetition for the *next* byte
	inc     si
	call    FindRep
	dec     si

	mov     di, ax          ; DI = length of next match
	mov     ax, [bp+v_total_loaded]; AX = length of current match
	cmp     di, ax
	jbe     @@updatedist    ; If next match is not better, use current one

	inc     ax
	cmp     ax, di
	jb      @@_6

	cmp     [bp+v_savedist], 80h; If current match is distance
	jbe     @@updatedist    ; ...use it

@@_6:
; Next match is better. Output current byte as literal and continue
	push    bx
	xor     cx, cx
	mov     cl, [si]        ; CL = literal value
	add     bx, cx
	xor     ax, ax
	mov     al, [bx+sCOM.nChBits]; Get bit length
	add     bx, cx
	mov     dx, [bx+sCOM.nChCodes]; Get code
	pop     bx
	call    OutputBits
	inc     si              ; Advance SI by 1

	jmp     @@chk_matchlen  ; Re-evaluate from new position

@@updatedist:
; Current match is better, restore it
	mov     di, [bp+v_total_loaded]; DI = length

	mov     ax, [bp+v_savedist]
	mov     [bx+sCOM.distance], ax; Restore distance

_flushrepetition:
; Output a length/distance pair
	shl     di, 1           ; index = length * 2
	mov     dx, [bx+di+sCOM.nChCodes+(0FEh*2)]; Get code
	shr     di, 1
	xor     ax, ax
	mov     al, [bx+di+sCOM.nChBits+(0FEh)]; Get bit length
	call    OutputBits      ; Write length code

	cmp     di, 2
	jnz     @@_7

; Handle distance encoding differently for length 2
	push    bx
	mov     ax, [bx+sCOM.distance]
	shr     ax, 1
	shr     ax, 1           ; AX = distance / 4
	add     bx, ax
	xor     ax, ax
	cwd
	mov     dl, [bx+sCOM.dist_codes]; Distance codes
	mov     al, [bx+sCOM.dist_bits]; Distance bits
	pop     bx
	call    OutputBits      ; Write distance code

	mov     dl, byte ptr [bx+sCOM.distance]
	and     dx, 3           ; DX = extra bits (distance % 4)
	mov     ax, di          ; AX = bit count (2)
	jmp     _wcd_output_and_advance

@@_7:
; Handle distance encoding for length > 2
	push    bx
	mov     ax, [bx+sCOM.distance]
	mov     cl, byte ptr [bx+sCOM.dictsize_bits]
	shr     ax, cl          ; AX = distance / dict_size_factor
	add     bx, ax
	xor     ax, ax
	cwd
	mov     dl, [bx+sCOM.dist_codes]; Distance codes
	mov     al, [bx+sCOM.dist_bits]; Distance bits
	pop     bx
	call    OutputBits      ; Write distance code

	mov     dx, [bx+sCOM.dictsize_mask]
	and     dx, [bx+sCOM.distance]; DX = extra bits
	mov     ax, [bx+sCOM.dictsize_bits]; AX = bit count

_wcd_output_and_advance:
; ax=bit_count, dx=bits_to_write
	call    OutputBits      ; Write literal or extra bits
	add     si, di          ; Advance SI by match length (or 1 for literal)
	cmp     [bp+v_input_end], si
	jbe     _wcd_block_done ; If end of block, finish up

	jmp     _wcd_find_rep_loop; Loop for next match

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
_wcd_set_end_flag:
	mov     [bp+v_inp_data_ended], 1; Set end of input flag

@@process_block:
	mov     di, cx          ; DI = number of bytes in block
	add     di, [bx+sCOM.dictsize_bytes]; Dictionary size in bytes
	lea     di, [bx+di+sCOM.work_buff]; DI = end of data pointer

	cmp     [bp+v_inp_data_ended], 0
	jz      _wcd_not_end_of_input; If not end of input
	add     di, h_204       ; di=input_data_end

_wcd_not_end_of_input:
	mov     ax, [bp+v_phase]; Get current phase
	test    ax, ax
	jz      @@phase_0       ; phase==0

	dec     ax
	jz      @@phase_1       ; phase==1

; phase > 1
	mov     si, [bp+v_src]
	lea     ax, [di+1]
	mov     cx, [bx+sCOM.dictsize_bytes]; Dictionary size in bytes
	mov     dx, si
	sub     dx, cx
	call    SortBuffer      ; Re-sort the dictionary

	jmp     _wcd_check_more_data

@@phase_0:
; phase==0
	cmp     [bx+sCOM.dictsize_bytes], d_4096; Dictionary size in bytes
	jz      @@_8

	inc     [bp+v_phase]

@@_8:
	mov     si, [bp+v_src]
	lea     ax, [di+1]
	mov     dx, si
	jmp     @@_9

@@phase_1:
; phase==1
	mov     si, [bp+v_src]
	lea     ax, [di+1]
	mov     cx, [bx+sCOM.dictsize_bytes]; Dictionary size in bytes
	lea     dx, [si+h_204]
	sub     dx, cx
@@_9:
	call    SortBuffer      ; Sort the buffer to build hash table
	inc     [bp+v_phase]

_wcd_check_more_data:
	cmp     di, si
	jbe     _wcd_block_done ; If no more data to process in this block

	jmp     @@LoopCompress  ; Go to inner compression loop

_wcd_block_done:
	cmp     [bp+v_inp_data_ended], 0
	jnz     @@_10           ; If end of input, don't slide window

; --- Slide the dictionary window ---
; Copy the last d_4096 (or dict_size) bytes to the start of the buffer
	push    si
	push    di

	lea     di, [bx+sCOM.work_buff]
	lea     si, [bx+sCOM.work_buff+d_4096]
	mov     cx, [bx+sCOM.dictsize_bytes]; Dictionary size in bytes
	add     cx, h_204
	shr     cx, 1
	rep     movsw
	jnc     $+3
	movsb

	pop     di
	pop     si

	sub     si, d_4096      ; Adjust SI to new position

@@_10:
	mov     [bp+v_src], si  ; Save new start pointer
	cmp     [bp+v_inp_data_ended], 0
	jnz     _wcd_exit       ; If end of input, exit

	jmp     @@mainloop      ; Loop to read next block of data

_wcd_exit:
; --- Write stop code ---
	xor     ax, ax
	mov     al, [bx+sCOM.nChBits+305h]; Get bit length for STOP code
	mov     dx, [bx+sCOM.nChCodes+(305h*2)]; Get STOP code
	call    OutputBits

; --- Flush any remaining bits in the buffer ---
	cmp     [bx+sCOM.out_bits], 0; If there are partial bits in the last byte
	jz      @@_11
	inc     [bx+sCOM.out_bytes]; Increment byte count to include it

@@_11:
; --- Write final block of compressed data ---
	lea     ax, [bx+sCOM.out_buf]
	push    ds
	push    ax              ; Arg 1: buffer
	lea     ax, [bx+sCOM.out_bytes]; # bytes available in out_buff
	push    ds
	push    ax              ; Arg 2: size

	push    ds
	pop     es
	mov     ax, cs:saveDS
	mov     ds, ax
	call    es:[bx+sCOM.COMwrite]
; Reload SCOM pointer, no need at the end.

; --- Clean up and return ---
	mov     sp, bp
	pop     bp
	retn

WriteCmpData endp

; ==========================================================================
;
; Find best repetition for string at current position.
;
; In:
;   SI = current position in phash_offs buffer
;
; Out:
;   AX = length of best repetition found (0 if none)
;   sCOM.distance is updated with the distance of the best match
;
FindRep proc    near

; --- Local variables ---
v_inputdata     = word ptr -10h ; == [bp+6] (pushed SI)
v_bakSI         = word ptr -0Eh ; Temp for KMP-like search
v_bakDI         = word ptr -0Ch ; Temp for KMP-like search
v_index         = word ptr -0Ah ; Temp for hash index
v_phashtoindex  = word ptr -8   ; Pointer into hash chain
v_len           = word ptr -6   ; Best length found so far
v_ptr_input     = word ptr -4   ; == [bp+6] (pushed SI)

	push    bp
	mov     bp, sp
	sub     sp, 7*2         ; Allocate locals
	push    si              ; v_inputdata is here
	push    di
	push    bx

	mov     [bp+v_len], 1   ; Min length is 1 (a literal)

; --- Calculate 2-byte hash ---
	xor     ax, ax
	mov     al, [si]        ; AL = char 1
	mov     di, ax
	mov     al, [si+1]      ; AL = char 2
	mov     cl, 3
	shl     di, cl
	add     di, ax          ; DI = (char1 * 8) + char2

	add     di, di          ; DI = hash * 2 (for word index)
	mov     [bp+v_index], di; Save hash index

; Get start of hash chain
	mov     di, [di+bx+sCOM.phash_to_index]
	mov     [bp+v_phashtoindex], di

; Calculate minimum allowed offset (start of dictionary window)
	sub     si, [bx+sCOM.dictsize_bytes]; Dictionary size in bytes
	inc     si
; SI now = min_phash_offs

	push    ds
	pop     es

; Find first hash entry *within* the current dictionary window
	cmp     [di], si        ; si=min_phash_offs
	jnb     _fr_hash_in_window

@@_12:
; This hash entry is too old (outside window), try next
	add     di, 2
	cmp     [di], si
	jb      @@_12

; Found first valid entry
	mov     [bp+v_phashtoindex], di
	mov     ax, di
	mov     di, [bp+v_index]
	mov     [di+bx+sCOM.phash_to_index], ax; Update hash table head

_fr_hash_in_window:
	mov     bx, [bp+v_phashtoindex]
	mov     di, [bx]        ; DI = offset of potential match
	mov     dx, [bp+v_inputdata]; DX = current position
	dec     dx
	cmp     di, dx          ; Compare previous repetition offset with limit
	jnb     _fr_ret_0

; --- Start searching the hash chain ---
	mov     si, [bp+v_inputdata]; SI = current position
	mov     cx, si
	mov     [bp+v_ptr_input], si
	mov     bx, [bp+v_len]
	dec     bx
	mov     al, [bx+si]     ; AL = last char of current best match (char at SI+0)

@@_13:
; --- Check this potential match ---
	cmp     [bx+di], al     ; Quick check: compare last char of *current* match
	jnz     @@scan_2        ; If no match, try next in chain

	cmpsb                   ; Compare first char
	jnz     @@scan_1

; Found a potential match (first char matches), now find its length
	mov     cx, (h_204-2)   ; Max length to check
	inc     si
	inc     di
	repe    cmpsb           ; Find length of match
	jz      @@_14
	inc     cx              ; Adjust length if cmpsb stopped due to CX=0

@@_14:
	sub     cx, h_204
	neg     cx              ; CX = length of this match
	cmp     [bp+v_len], cx  ; Is it longer than best so far?
	ja      @@_15           ; If new match is not longer, continue searching

; --- New best match found ---
	lea     ax, [si-1]
	sub     ax, di

; Reload sCOM pointer
	mov     bx, word ptr cs:ptrCOM

	mov     [bx+sCOM.distance], ax; Store distance
	mov     [bp+v_len], cx  ; Store length
	cmp     cx, 14
	jb      @@_15

	cmp     cx, h_204       ; Is it max length?
	jnz     @@_17

	jmp     @@ret_cx

@@_15:
; Set up for next check in hash chain
	mov     bx, [bp+v_len]
	dec     bx
	mov     si, [bp+v_ptr_input]
	mov     al, [bx+si]     ; AL = last char of current best match
	mov     cx, si          ; cx = current input position
@@scan_1:
	mov     si, cx

@@scan_2:
; Get next entry in hash chain
	mov     di, [bp+v_phashtoindex]
	add     di, 2
	mov     [bp+v_phashtoindex], di
	mov     di, [di]        ; DI = offset of potential match
	cmp     di, dx          ; Check if still in window
	jb      @@_13

; chk_len_1
	mov     ax, [bp+v_len]
	cmp     ax, 2           ; Was best length >= 2?
	jnb     @@_16           ; Return best length
_fr_ret_0:
	xor     ax, ax          ; Return 0
@@_16:
	jmp     _fr_ret

@@_17:
; --- This section is a complex, KMP-like search for ---
; --- overlapping/better matches. ---
	mov     bx, [bp+v_phashtoindex]
	cmp     [bx+2], dx      ; Check next hash entry
	jnb     @@ret_vlen

	cmp     [bx+4], dx
	jnb     @@_15

	xor     si, si

	mov     di, cs:KMP_buff
	mov     word ptr ss:[di], 0FFFFh
	mov     ss:[di+2], si

	mov     di, 1           ; offs_in_rep=1
	mov     bx, [bp+v_ptr_input]
	mov     cx, [bp+v_len]

_fr_loop_3:
	mov     al, [bx+di]
	cmp     [bx+si], al
	jz      @@_18
	shl     si, 1
	add     si, cs:KMP_buff
	mov     si, ss:[si]
	test    si, si
	jns     @@next_01

@@_18:
	inc     si
	inc     di

	push    di
	shl     di, 1
	add     di, cs:KMP_buff
	mov     ss:[di], si
	pop     di

@@next_01:
	cmp     cx, di
	ja      _fr_loop_3

	mov     [bp+v_bakSI], si
	mov     [bp+v_bakDI], di
	mov     bx, [bp+v_phashtoindex]
	mov     di, [bx]
	add     di, cx
	inc     di
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
_fr_loop_4:
	dec     di

	mov     si, cx          ; si=rep_length2
	shl     si, 1
	add     si, cs:KMP_buff
	mov     si, ss:[si]
	cmp     si, 0FFFFh
	jnz     _fr_loop_5

	inc     si

_fr_loop_5:
	add     [bp+v_phashtoindex], 2
	mov     bx, [bp+v_phashtoindex]
	mov     ax, [bx]
	mov     [bp+v_index], ax
	cmp     ax, dx
	jb      @@_qqq_01
@@ret_vlen:
	mov     ax, [bp+v_len]  ; Return best length
	jmp     _fr_ret

@@_qqq_01:
	add     ax, si
	cmp     ax, di
	jb      _fr_loop_5

	mov     bx, [bp+v_len]
	add     bx, [bp+v_index]
	mov     ax, [bx-2]

	mov     bx, [bp+v_len]
	add     bx, [bp+v_ptr_input]
	cmp     ax, [bx-2]
	jz      @@next_02

	mov     bx, [bp+v_len]
	dec     bx
	dec     bx
	mov     si, [bp+v_ptr_input]

@@back_01:
	add     [bp+v_phashtoindex], 2
	mov     di, [bp+v_phashtoindex]

	mov     di, [di]
	cmp     di, dx
	jnb     @@ret_vlen

	mov     ax, [bx+di]
	cmp     [bx+si], ax
	jnz     @@back_01

	mov     al, [di]
	cmp     [si], al
	jnz     @@back_01

	mov     cx, 2
	mov     [bp+v_index], di
	add     di, cx

	jmp     @@_19

@@ret_cx:
	mov     ax, cx          ; Return length
	jmp     _fr_ret

@@next_02:
	mov     cx, si
	mov     ax, [bp+v_index]
	add     ax, cx
	cmp     ax, di
	jz      @@_19

	xor     cx, cx
	mov     di, [bp+v_index]

@@_19:
	mov     si, [bp+v_ptr_input]
	add     si, cx
	neg     cx
	add     cx, h_204

	repe    cmpsb

	jz      @@_20
	inc     cx

@@_20:
	sub     cx, h_204
	neg     cx
	cmp     [bp+v_len], cx
	ja      _fr_loop_4a

	lea     ax, [si-1]
	sub     ax, di

; Reload sCOM pointer
	mov     bx, word ptr cs:ptrCOM
	mov     [bx+sCOM.distance], ax; Store new best distance
	cmp     [bp+v_len], cx
	jnb     _fr_loop_4a

; MAX_REP_LENGTH
	cmp     cx, h_204
	jz      @@ret_cx

	mov     [bp+v_len], cx  ; Store new best length

@@_21:
	mov     si, [bp+v_ptr_input]

	mov     bx, [bp+v_bakDI]
	mov     al, [bx+si]

	mov     bx, [bp+v_bakSI]
	cmp     [bx+si], al
	jz      @@_22

	shl     bx, 1
	mov     si, bx
	add     si, cs:KMP_buff
	mov     bx, ss:[si]

	test    bx, bx
	jns     @@next_03

@@_22:
	inc     bx
	inc     [bp+v_bakDI]

	mov     si, [bp+v_bakDI]
	shl     si, 1
	add     si, cs:KMP_buff
	mov     ss:[si], bx

@@next_03:
	mov     [bp+v_bakSI], bx
	mov     ax, [bp+v_bakDI]
	cmp     cx, ax
	ja      @@_21
_fr_loop_4a:
	jmp     _fr_loop_4

_fr_ret:
; --- Clean up and return ---
	pop     bx
	pop     di
	pop     si

	mov     sp, bp
	pop     bp
	retn
FindRep endp

; ==========================================================================
;
; Writes a specified number of bits to the output stream.
;
; In:
;   AX = number of bits to write (0-16)
;   DX = the bits (value)
;
OutputBits proc near

; --- Local variables ---
v_nbits         = word ptr -4   ; (pushed AX)
v_out_bits      = word ptr -2   ; Temp storage for sCOM.out_bits

	push    bp
	mov     bp, sp
	sub     sp, 2
	push    ax              ; v_nbits here

	push    di
	push    si

	mov     di, dx          ; DI = value to write
	cmp     ax, 8
	jbe     @@_LE_8
; If more than 8 bits, write 8 bits recursively
	mov     ax, 8
	call    OutputBits      ; ax=value, dx=???
	sub     [bp+v_nbits], 8 ; Adjust remaining bits
	mov     cl, 8
	shr     di, cl          ; Shift value

@@_LE_8:
	mov     cx, [bx+sCOM.out_bits]
	mov     [bp+v_out_bits], cx

	mov     ax, di          ; AX = value
	shl     al, cl          ; Shift value into position
	mov     si, [bx+sCOM.out_bytes]; si = index of current output byte
	or      [bx+si+sCOM.out_buf], al; OR bits into the output byte

	mov     ax, cx
	add     ax, [bp+v_nbits]
	mov     [bx+sCOM.out_bits], ax; Update total bits in current byte
	cmp     ax, 8
	jbe     @@done          ; If it's not full, we're done with this part

; --- Byte overflow ---
	inc     si              ; Move to next byte
	mov     cl, 8
	sub     cl, byte ptr [bp+v_out_bits]; CL = bits remaining in old byte
	shr     di, cl          ; Shift value to get overflow bits
	mov     ax, di
	mov     [bx+si+sCOM.out_buf], al; Write remaining bits to next byte
	and     [bx+sCOM.out_bits], 7; Update new bit count (mod 8)

	jmp     @@_25

@@done:
	and     [bx+sCOM.out_bits], 7
	jnz     @@_25           ; If byte is not exactly full, keep same byte index
	inc     si              ; Byte is exactly full, advance to next

@@_25:
; # bytes available in out_buff
	mov     [bx+sCOM.out_bytes], si
	cmp     si, d_2048      ; Is buffer full?
	jb      @@ret

	call    FlushBuf        ; Write 2KB block

@@ret:
	pop     si
	pop     di
	mov     sp, bp
	pop     bp
	retn
OutputBits endp

; ==========================================================================
;
; Sorts the input buffer to build the hash table
;
; This uses a 3-pass method to build the hash chains
;
; In:
;   AX = end_offset
;   DX = start_offset
;
SortBuffer proc near

var_8           = word ptr -8
var_6           = word ptr -6

	push    bp
	mov     bp, sp
	sub     sp, 4
	push    ax              ; var_6 is here
	push    dx              ; var_8 is here

	push    di
	push    si

; --- Pass 1: Clear hash table counts ---
	push    ds
	pop     es
	xor     ax, ax
	mov     cx, d_2304      ; 2304 * 2 = 4608 bytes
	lea     di, [bx+sCOM.phash_to_index]; Clear first part of hash table
	rep     stosw

	mov     dx, [bp+var_6]  ; DX = end_offset
	mov     si, [bp+var_8]  ; SI = start_offset
	sub     dx, si          ; DX = count
	mov     cl, 3

; --- Pass 2: Count occurrences of each hash ---
@@loop_1:
	lodsb                   ; AL = char 1
	mov     di, ax          ; DI =Char1
	mov     al, [si]        ; AX = char 2
	shl     di, cl          ; DI = char1 * 8
	add     di, ax          ; DI = (char1 * 8) + char2
	shl     di, 1           ; DI = hash * 2 (word index)
	add     word ptr [bx+di+sCOM.phash_to_index], 2; Increment count for this hash

	dec     dx
	jnz     @@loop_1

; --- Pass 3: Create cumulative counts to get pointers ---
	lea     ax, [bx+(size sCOM)]; SI+45B0h (Points past sCOM, seems wrong, but is address)
	mov     cx, d_2304/2
	lea     di, [bx+sCOM.phash_to_index]

@@loop_2:
	add     ax, [di]        ; AX = cumulative offset
	stosw                   ; Store offset
	add     ax, [di]        ; AX = cumulative offset
	stosw                   ; Store offset
	loop    @@loop_2

; --- Pass 4: Build the actual hash chains ---
	mov     dx, [bp+var_6]
	mov     si, dx
	sub     dx, [bp+var_8]  ; DX = count
	mov     cl, 3
	xor     ax, ax
	std                     ; Set direction flag (process backwards)
@@loop_3:
	lodsb
	mov     di, ax          ; char 1 (from end)
	mov     al, [si]        ; char 2
	xchg    ax, di
	shl     di, cl          ; DI * 8
	add     di, ax
	shl     di, 1
	sub     word ptr [bx+di+sCOM.phash_to_index], 2; Decrement the offset pointer
	mov     di, [bx+di+sCOM.phash_to_index]
	mov     [di], si        ; Store offset (SI) in the chain
	dec     dx
	jnz     @@loop_3
	cld

	pop     si
	pop     di

	mov     sp, bp
	pop     bp
	retn
SortBuffer endp

; ==========================================================================
;
; Flushes the 2048-byte chunk of the output buffer
; Handles buffer wrap-around by saving overflow bytes.
FlushBuf proc   near

var_4           = word ptr -4
v_outbuf        = byte ptr -2
v_outbyte       = byte ptr -1

	push    bp
	mov     bp, sp
	sub     sp, 4

	mov     [bp+var_4], d_2048; write 2048 bytes

; --- Call user's write function ---
	lea     ax, [bx+sCOM.out_buf]
	push    ds
	push    ax              ; Arg 1: buffer
	lea     ax, [bp+var_4]
	push    ss
	push    ax              ; Arg 2: size (2048)

	push    ds
	pop     es
	mov     ax, cs:saveDS
	mov     ds, ax
	call    es:[bx+sCOM.COMwrite]
; Reload sCOM pointer
	lds     bx, cs:ptrCOM

; --- Save overflow bytes ---
	mov     di, bx
	add     di, [bx+sCOM.out_bytes]; # bytes available in out_buff
	mov     al, [di+sCOM.out_buf]; Save last partial byte
	mov     [bp+v_outbyte], al

	mov     al, [bx+sCOM.out_buf+d_2048]; Save first byte *past* 2K
	mov     [bp+v_outbuf], al

	sub     [bx+sCOM.out_bytes], d_2048; Adjust byte count

; --- Clear the buffer ---
	lea     di, [bx+sCOM.out_buf]
	push    ds
	pop     es
	xor     ax, ax
	mov     cx, 401h        ; 2050 bytes
	rep     stosw

	cmp     [bx+sCOM.out_bytes], 0; # bytes available in out_buff
	jnz     @@NotZero

	mov     si, bx
	jmp     @@_25a

@@NotZero:
; Restore first overflow byte
	mov     al, [bp+v_outbuf]
	mov     [bx+sCOM.out_buf], al

@@_25a:
; # of bits available in the last out byte
	cmp     [bx+sCOM.out_bits], 0
	jz      @@Ret
; Restore last partial byte
	mov     si, [bx+sCOM.out_bytes]; # bytes available in out_buff
	add     si, bx
	mov     al, [bp+v_outbyte]
	mov     [si+sCOM.out_buf], al

@@Ret:
	mov     sp, bp
	pop     bp
	retn
FlushBuf endp

; ==========================================================================
; ==========================================================================
;
; Explode - Main entry point for DECOMPRESSION
;
; In:
;   [bp+6]  (DWORD) -> Pointer to sDEC decompression workspace buffer
;   [bp+0Ah] (DWORD) -> FAR pointer to Write function
;   [bp+0Eh] (DWORD) -> FAR pointer to Read function
;
; Out:
;   AX = 0 on success, or an error code (CMP_...)
;
public  Explode
Explode proc    far

a_buff          = dword ptr  6
a_blkwrite      = dword ptr  0Ah
a_blkread       = dword ptr  0Eh

	push    bp
	mov     bp, sp

	push    ds
	push    si
	push    di

	mov     ax, ds
	mov     cs:saveDS, ax

	lds     bx, [bp+a_buff]

; Save sDEC pointer globally
	mov     word ptr cs:ptrDEC, bx
	mov     word ptr cs:ptrDEC[2], ds

; Copy Write function pointer to sDEC
	les     ax, [bp+a_blkwrite]
	mov     word ptr [bx+sDEC.DECwrite], ax
	mov     word ptr [bx+(sDEC.DECwrite+2)], es

; Copy Read function pointer to sDEC
	les     ax, [bp+a_blkread]
	mov     word ptr [bx+sDEC.DECread], ax
	mov     word ptr [bx+(sDEC.DECread+2)], es

; --- Read and parse the compression header ---
	mov     [bx+sDEC.in_pos], d_2048; read 2048 bytes
	lea     ax, [bx+sDEC.inbuff]; Buffer for data to be decompressed
	push    ds
	push    ax              ; Arg 1: buffer
	lea     ax, [bx+sDEC.in_pos]; Position in in_buff
	push    ds
	push    ax              ; Arg 2: size

	push    ds
	pop     es
	mov     ax, cs:saveDS
	mov     ds, ax
	call    es:[bx+sDEC.DECread]
; Reload sDEC pointer
	lds     bx, [bp+a_buff]

	mov     [bx+sDEC.inbytes], ax; Number of bytes in input buffer
	cmp     ax, 4           ; Must have at least 4 bytes (header + data)
	ja      @@_26

	mov     ax, CMP_BAD_DATA
	jmp     _exp_ret

@@_26:
; Parse 4-byte header
	xor     ax, ax
	mov     al, [bx+sDEC.inbuff]; Byte 0: Compression type
	mov     [bx+sDEC.c_type], ax

	mov     al, [bx+sDEC.inbuff+2]; Byte 2: First 8 bits of data
	mov     [bx+sDEC.bitbuff], ax; Prime the 16-bit bit buffer

	mov     al, [bx+sDEC.inbuff+1]; Byte 1: Dictionary size bits
	mov     [bx+sDEC.dsizebits], ax; Dict size (4, 5, 6 for 0x400, 0x800, 0x1000)

	mov     [bx+sDEC.extrabits], 0; Number of extra (above 8) bits in bit buffer
	mov     [bx+sDEC.in_pos], 3; Position in input buffer (consumed 3 bytes)

	cmp     ax, 4           ; Dict size bits must be >= 4
	jnb     @@_27

	jmp     _exp_ret_1      ; Return 1 (CMP_INVALID_DICTSIZE)

@@_27:
	cmp     ax, 6           ; Dict size bits must be <= 6
	jbe     @@_28

	jmp     _exp_ret_1      ; Return 1

@@_28:
; Calculate dictionary size mask
	mov     cl, 16
	sub     cl, al
	mov     ax, 0FFFFh
	shr     ax, cl          ; cl=10..12
	mov     [bx+sDEC.dsizemask], ax; Dict size bitmask (0x0F, 0x1F, 0x3F for 0x400, 0x800, 0x1000)

	cld
	push    ds
	pop     es
; Check compression type
	mov     ax, [bx+sDEC.c_type]
	test    ax, ax
	jz      @@binmod        ; 0 = BINARY DeCompress
	dec     ax
	jz      @@asciimode     ; 1 = ASCII DeCompress
	mov     ax, CMP_INVALID_MODE
	jmp     _exp_ret

; --- Initialize for ASCII mode ---
@@asciimode:

; Copy static ASCII bit length table
	push    ds
	push    cs
	pop     ds
	lea     di, [bx+sDEC.ChBitsAsc]
	mov     si, offset TabChBitsAsc
	mov     cx, 256/2
	rep     movsw
	pop     ds

; Build fast ASCII decode tables
	call    GenAscTab

; --- Initialize for BINARY mode ---
@@binmod:

; Copy static Length bits table
	push    ds
	push    cs
	pop     ds
	lea     di, [bx+sDEC.LenBits]; Numbers of bits for skip copied block length
	mov     si, offset TabLenBits
	mov     cx, 16/2
	rep     movsw
	pop     ds

; Build fast Length decode table
	lea     dx, [bx+sDEC.LenBits]; Numbers of bits for skip copied block length
	mov     si, offset TabLenCode
	lea     di, [bx+sDEC.LengthCode]; Table of length codes
	mov     ax, 16
	call    GenDecodeTab

; Copy static Extra Length bits table
	push    ds

	push    cs
	pop     ds
	lea     di, [bx+sDEC.ExLenBits]; Numbers of valid bits for copied block
	mov     si, offset TabExLenBits
	mov     cx, 16/2
	rep     movsw

; Copy static Length base table
	lea     di, [bx+sDEC.LenBase]
	mov     si, offset TabLenBase
	mov     cx, 32/2
	rep     movsw

; Copy static Distance bits table
	lea     di, [bx+sDEC.Dst_Bits]; Numbers of bytes to skip copied block length
	mov     si, offset TabDistBits
	mov     cx, 64/2
	rep     movsw

	pop     ds

; Build fast Distance decode table
	lea     dx, [bx+sDEC.Dst_Bits]; Numbers of bytes to skip copied block length
	mov     si, offset TabDistCode
	lea     di, [bx+sDEC.DistPosCode]; Table of distance position codes
	mov     ax, 64
	call    GenDecodeTab

; --- All tables built, start expanding ---
	call    Expand

	cmp     ax, h_306       ; Check for abort code
	jnz     _exp_ret_0

	mov     ax, CMP_ABORT
	jmp     _exp_ret

_exp_ret_0:
	xor     ax, ax          ; Return 0 (Success)
	jmp     _exp_ret

_exp_ret_1:
	mov     ax, CMP_INVALID_DICTSIZE

_exp_ret:
; Standard function exit
	pop     di
	pop     si
	pop     ds

	pop     bp

	retf    0Ch             ; Far return, popping 3*4=12 bytes of args

Explode endp

; ==========================================================================
;
; Expand - The main decompression loop
;
; This function reads literals and length/distance pairs
; and reconstructs the original data.
;
Expand  proc    near

var_2           = word ptr -2

	push    bp
	mov     bp, sp
	sub     sp, 2

	mov     [bx+sDEC.outpos], d_4096; Start output at 4KB boundary

_epd_loop_1:
; --- Get next item (literal or length) ---
	call    DecodeLIT       ; AX = decoded value

	cmp     ax, 305h        ; Is it STOP code?
	jb      @@_29

	jmp     @@Done          ; Yes, exit

@@_29:
; Not stop code
	cmp     ax, 100h        ; Is it a literal (0-255)?
	jnb     @@_30           ; No, it's a length

; --- It's a LITERAL ---
	mov     di, [bx+sDEC.outpos]; Position in output buffer
	mov     [bx+di+sDEC.outbuff], al; Write literal to output
	inc     di
	mov     [bx+sDEC.outpos], di; Position in output buffer

	jmp     @@chk_8192

@@_30:
; --- It's a LENGTH/DISTANCE pair ---
	sub     ax, 0FEh        ; AX = length
	mov     di, ax          ; di=rep_length
	call    DecodeDist      ; AX = distance

	test    ax, ax
	jz      @@Error         ; If distance=0, error

	mov     cx, di          ; CX = length

	lea     di, [bx+sDEC.outbuff]; Output circle buffer.
	add     di, [bx+sDEC.outpos]; DI = pointer to dest
	add     [bx+sDEC.outpos], cx

	mov     si, di
	sub     si, ax          ; SI = pointer to source (current_pos - distance)

;                push    ds
;                pop     es
; --- Copy repetition from dictionary ---
	shr     cx, 1
	rep     movsw
	jnc     $+3
	movsb

	mov     di, [bx+sDEC.outpos]
@@chk_8192:
; --- Check if output buffer needs flushing ---
	cmp     di, 8192        ; 8KB threshold
	jb      _epd_loop_1     ; Not full, continue loop

; --- Flush first 4KB of output buffer ---
	mov     [bp+var_2], d_4096; write d_4096 bytes
	lea     ax, [bx+sDEC.outbuff+d_4096]; data here for write to file
	push    ds
	push    ax              ; Arg 1: buffer
	lea     ax, [bp+var_2]
	push    ss
	push    ax              ; Arg 2: size

	push    ds
	pop     es
	mov     ax, cs:saveDS
	mov     ds, ax
	call    es:[bx+sDEC.DECwrite]
; Reload sDEC pointer
	lds     bx, cs:ptrDEC

; --- Slide the output buffer ---
	push    di

	push    ds
	pop     es
	lea     di, [bx+sDEC.outbuff]; Output circle buffer.
	lea     si,[di+d_4096]
	mov     cx, [bx+sDEC.outpos]; Position in output buffer
	sub     cx, d_4096
	mov     [bx+sDEC.outpos], cx; Position in output buffer
	shr     cx, 1
	rep     movsw
	jnc     $+3
	movsb

	pop     di
	jmp     _epd_loop_1

@@Error:
; Error (distance=0)
	mov     [bp+var_2], h_306

@@Done:
; --- End of decompression ---
	push    [bp+var_2]      ; Save error code (if any)
; --- Flush remaining data in output buffer ---
	mov     ax, [bx+sDEC.outpos]; Position in output buffer
	sub     ax, d_4096
	mov     [bp+var_2], ax  ; AX = bytes to write
	lea     ax, [bx+sDEC.outbuff+d_4096]; data here for write to file
	push    ds
	push    ax              ; Arg 1: buffer
	lea     ax, [bp+var_2]
	push    ss
	push    ax              ; Arg 2: size

	push    ds
	pop     es
	mov     ax, cs:saveDS
	mov     ds, ax
	call    es:[bx+sDEC.DECwrite]
; Reload sDEC pointer, no need at the end.

	pop     ax              ; Get error code

	mov     sp, bp
	pop     bp
	retn
Expand  endp

; ==========================================================================
;
; Decodes a single literal or length value
;
; Out:
;   AX = Decoded value (0-255 for literal, 256-772 for length)
;      = 305h (STOP)
;      = 306h (ABORT)
;
DecodeLIT proc  near

; --- BINARY mode ---
	test    byte ptr [bx+sDEC.bitbuff], 1; Test bit 0
	jz      @@BinLit        ; Bit 0 = 0 -> Binary Literal

; Bit 0 = 1 -> Binary Length
	mov     ax, 1
	call    WasteBits       ; Consume 1 bit
	test    ax, ax
	jnz     @@ret_306

; AX == 0
; --- Binary LENGTH ---
;                xor     ax, ax
	mov     al, byte ptr [bx+sDEC.bitbuff]; 16-bit buffer for processing input data
	mov     si, ax          ; Get first 8 bits
	mov     al, [bx+si+sDEC.LengthCode]; Use fast lookup table
	mov     di, ax          ; DI = base length code
	lea     si, [bx+sDEC.LenBits]; Numbers of bits for skip copied block length
	add     si, ax
	mov     al, [si]        ; AL = bit length for this code
	call    WasteBits       ; Consume bits
	test    ax, ax
	jnz     @@ret_306

; AX == 0
	mov     cl, [bx+di+sDEC.ExLenBits]; CL = number of extra bits
	test    cl, cl
	jz      @@_31           ; No extra bits

; --- Read Extra Bits ---
	mov     si, 1
	shl     si, cl
	dec     si              ; SI = mask for extra bits
	and     si, [bx+sDEC.bitbuff]; Get extra bits value
	shl     di, 1
	add     si, [bx+di+sDEC.LenBase]; Add to base value
;                xor     ax, ax
	mov     al, cl
	call    WasteBits       ; Consume extra bits
	test    ax, ax
	jnz     @@ret_306

; AX == 0
	mov     di, si
@@_31:
; Adjust to length range
	add     di, 100h
	jmp     @@ret_di
@@BinLit:
; --- Binary LITERAL ---
	mov     ax, 1
	call    WasteBits       ; Consume 1 bit
	test    ax, ax
	jz      @@_32

@@ret_306:
	mov     ax, h_306       ; Abort
	jmp     @@ret

@@_32:
; AX == 0
	cmp     [bx+sDEC.c_type], ax; Check if c_type is BINARY
	jnz     @@ASCII_mode    ; If ASCII, jump

; --- Binary Literal (c_type=0) ---
	mov     di, [bx+sDEC.bitbuff]; 16-bit buffer for processing input data
	and     di, 0FFh        ; Get next 8 bits
	mov     ax, 8

@@loop_01:
	call    WasteBits       ; Consume 8 bits
	test    ax, ax
	jnz     @@ret_306
; AX == 0
; literal
	jmp     @@ret_di

@@ASCII_mode:
; --- ASCII mode literal/length ---
	xor     ax, ax
	mov     al, byte ptr [bx+sDEC.bitbuff]
	test    ax, ax
	jz      @@next_1

	mov     di, ax
	mov     al, [bx+di+sDEC.ASC_lvl_01]; Use level 1 table
	mov     di, ax

	cmp     ax, 0FFh
	jnz     @@next_3

; AX == 255
	test    byte ptr [bx+sDEC.bitbuff], 3Fh; 16-bit buffer for processing input data
	jz      @@_33

	mov     ax, 4
	call    WasteBits
	test    ax, ax
	jnz     @@ret_306

; AX == 0
	mov     si, [bx+sDEC.bitbuff]; 16-bit buffer for processing input data
	and     si, 0FFh
	mov     di, word ptr [bx+si+sDEC.ASC_lvl_02]; Use level 2 table
	jmp     @@next_2

@@_33:
	mov     ax, 6
	call    WasteBits
	test    ax, ax
	jnz     @@ret_306

; AX == 0
	mov     si, [bx+sDEC.bitbuff]; 16-bit buffer for processing input data
	and     si, 7Fh
	mov     di, word ptr [bx+si+sDEC.ASC_lvl_03]; Use level 3 table
	jmp     @@next_2

@@next_1:
	mov     ax, 8
	call    WasteBits
	test    ax, ax
	jnz     @@ret_306

; AX == 0
	mov     si, [bx+sDEC.bitbuff]; 16-bit buffer for processing input data
	and     si, 0FFh
	mov     di, word ptr [bx+si+sDEC.ASC_lvl_04]; Use level 4 table

@@next_2:
	and     di, 0FFh

@@next_3:
; DI now has the decoded value
	xor     ax, ax
	mov     al, [bx+di+sDEC.ChBitsAsc]; Get bit length

	jmp     @@loop_01       ; Consume bits and return

@@ret_di:
	mov     ax, di          ; Return value in AX

@@ret:
	retn
DecodeLIT endp


; ==========================================================================
;
; Decodes a distance value
;
; In:
;   DI = length (used to check for length==2)
;
; Out:
;   AX = Decoded distance
;
DecodeDist proc near
; DI = length
	xor     ax, ax
	mov     al, byte ptr [bx+sDEC.bitbuff]; 16-bit buffer for processing input data
	mov     si, ax
	mov     al, [bx+si+sDEC.DistPosCode]; Use fast lookup table
	mov     si, ax          ; SI = base distance code

	mov     al, [bx+si+sDEC.Dst_Bits]; AL = bit length for this code
	call    WasteBits       ; Consume bits
	test    ax, ax
	jnz     @@ret_0

	cmp     di, 2           ; Check if length == 2
	jnz     @@GT_2          ; Special handling for len 2

; --- Distance for Length 2 ---
	shl     si, 1
	shl     si, 1           ; SI = base * 4
	mov     al, byte ptr [bx+sDEC.bitbuff]; 16-bit buffer for processing input data
	and     ax, 3           ; Get 2 extra bits
	or      si, ax          ; SI = (base * 4) + extra_bits
	mov     ax, di          ; AX = 2 (bit count)
	jmp     @@_34

@@GT_2:
; --- Distance for Length > 2 ---
	xor     cx, cx
	mov     cl, byte ptr [bx+sDEC.dsizebits]
	shl     si, cl          ; SI = base << dsizebits
	mov     ax, [bx+sDEC.dsizemask]; Dict size bitmask
	and     ax, [bx+sDEC.bitbuff]; Get extra bits
	or      si, ax          ; SI = (base << dsizebits) | extra_bits
	mov     al, cl          ; AX = dsizebits (bit count)
@@_34:
	call    WasteBits       ; Consume extra bits
	test    ax, ax
	jnz     @@ret_0

	mov     ax, si
	inc     ax              ; Distance = value + 1
	jmp     @@ret

@@ret_0:
	xor     ax, ax          ; Abort
@@ret:
	retn
DecodeDist endp

; ==========================================================================
;
; Consumes a specified number of bits from the input stream
;
; In:
;   AX = number of bits to waste (consumed by xchg)
WasteBits proc  near
	mov     cx, ax          ; CX = bits to waste

	mov     ch, byte ptr [bx+sDEC.extrabits]; CH = bits available
	cmp     ch, cl
	jb      @@_35           ; Not enough bits, need to read more

; --- Enough bits in buffer ---
	shr     [bx+sDEC.bitbuff], cl; Consume bits
	sub     ch, cl
	mov     byte ptr [bx+sDEC.extrabits], ch; Save new bit count

	xor     ax, ax          ; Return 0 (Success)
	retn

@@_35:
; --- Not enough bits, need to read ---
	push    di

	xchg    cl, ch          ; CL = bits available

	shr     [bx+sDEC.bitbuff], cl; Consume available bits
	mov     di, [bx+sDEC.in_pos]; Position in in_buff

	cmp     [bx+sDEC.inbytes], di; Number of bytes in input buffer
	ja      @@_36           ; Still data in input buffer

; --- Input buffer is empty, read more ---

	push    cx
	push    si

	mov     [bx+sDEC.in_pos], d_2048; Position in in_buff
	lea     ax, [bx+sDEC.inbuff]; Buffer for data to be decompressed
	push    ds
	push    ax              ; Arg 1: buffer
	lea     ax, [bx+sDEC.in_pos]; Position in in_buff
	push    ds
	push    ax              ; Arg 2: size

	push    ds
	pop     es
	mov     ax, cs:saveDS
	mov     ds, ax
	call    es:[bx+sDEC.DECread]
; Reload sDEC pointer
	lds     bx, cs:ptrDEC
	pop     si
	pop     cx

	mov     [bx+sDEC.inbytes], ax; Number of bytes in input buffer
	test    ax, ax
	mov     ax, 1           ; AX=1 (Error)
	jz      @@ret           ; If 0 bytes read, return error

	xor     di, di          ; Reset input buffer pos

@@_36:
; --- Refill bitbuff from inbuff ---
	xor     ax, ax
	mov     ah, [bx+di+sDEC.inbuff]; AH = new byte
	or      [bx+sDEC.bitbuff], ax; Add new byte to bitbuff
	inc     di
	sub     ch, cl          ; CH = bits needed
	mov     cl, ch
	shr     [bx+sDEC.bitbuff], cl; Consume needed bits
	neg     cl
	add     cl, 8
	mov     byte ptr [bx+sDEC.extrabits], cl; New number of bits
	mov     [bx+sDEC.in_pos], di; Position in in_buff
	xor     ax, ax          ; Return 0 (Success)

@@ret:
	pop     di
	retn
WasteBits endp


; ==========================================================================
;
; Generates a fast decode lookup table
;
; In:
;   AX = number of codes
;   DX -> bit lengths table
;   SI -> codes table
;   DI -> output lookup table
;
GenDecodeTab proc near
	push    bp
	push    bx

	mov     bx, ax
	dec     bx              ; BX = code index (AX-1 down to 0)

@@loop_1:
; For each code...
	add     bx, dx
	mov     cl, [bx]        ; CL = bit length
	sub     bx, dx
	mov     ax, 1
	shl     ax, cl          ; AX = 2^CL

	mov     bp, cs:[bx+si]  ; BP = code
	and     bp, 0FFh

@@loop_2:
; --- Fill all table entries that start with this code ---
	mov     ds:[bp+di], bl  ; Store the value (code index)
	add     bp, ax          ; Jump to next entry
	cmp     bp, 0FFh
	jbe     @@loop_2

	dec     bx
	jge     @@loop_1        ; Loop for all codes

	pop     bx
	pop     bp
	retn
GenDecodeTab endp

; ==========================================================================
;
; Generates the multi-level ASCII decode tables
;
GenAscTab proc  near
	push    bp

	mov     si, 255         ; For each code 255 down to 0...

@@loop_genasc:
	mov     dx, 11111111b   ; DX = 0xFF (mask)

	shl     si, 1
	mov     bp, cs:TabChCodeAsc[si]; DI = code
	shr     si, 1

	xor     cx, cx
	mov     di, offset sDEC.ASC_lvl_01; Default to level 1 table

	mov     al, [si+bx+sDEC.ChBitsAsc]; AL = bit length
	cmp     al, 8
	jbe     @@_37

	test    bp, dx
	jz      @@next

	mov     di, bp
	and     di, dx
	mov     [di+bx+sDEC.ASC_lvl_01], dl; Mark as "needs level 2"

	mov     cl, 4
	mov     di, offset sDEC.ASC_lvl_02; Use level 2 table

	test    bp, 3Fh
	jnz     @@_37

	mov     cl, 6
	mov     di, offset sDEC.ASC_lvl_03; Use level 3 table

	mov     dx, 7Fh
	jmp     @@_37

@@next:
	mov     cl, 8
	mov     di, offset sDEC.ASC_lvl_04; Use level 4 table

@@_37:
	shr     bp, cl          ; DI = code >> shift
	sub     al, cl
	mov     [si+bx+sDEC.ChBitsAsc], al; Save remaining bit length
	xchg    ax, cx          ; CX = bit length
	mov     ax, 1
	shl     ax, cl          ; AX = 2^CL
	add     di, bx

	mov     cx, si
@@_38:
; --- Fill table entries ---
	mov     ds:[di+bp], cl  ; Store low byte (SI)
	add     bp, ax

	cmp     bp, dx
	jbe     @@_38

	dec     si
	jge     @@loop_genasc

	pop     bp
	retn
GenAscTab endp

PK_TEXT ends

	end
