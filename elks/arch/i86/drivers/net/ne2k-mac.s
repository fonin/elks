;------------------------------------------------------------------------------
; NE2K driver - low part - MAC routines
;------------------------------------------------------------------------------

; TODO: move definitions to ne2k-defs.s

; I/O base @ 300h

io_eth_command    EQU $300

io_eth_rx_first   EQU $301  ; page 0
io_eth_rx_last    EQU $302  ; page 0
io_eth_rx_get     EQU $303  ; page 0

io_eth_rx_put1    EQU $306  ; page 0 - read

io_eth_tx_start   EQU $304  ; page 0 - write
io_eth_tx_len1    EQU $305  ; page 0 - write
io_eth_tx_len2    EQU $306  ; page 0 - write

io_eth_int_stat   EQU $307  ; page 0

io_eth_dma_addr1  EQU $308  ; page 0
io_eth_dma_addr2  EQU $309  ; page 0
io_eth_dma_len1   EQU $30A  ; page 0 - write
io_eth_dma_len2   EQU $30B  ; page 0 - write

io_eth_rx_stat    EQU $30C  ; page 0 - read

io_eth_rx_conf    EQU $30C  ; page 0 - write
io_eth_tx_conf    EQU $30D  ; page 0 - write
io_eth_data_conf  EQU $30E  ; page 0 - write
io_eth_int_mask   EQU $30F  ; page 0 - write

io_eth_unicast    EQU $301  ; page 1 - 6 bytes
io_eth_rx_put2    EQU $307  ; page 1
io_eth_multicast  EQU $308  ; page 1 - 8 bytes

io_eth_data_io    EQU $310  ; 2 bytes

tx_first          EQU $40
rx_first          EQU $46
rx_last           EQU $80


	.TEXT


;-------------------------------------------------------------------------------
; Select register page
;-------------------------------------------------------------------------------

; AL : page number (0 or 1)

page_select:

	push    ax
	push    dx

	mov     ah, al
	and     ah, #$01
	shl     ah, #6

	mov     dx, #io_eth_command
	in      al, dx
	and     al, #$3F
	or      al, ah
	out     dx, al

	pop     dx
	pop     ax
	ret


;-------------------------------------------------------------------------------
; Set unicast address (aka MAC address)
;-------------------------------------------------------------------------------

; arg1 : pointer to unicast address (6 bytes)

_ne2k_addr_set:

	push    bp
	mov     bp, sp

	push    ax
	push    cx
	push    dx
	push    si

	mov     si, [bp + $4]

	; select page 1

	mov     al, #1
	call    page_select

	; load MAC address

	mov     dx, #io_eth_unicast
	mov     cx, #6
	cld

ems_loop:

	lodsb
	out     dx, al
	inc     dx
	loop    ems_loop

	pop     si
	pop     dx
	pop     cx
	pop     ax

	pop     bp
	ret


;-------------------------------------------------------------------------------
; DMA initialization
;-------------------------------------------------------------------------------

; BX : chip memory address (4000h...8000h)
; CX : byte count

dma_init:

	push    ax
	push    dx

	; select page 0

	xor     al, al
	call    page_select

	; set DMA start address

	mov     dx, #io_eth_dma_addr1
	mov     al, bl
	out     dx, al

	; mov     dx, #io_eth_dma_addr2
	inc     dx
	mov     al, bh
	out     dx, al

	; set DMA byte count

	; mov     dx, #io_eth_dma_len1
	inc     dx
	mov     al, cl
	out     dx, al

	; mov     dx, #io_eth_dma_len2
	inc     dx
	mov     al, ch
	out     dx, al

	pop     dx
	pop     ax
	ret


;-------------------------------------------------------------------------------
; Write block to chip with internal DMA
;-------------------------------------------------------------------------------

; BX    : chip memory address (to write to)
; CX    : byte count
; DS:SI : host memory address (to read from)

dma_write:

	push    ax
	push    cx
	push    dx
	push    si

	call    dma_init

	; start DMA write

	mov     dx, #io_eth_command
	in      al, dx
	and     al, #$C7
	or      al, #$10
	out     dx, al

	; I/O write loop

	mov     dx, #io_eth_data_io
	cld

emw_loop:

	lodsb
	out     dx, al
	loop    emw_loop

	; maybe check DMA completed ?

	pop     si
	pop     dx
	pop     cx
	pop     ax
	ret


;------------------------------------------------------------------------------
; Read block from chip with internal DMA
;------------------------------------------------------------------------------

; BX    : chip memory to read from
; CX    : byte count
; ES:DI : host memory to write to

dma_read:

	push    ax
	push    cx
	push    dx
	push    di

	call    dma_init

	; start DMA read

	mov     dx, #io_eth_command
	in      al, dx
	and     al, #$C7
	or      al, #$08
	out     dx, al

	; I/O read loop

	mov     dx, #io_eth_data_io
	cld

emr_loop:

	in      al, dx
	stosb
	loop    emr_loop

	; maybe check DMA completed ?

	pop     di
	pop     dx
	pop     cx
	pop     ax
	ret


;------------------------------------------------------------------------------
; Get received packet
;------------------------------------------------------------------------------

; arg1 : packet buffer to write to

; returns:

; AX : error code

_ne2k_pack_get:

	push    bp
	mov     bp,sp

	push    bx
	push    cx
	push    dx
	push    di

	xor     al,al
	call    page_select

	; get RX put pointer

	mov     dx, #io_eth_rx_put1
	in      al, dx
	mov     cl, al

	; get RX get pointer

	mov     dx, #io_eth_rx_get
	in      al, dx
	inc     al
	cmp     al, #rx_last
	jnz     npg_nowrap1
	mov     al, #rx_first

npg_nowrap1:

	; check ring is not empty

	cmp     cl, al
	jz      npg_err

	xor     bl, bl
	mov     bh, al

	; get packet header

	mov     di, [bp + 4]
	mov     cx, #4
	call    dma_read

	mov     ax, [di + 0]  ; AH : next record, AL : status
	mov     cx, [di + 2]  ; packet size (without CRC)

	add     bx, #4
	add     di, #4

	push    ax
	push    cx

	mov     ax, bx
	add     ax, cx
	cmp     ax, #$8000
	jbe     npg_nowrap2

	mov     ax, #$8000
	sub     ax, bx
	mov     cx, ax

npg_nowrap2:

	; get packet body (first segment)

	call    dma_read

	add     di, cx

	mov     ax, cx
	pop     cx
	sub     cx, ax
	jz      npg_nowrap3

	; get packet body (second segment)

	mov     bx, #$4000
	call    dma_read

npg_nowrap3:

	; update RX get pointer

	pop     ax
	xchg    ah, al
	dec     al
	cmp     al, #rx_first
	jae     npg_next
	mov     al, #rx_last - 1

npg_next:

	mov     dx, #io_eth_rx_get
	out     dx, al

	xor     ax, ax
	jmp     npg_exit

npg_err:

	mov     ax, #$FFFF

npg_exit:

	pop     di
	pop     dx
	pop     cx
	pop     bx
	pop     bp
	ret


;------------------------------------------------------------------------------
; Put packet to send
;------------------------------------------------------------------------------

; arg1 : packet buffer to read from
; arg2 : size in bytes

; returns:

; AX : error code

_ne2k_pack_put:

	push    bp
	mov     bp,sp

	push    bx
	push    cx
	push    dx
	push    si

	xor     al,al
	call    page_select

	; write packet to chip memory

	mov     cx, [bp + 6]
	xor     bl,bl
	mov     bh, #tx_first
	mov     si, [bp + 4]
	call    dma_write

	; set TX pointer and length

	mov     dx, #io_eth_tx_start
	mov     al, #tx_first
	out     dx, al

	mov     dx, #io_eth_tx_len1
	mov     al, cl
	out     dx, al
	inc     dx  ; = io_eth_tx_len2
	mov     al, ch
	out     dx, al

	; start TX

	mov     dx, #io_eth_command
	in      al, dx
	or      al, #$04
	out     dx, al

	xor     ax, ax

	pop     si
	pop     dx
	pop     cx
	pop     bx
	pop     bp
	ret


;------------------------------------------------------------------------------
; Get NE2K status
;------------------------------------------------------------------------------

; returns:

; AX : status
;   01h = packet received
;   02h = packet sent
;   10h = RX ring overflow

_ne2k_status:

	push    dx

	; select page 0

	xor     al, al
	call    page_select

	; get interrupt status

	xor     ah, ah

	mov     dx, #io_eth_int_stat
	in      al, dx
	test    al, #$3F
	jz      ns_next1

	; acknowledge interrupt

	out     dx, al

ns_next1:

	pop     dx
	ret


;-------------------------------------------------------------------------------
; NE2K initialization
;-------------------------------------------------------------------------------

_ne2k_init:

	push    cx
	push    dx

	; select page 0

	xor     al,al
	call    page_select

	; Stop DMA and MAC
	; TODO: is this really needed after a reset ?

	mov     dx, #io_eth_command
	in      al, dx
	and     al, #$C0
	or      al, #$21
	out     dx, al

	; data I/O in single bytes
	; and low endian for 80188
	; plus magical stuff (48h)

	mov     dx, #io_eth_data_conf
	mov     al, #$48
	out     dx, al

	; accept packet without error
	; unicast & broadcast only

	mov     dx, #io_eth_rx_conf
	mov     al, #$44
	out     dx, al

	; half-duplex and internal loopback
	; to insulate the MAC while stopped
	; TODO: loopback cannot be turned off later !

	mov     dx, #io_eth_tx_conf
	mov     al, #0  ; 2
	out     dx, al

	; set RX ring limits
	; all 16KB on-chip memory
	; except one TX frame at beginning (6 x 256B)

	mov     dx, #io_eth_rx_first
	mov     al, #rx_first
	out     dx, al

	mov     dx, #io_eth_rx_last
	mov     al, #rx_last
	out     dx, al

	mov     dx, #io_eth_tx_start
	mov     al, #tx_first
	out     dx, al

	; set RX get pointer

	mov     dx, #io_eth_rx_get
	mov     al, #rx_first
	out     dx, al

	; clear DMA length
	; TODO: is this really needed after a reset ?

	xor     al, al
	mov     dx, #io_eth_dma_len1
	out     dx, al
	inc     dx  ; = io_eth_dma_len2
	out     dx, al

	; clear all interrupt flags

	mov     dx, #io_eth_int_stat
	mov     al, #$FF
	out     dx, al

	; set interrupt mask
	; TX & RX without error and overflow

	mov     dx, #io_eth_int_mask
	mov     al, #$13
	out     dx, al

	; select page 1

	mov     al, #1
	call    page_select

	; clear unicast address

	mov     cx, #6
	mov     dx, #io_eth_unicast
	xor     al, al

ei_loop_u:

	out     dx, al
	inc     dx
	loop    ei_loop_u

	; clear multicast bitmap

	mov     cx, #8
	mov     dx, #io_eth_multicast
	xor     al, al

ei_loop_m:

	out     dx, al
	inc     dx
	loop    ei_loop_m

	; set RX put pointer to first bloc + 1

	mov     dx, #io_eth_rx_put2
	mov     al, #rx_first
	inc     al
	out     dx, al

	; return no error

	xor     ax,ax

	pop     dx
	pop     cx
	ret


;-------------------------------------------------------------------------------
; NE2K startup
;-------------------------------------------------------------------------------

_ne2k_start:

	push    dx

	; start the transceiver

	mov     dx, #io_eth_command
	in      al, dx
	and     al, #$FC
	or      al, #$02
	out     dx, al

	; move out of internal loopback

	; TODO: read PHY status to update the duplex mode ?

	mov     dx, #io_eth_tx_conf
	xor     al, al
	out     dx, al

	xor     ax, ax

	pop     dx
	ret


;-------------------------------------------------------------------------------
; NE2K stop
;-------------------------------------------------------------------------------

_ne2k_stop:

	push    ax
	push    dx

	; Stop the DMA and the MAC

	mov     dx, #io_eth_command
	in      al, dx
	and     al, #$C0
	or      al, #$21
	out     dx, al

	; select page 0

	xor     al, al
	call    page_select

	; half-duplex and internal loopback
	; to insulate the MAC while stopped
	; and ensure TX finally ends

	mov     dx, #io_eth_tx_conf
	mov     al, #2
	out     dx, al

	; clear DMA length

	xor     al, al
	mov     dx, #io_eth_dma_len1
	out     dx, al
	inc     dx  ; = io_eth_dma_len2
	out     dx, al

	; TODO: wait for the chip to get stable

	pop     dx
	pop     ax
	ret


;-------------------------------------------------------------------------------
; NE2K termination
;-------------------------------------------------------------------------------

; call ne2k_stop() before

_ne2k_term:

	push    ax
	push    dx

	; select page 0

	xor     al, al
	call    page_select

	; mask all interrrupts

	mov     dx, #io_eth_int_mask
	xor     al,al
	out     dx, al

	pop     dx
	pop     ax
	ret


;------------------------------------------------------------------------------
; NE2K reset
;------------------------------------------------------------------------------

_ne2k_reset:

	push    ax
	push    dx

	; reset the chip

	mov     dx,#$31F  ; reset register
	in      al, dx
	out     dx, al

	; manual wait for reset
	; TODO: replace by wait function

	int     #3

	pop     dx
	pop     ax
	ret


;------------------------------------------------------------------------------

	EXPORT  _ne2k_addr_set
	EXPORT  _ne2k_pack_get
	EXPORT  _ne2k_pack_put
	EXPORT  _ne2k_status

	EXPORT  _ne2k_init
	EXPORT  _ne2k_term

	EXPORT  _ne2k_start
	EXPORT  _ne2k_stop

	EXPORT  _ne2k_reset

	END

;------------------------------------------------------------------------------
