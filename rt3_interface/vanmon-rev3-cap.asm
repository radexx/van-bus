  list p=16f876, st=OFF, x=OFF, n=0
  errorlevel -302
  #include <p16f876.inc>

  __config _PWRTE_ON & _WDT_OFF & _HS_OSC

;
; Command list:
;
; c              = Start capture packets. Filtered addresses is shown "(5E4,554)"
;                  when the capturing is started. Stop with ESC key
;
; -XXX0          = Hide packets with address XXX (for example "-5E40")
;                  Max 32 packet addresses can be hidden during capture. The list
;                  is not checked for duplicates
;
; +              = Show all packets
;
; tXXX*ZZZZ..    = Transmit packet to address XXX with command bits *
;                  Valid command bits are "C" (Write+RAK) or "8" (Write only) 
;
; rXXXF          = Read packet from address XXX
;
;

; I/O port usage:
;
; RA0             = VAN received data
; RA1
; RA2
; RA3             = VAN transmit data (active high)
; RA4
; RA5             
;
; RB0             = VAN received data
; RB1
; RB2
; RB3
; RB4             = Status LED 
; RB5
; RB6             = ICD
; RB7             = ICD
;
; RC0
; RC1
; RC2             
; RC3             
; RC4             
; RC5             
; RC6             = RS232 TX
; RC7             = RS232 RX





; Constants

CMDBUFF_LEN   EQU 0x20      ; Length of command buffer
TX_DELAY      EQU 0x80      ; Delay in clk/4 before transmitting
                            ; 0x80 = 128*4*0.2 us = 102.4 us

MODE_NONE     EQU 0x00      ; Modes for main_mode variable
MODE_CAPTURE  EQU 0x01

; RAM variables

    CBLOCK        0x20

    crc_h:          1       ; CRC high byte, used by _CalcCrc
    crc_l:          1       ; CRC low byte, used by _CalcCrc
    crc_bit:        1       ; CRC bit counte, used by _CalcCrc
    crc_count:      1       ; CRC byte counter, used by _CalcCrc

    tx_bytes:       1       ; No of bytes to transmit (incl CRC)
    tx_byte_buf:    1       ; Byte to transmit
    tx_output_buf:  1       ; Bits during transmission
    tx_nibblecnt:   1       ; Count bits during transmission
    tx_delay:       1       ; Timedelay
    tx_status:      1       ; Status for transmitting packets
    tx_retries:     1       ; Number of transmission retries
    
    rx_input_buf:   1       ; Input buffer
    rx_delay:       1       ; Timedelay
    rx_bytes:       1       ; No of bytes received
    rx_fsr:         1       ; Temporary storage for FSR pointer
    rx_curr_buf:    1       ; Current buffer (0x10, 0x30, 0x50) to write to
    
    rx_rtr:         1       ; Handle RTR data
    rx_rtaddr_l:    1       ; VAN RTR address LSB
    rx_rtaddr_h:    1       ; VAN RTR address MSB
    rx_rtdata_len:  1       ; VAN RTR data length (incl CRC but not address)
    
    rx_reply1_l:    1       ; PIC VAN address 1 (LSB) 
    rx_reply1_h:    1       ; PIC VAN address 1 (MSB)    
    rx_reply2_l:    1       ; PIC VAN address 2 (LSB) 
    rx_reply2_h:    1       ; PIC VAN address 2 (MSB)     
    rx_reply_data:  1       ; Temporary variable for handling PIC VAN addr
    

    rx232_bytes:    1       ; Bytes left in rs232 buffer to transmit
    rs232_txptr:    1       ; Pointer to next byte in rs232 buffer to transmit
    rs232_temp:     1       ; Temporary RS232 variable
    rs232_txinptr:  1       ; Pointer to where to add data in tx queue
    
    dec_count:      1       ; Counter when decoding packages
    dec_ptr:        1       ; Byte pointer to packet buffer while decoding
    dec_temp:       1       ; Temporary variable
    dec_data:       1
    dec_readfrom:   1

    main_inptr:     1       ; Pointer to cmd bytes read    
    main_readfrom:  1       ; Packet buffer to read from
    main_inchar:    1       ; Character read from RS232 port
    main_mode:      1       ; Current mode of operation
    main_txcount:   1       ; Bytes to transmit by the "t" command
    
    hex_temp:       1       ; Hex conversion temporary variable
        
    ENDC

   CBLOCK       0x71        ; Common registers

    int_w:        0x01      ; Save W register during interrupt
    int_stat:     0x01      ; Save STATUS register during interrupt    
    int_fsr:      0x01      ; Save FSR register
    int_pclath:   0x01      ; Save PCLATH register
        
    ENDC

    CBLOCK        0x0a0
    txbuffer:     0x20      ; Packet transmission buffer
    cmd_buffer:   CMDBUFF_LEN   ; Command buffer
    
    ENDC

    CBLOCK        0x110
    rxbuffer1:    0x20
    rxbuffer2:    0x20
    rxbuffer3:    0x20          
    ENDC

    CBLOCK        0x190
    rtr_buffer:   0x20      ; Buffer for RTR of data
    rs232tx_buff: 0x40      ; Buffer for data to send using serial port
    
    ENDC

Bank0   MACRO     ; Macro to select data RAM bank 0
    bcf STATUS,RP0
    bcf STATUS,RP1
    ENDM

Bank1   MACRO     ; Macro to select data RAM bank 1
    bsf STATUS,RP0
    bcf STATUS,RP1
    ENDM

Bank2   MACRO     ; Macro to select data RAM bank 2
    bcf STATUS,RP0
    bsf STATUS,RP1
    ENDM

Bank3   MACRO     ; Macro to select data RAM bank 3
    bsf STATUS,RP0
    bsf STATUS,RP1
    ENDM
    
Tx232   MACRO     ; Send W to serial port
    bsf     STATUS,RP0
    bcf     STATUS,RP1
    btfss   TXSTA,TRMT
    goto    $-2
    bcf     STATUS,RP0
    movwf   TXREG
    ENDM

;---------------------------

    ORG 0x0000 

_ResetVector: 
  clrf    PCLATH          ; Set page bits for page0
  goto    _Main           ; Go to startup code


;---------------------------

    ORG 0x0004

_Interrupt:
  movwf   int_w           ; Save status
  swapf   STATUS,W
  movwf   int_stat
  movf    FSR,W
  movwf   int_fsr 
  movf    PCLATH,W
  movwf   int_pclath
  clrf    PCLATH
  Bank0
  bsf     PORTB,4
  nop
  bcf     PORTB,4

  btfss   INTCON,INTF     ; INT signal interrupt
  goto    _NotInt 
  call    _VAN_rx

  bcf     INTCON,INTF
  movlw   0x00-TX_DELAY
  movwf   TMR2
  bcf     PIR1,TMR2IF
  
_NotInt:
  btfss   PIR1,TMR2IF
  goto    _IntEnd
  btfss   tx_status,7
  goto    _IntTxOk
  movf    tx_status,W
  andlw   0x1f
  call    _VAN_tx
  bcf     PIR1,TMR2IF
  movwf   rx_delay
  decfsz  tx_retries,F
  goto    _IntChk
  goto    _IntTxFailed
_IntChk:  
  movf    rx_delay,W  
  sublw   0x02
  btfsc   STATUS,Z
  goto    _IntEnd
_IntTxFailed:
  movf    rx_delay,W
  movwf   tx_status
  
_IntTxOk:
  Bank1
  bcf     PIE1,TMR2IE
  Bank0
  bcf     PIR1,TMR2IF
  clrf    T2CON             

_IntEnd:
  movf    int_pclath,W
  movwf   PCLATH
  movf    int_fsr,W
  movwf   FSR 
  swapf   int_stat,W    ; Restore status
  movwf   STATUS
  swapf   int_w,F
  swapf   int_w,W
  retfie        


;---------------------------
; Convert W to hex character
;
; Input:  W - Value to convert
;
; Output: Ascii character 0..9, A..F

_HexConv:
  clrf    PCLATH
  andlw   0x0f
  addwf   PCL,F
  retlw   '0'
  retlw   '1'
  retlw   '2'
  retlw   '3'
  retlw   '4'
  retlw   '5'
  retlw   '6'
  retlw   '7'
  retlw   '8'
  retlw   '9'
  retlw   'A'
  retlw   'B'
  retlw   'C'
  retlw   'D'
  retlw   'E'
  retlw   'F'


_Main:

  bcf     INTCON,7    ; Disable all interrupts

  Bank1 

  movlw   0x0a        ; Set baud rate 115200
  movwf   SPBRG 
  movlw   0x24        ; Transmitter enable, asyncronus mode, high speed mode
  movwf   TXSTA
  
  movlw   0x06        ; Switch off ADC
  movwf   ADCON1
  
  movlw   0x37        ; Bit 0 : VAN Input, Bit 3 : VAN Output
  movwf   TRISA      
  movlw   0xef        ; Bit 0 : VAN Input, Bit 4 : Status LED Output
  movwf   TRISB 

  bcf     OPTION_REG,INTEDG
  
  Bank0
    
  movlw   0x90        ; Enable Serial port and Receiver
  movwf   RCSTA

  
  ; Ready

  Bank0

  clrf    rx232_bytes
  clrf    rs232_txptr
  clrf    rs232_txinptr
  clrf    main_inptr
  movlw   MODE_CAPTURE
  movwf   main_mode
  movlw   0x10
  movwf   rx_curr_buf
  movwf   main_readfrom
  
  Bank2
  clrf    rxbuffer1       ; Clear all packet buffers
  clrf    rxbuffer2
  clrf    rxbuffer3

  Bank3
  movlw   0xff            ; Disable RTR buffer
  movwf   0x190        
  movlw   0xf0      
  movwf   0x191      

  Bank0
  movlw   0x0d
  movwf   rx_rtdata_len
  
  movlw   low rtr_buffer  ; Setup FSR to point to first byte in
  movwf   FSR             ; RTR package buffer  
  bsf     STATUS,IRP      ; Point to packet buffer at 0x190 in RAM
  movf    INDF,W
  movwf   rx_rtaddr_h
  incf    FSR,F
  movf    INDF,W
  andlw   0xf0
  movwf   rx_rtaddr_l

  movlw   0x8e
  movwf   rx_reply1_h
  movlw   0xc0
  movwf   rx_reply1_l 

  movlw   0xff            ; Disable ACK answer addr 2
  movwf   rx_reply2_h
  movwf   rx_reply2_l

  bsf     INTCON,PEIE   
  bsf     INTCON,INTE
  bsf     INTCON,GIE      ; Enable all interrupts 

_WritePrompt: 
  movlw   0x0d            ; Write < CR > 
  call    _QueueRs232
  movlw   '>'             ; Write ">" (prompt)
  call    _QueueRs232

  
_WaitCmd:
  
  call    _SendRs232      ; Send any buffered RS232 data
  
  Bank0
  btfss   RCSTA,1         ; Check for owerrun Error
  goto    _NoRXErr  
  bcf     RCSTA,CREN      ; Clear RS232 receiver
  bsf     RCSTA,CREN
_NoRXErr: 
  btfss   PIR1,RCIF       
  goto    _NoRs232Rx
  movf    RCREG,W
  call    _InterpretCmd
  movwf   main_inchar
  sublw   0x02
  btfsc   STATUS,Z
  goto    _WritePrompt
  
_NoRs232Rx:
  movf    main_mode,W
  andlw   0x0f
  sublw   MODE_CAPTURE
  btfss   STATUS,Z
  goto    _WaitCmd  

  movf    main_readfrom,W
  movwf   FSR
  bsf     STATUS,IRP
  movf    INDF,W
  btfsc   STATUS,Z
  goto    _MoveOn
  
  movf    main_readfrom,W
  call    _EEFilter
  movf    main_readfrom,W
  btfss   STATUS,C
  call    _HexDecodePacket  
  
  movf    main_readfrom,W
  movwf   FSR
  bsf     STATUS,IRP
  clrf    INDF

_MoveOn:
  movlw   0x20
  addwf   main_readfrom,F
  movf    main_readfrom,W
  sublw   low rxbuffer3+0x20
  movlw   low rxbuffer1
  btfsc   STATUS,Z
  movwf   main_readfrom

  goto    _WaitCmd
    
  
;-----------------------------------------------------------------------
; Interpret command from RS232 port
;
; Input: W = Received character

_InterpretCmd:
  movwf   main_inchar
  
  sublw   0x08            ; Is it DEL key?
  btfss   STATUS,Z
  goto    _Rx232NotDel  
  movf    main_inptr,W
  btfsc   STATUS,Z        ; Are there any characters in the buffer?
  retlw   0x00
  decf    main_inptr,F
  movlw   0x08            ; Yes - erase the last character in 
  call    _QueueRs232     ; input buffer
  movlw   ' '
  call    _QueueRs232
  movlw   0x08
  call    _QueueRs232
  retlw   0x00
  
_Rx232NotDel:
  movf    main_inchar,W   ; Is it CR ?
  sublw   0x0d
  btfss   STATUS,Z
  goto    _KeyNotCR

_Rx232interp:
  movlw   LOW cmd_buffer
  movwf   FSR
  bcf     STATUS,IRP      ; Point to cmd buffer at 0x0a0 in RAM
  
  movf    INDF,W          ; Is it capture command?
  sublw   'c'
  btfss   STATUS,Z
  goto    _CmdNotCapt
  movlw   MODE_CAPTURE    ; Start capture
  movwf   main_mode

  movlw   0x0d            ; Write < CR > 
  call    _QueueRs232
  call    _DispFilterAddr
  Bank2
  clrf    rxbuffer1       ; Clear all packet buffers
  clrf    rxbuffer2
  clrf    rxbuffer3
  Bank0
  clrf    main_inptr      ; Clear buffer
  retlw   0x00  
  
_CmdNotCapt:

  movf    INDF,W          ; Is it transmit command?
  sublw   't'
  btfss   STATUS,Z
  goto    _CmdNotTransm

  call    _DecodeParam
  movwf   main_txcount
  movwf   main_inptr
  btfsc   STATUS,C
  goto    _CmdInvChar
  
  Bank1                   ; Ensure Write cmd bit is correct
  movf    low txbuffer+1,W
  andlw   0xfc
  iorlw   0x08
  movwf   low txbuffer+1
  Bank0
  
_SendPackage:
  movf    main_txcount,W  ; Send the packet
  call    _Tx_Packet
  movwf   tx_bytes
  andlw   0x0f
  sublw   0x04
  btfss   STATUS,Z
  goto    _NoReqRepl

  movlw   0x0d            ; Write < CR > 
  call    _QueueRs232 
  
  movf    tx_bytes,W
  andlw   0x70
  call    _HexDecodePacket  
  
  movf    tx_bytes,W      ; Clear packet lenght byte
  andlw   0x70
  movwf   FSR
  bsf     STATUS,IRP
  clrf    INDF
  
  clrf    main_inptr      ; Clear buffer  
  retlw   0x02
  
_NoReqRepl:
  movlw   0x0d            ; Write < CR > 
  call    _QueueRs232 
  btfsc   tx_bytes,0
  goto    _CmdTxGotAck
  movlw   'N'
  call    _QueueRs232
  movlw   'O'
  call    _QueueRs232
  movlw   ' '
  call    _QueueRs232
_CmdTxGotAck:
  movlw   'A'
  call    _QueueRs232
  movlw   'C'
  call    _QueueRs232
  movlw   'K'
  call    _QueueRs232

  clrf    main_inptr      ; Clear buffer
  retlw   0x02
  
_CmdInvChar:
  movlw   '?'             ; Write < ? > 
  call    _QueueRs232

  clrf    main_inptr      ; Clear buffer
  retlw   0x02
  
_CmdNotTransm:
  movf    INDF,W          ; Is it read command?
  sublw   'r'
  btfss   STATUS,Z
  goto    _CmdNotRead

  call    _DecodeParam
  movwf   main_txcount
  btfsc   STATUS,C
  goto    _CmdInvChar
  
  Bank1
  movlw   0x0f
  iorwf   low txbuffer+1,F
  Bank0
  goto    _SendPackage

_CmdNotRead:
  movf    INDF,W          ; Is it filter hide ("-") command?
  sublw   '-'
  btfss   STATUS,Z
  goto    _CmdNotFiltHide

  call    _DecodeParam    ; Decode parameters
  movwf   main_txcount
  btfsc   STATUS,C        ; Exit if invalid characters
  goto    _CmdInvChar
  btfsc   main_txcount,0  ; Exit if odd number of addresses
  goto    _CmdInvChar
  
  clrf    main_inptr      ; Find next free position in data EEPROM
_CmdFilt1L:
  movf    main_inptr,W
  call    _EERead
  btfsc   STATUS,Z
  goto    _CmdHF          ; Found the end position
  incf    main_inptr,F
  incf    main_inptr,F
  btfsc   main_inptr,6
  goto    _CmdInvChar     ; Reached end (32 addresses exists)
  goto    _CmdFilt1L
    
_CmdHF: 
  Bank1
  movf    txbuffer,W      ; Store new address to filter last
  call    _EEWrite        ; in the EEPROM (MSB)
  Bank2
  incf    EEADR,F
  Bank1
  movf    txbuffer+1,W
  call    _EEWrite        ; Store packet address LSB
  Bank2
  incf    EEADR,F
  btfsc   EEADR,6
  goto    _CmdHFOk        ; 32 addresses has been stored -> exit
  clrw
  call    _EEWrite        ; Add 0x00 0x00 to EEPROM
  Bank2
  incf    EEADR,F
  clrw
  call    _EEWrite
_CmdHFOk
  movlw   ' '
  call    _QueueRs232 
  call    _DispFilterAddr
  Bank0       
  clrf    main_inptr      ; Clear buffer
  retlw   0x02
  
_CmdNotFiltHide:
  movf    INDF,W          ; Is it filter show all ("+") command?
  sublw   '+'
  btfss   STATUS,Z
  goto    _CmdNotFiltShow

  Bank2
  clrf    EEADR           ; Write 0x00, 0x00 to EEPROM[0x00..0x01] to
  clrw                    ; disable all filtered addresses
  call    _EEWrite
  Bank2
  incf    EEADR,F
  clrw
  call    _EEWrite
  Bank0     
  call    _DispFilterAddr
  clrf    main_inptr      ; Clear buffer
  retlw   0x02
  

_CmdNotFiltShow:
  movlw   0x0d            ; Write < CR > 
  call    _QueueRs232
  movlw   '?'             ; Write < ? > 
  call    _QueueRs232
  movlw   0x0d            ; Write < CR > 
  call    _QueueRs232
  clrf    main_inptr      ; Clear buffer
  retlw   0x02
  
_KeyNotCR:
  movf    main_inchar,W   ; Is it Esc
  sublw   0x1b
  btfss   STATUS,Z
  goto    KeyNotEsc

  movf    main_mode,W     ; Ignore key of no special mode
  btfsc   STATUS,Z
  retlw   0x00
    
  movlw   MODE_NONE       ; Stop capturing packets
  movwf   main_mode
  retlw   0x02            ; Write command prompt again
    
KeyNotEsc:
  movf    main_inchar,W   ; Is it CR ?
  sublw   0xa7
  btfss   STATUS,Z
  goto    _KeyNotPar
  movlw   0x4f
  xorwf   rx_rtaddr_l,F
  retlw   0x00
  
_KeyNotPar:
  movf    main_inptr,W    ; Check if buffer is filled
  sublw   CMDBUFF_LEN
  btfsc   STATUS,Z
  retlw   0x01
  
  movf    main_inptr,W    ; No, add character
  addlw   LOW cmd_buffer
  movwf   FSR
  bcf     STATUS,IRP      ; Point to cmd buffer at 0x0a0 in RAM
  incf    main_inptr,F
  
  movf    main_inchar,W
  movwf   INDF
  goto    _QueueRs232     ; Print character

  btfss   main_inptr,0
  goto    _CmdInvChar

;-----------------------------------------------------------------------
; Decode hex parameters in command
;
; Input:  -
;
; Output: C = 0 : W = No of bytes 
;         C = 1 : Invalid character
;

_DecodeParam:
  clrf    main_txcount

  btfss   main_inptr,0
  goto    _DecFailed
  
_DecNextByte:
  incf    main_txcount,W
  addwf   main_txcount,W
  subwf   main_inptr,W
  btfsc   STATUS,Z
  goto    _DecFinished
  
  movf    main_txcount,W
  addwf   main_txcount,W
  andlw   0x3e
  addlw   LOW cmd_buffer+1
  movwf   FSR
  bcf     STATUS,IRP      ; Point to cmd buffer at 0x0a0 in RAM

  movf    INDF,W
  call    _HexDecode
  btfsc   STATUS,C
  goto    _DecFailed
  movwf   tx_bytes
  swapf   tx_bytes,F
  incf    FSR,F
  movf    INDF,W
  call    _HexDecode
  btfsc   STATUS,C
  goto    _DecFailed
  iorwf   tx_bytes,F

  movf    main_txcount,W
  addlw   low txbuffer    
  movwf   FSR             ; package buffer  
  bcf     STATUS,IRP      
  
  movf    tx_bytes,W
  movwf   INDF
  
  incf    main_txcount,F
  goto    _DecNextByte  
  
_DecFailed:
  bsf     STATUS,C
  return
  
  
_DecFinished:
  movf    main_txcount,W
  bcf     STATUS,C
  return

;-----------------------------------------------------------------------
; Convert Hex Ascii to hex
;
; Input: W = Ascii character
;
; Output: C = 0, W = value 
;         C = 1 : Invalid character
;

_HexDecode:
  movwf   hex_temp
  sublw   0x2f
  btfsc   STATUS,C
  goto    _HexInvChar
  movf    hex_temp,W
  sublw   0x39
  btfss   STATUS,C
  goto    _HexChkAF
  movlw   0x30
  subwf   hex_temp,W
  bcf     STATUS,C
  return
_HexChkAF:
  movf    hex_temp,W
  sublw   0x40
  btfsc   STATUS,C
  goto    _HexInvChar
  movf    hex_temp,W
  sublw   0x46
  btfss   STATUS,C
  goto    _HexInvChar
  movlw   0x37
  subwf   hex_temp,W
  bcf     STATUS,C
  return  
_HexInvChar:
  bsf     STATUS,C
  retlw   0x00

;-----------------------------------------------------------------------
; Calculate 15-bit CRC
;
; Input: W = Number of bytes in VAN package (excluding CRC)
;        FSR register must point to the first byte in the VAN package
;
; Output: crc_h (MSB) and crc_l (LSB) inverted and rotated checksum
;         bit 0 of LSB is always zero.
;         FSR will point to the byte in packet where the MSB of CRC
;         shall be stored to.
;

_CalcCrc:
  movwf   crc_count   ; Bytes to calculate checksum for

  movlw   0xff        ; Setup CRC start value
  movwf   crc_l
  movwf   crc_h
  
_CrcByte:
  movlw   0x08        ; 8 bits in each byte
  movwf   crc_bit

_CrcBit:
  rlf     INDF,W      ; Load MSB into carry so buffer contents
  rlf     INDF,F      ; isn't destroyed while rotating each byte. 

  rlf     crc_l,F     ; Carry flag is rotated into CRC bit 0
  rlf     crc_h,F
  movlw   0x01        ; CRC bit 0 is used as flag if the CRC 
  btfsc   crc_h,7     ; polynom shall be xor:ed with CRC. Xor 
  xorwf   crc_l,F     ; this flag with MSB of CRC

  movlw   0x0f        ; If bit 0 (flag) is set, xor with polynom
  btfsc   crc_l,0
  xorwf   crc_h,F
  movlw   0x9c        ; Bit 0 is already set so 0x9c is used
  btfsc   crc_l,0     ; instead of 0x9d for least significant
  xorwf   crc_l,F     ; byte for polynom

  decfsz  crc_bit,F   ; Next bit
  goto    _CrcBit
  
  incf    FSR,F       ; Update pointer to next byte in buffer
  decfsz  crc_count,F ; Has all bytes been included in CRC?
  goto    _CrcByte    

  movlw   0xff        ; Invert CRC
  xorwf   crc_h,F
  xorwf   crc_l,F
  bcf     STATUS,C    ; Ensure bit 0 is cleared in CRC after
  rlf     crc_l,F     ; rotating it one bit to the left.
  rlf     crc_h,F

  return

;-----------------------------------------------------------------------
; Display filter addresses
;
_DispFilterAddr:
  clrf    main_inptr

  movlw   '('
  call    _QueueRs232 
  
_DispFNext: 
  
  movf    main_inptr,W
  call    _EERead
  btfsc   STATUS,Z
  goto    _DispFOk
  movwf   dec_ptr

  movf    main_inptr,F
  movlw   ','
  btfss   STATUS,Z
  call    _QueueRs232 
  
  swapf   dec_ptr,W
  call    _HexConv  
  call    _QueueRs232
  movf    dec_ptr,W
  call    _HexConv  
  call    _QueueRs232

  incf    main_inptr,F

  movf    main_inptr,W
  call    _EERead
  movwf   dec_ptr
  swapf   dec_ptr,W
  call    _HexConv  
  call    _QueueRs232
  
  incf    main_inptr,F
  btfss   main_inptr,6
  goto    _DispFNext
  
_DispFOk:
  movlw   ')'
  call    _QueueRs232 
  movlw   0x0d
  call    _QueueRs232 
  return

;-----------------------------------------------------------------------
; Filter received VAN packets
;
; In: W = address 0x10, 0x30, 0x50 to read from
;
; Out: C=1 -> Packet addr is in filter list
;      C=0 -> Not found
;
; Note: EEPROM data is in format MSB,LSB (two bytes for each addr with
;       bit0..3 of LSB set to 0). Search will stop when MSB=0x00 is found
;       in the EEPROM
;
_EEFilter:
  movwf   dec_readfrom
  addlw   0x01
  movwf   FSR
  bsf     STATUS,IRP      ; Point to packet buffer at 0x110-0x15F in RAM
      
  bsf     STATUS,RP1      ; Bank 2
  bcf     STATUS,RP0      ; 
  clrf    EEADR           ; Select EEPROM address to start reading from
  
_EELoop:  
  bsf     STATUS,RP0      ; Bank 3
  bcf     EECON1,EEPGD    ; Point to Data memory
  bsf     EECON1,RD       ; Start read operation
  bcf     STATUS,RP0      ; Bank 2

  movf    EEDATA, W       ; 
  bcf     STATUS,RP1      ; Bank 0
  btfsc   STATUS,Z        ;
  goto    _EENotFound     ; Exit if end of list (not found)
  subwf   INDF,W
  movwf   dec_data
  bsf     STATUS,RP1      ; Bank 2

  incf    FSR,F
  incf    EEADR,F

  bsf     STATUS,RP0      ; Bank 3
  bcf     EECON1,EEPGD    ; Point to Data memory
  bsf     EECON1,RD       ; Start read operation
  bcf     STATUS,RP0      ; Bank 2

  movf    INDF,W
  andlw   0xf0
  subwf   EEDATA, W       
  bcf     STATUS,RP1      ; Bank 0
  iorwf   dec_data,W
  btfsc   STATUS,Z
  goto    _EEFound

  bsf     STATUS,RP1      ; Bank 2
  decf    FSR,F 
  incf    EEADR,F
  btfss   EEADR,6         ; Exit if addr isn't found at EEPROM[0x00]..[0x3F]
  goto    _EELoop

_EENotFound:
  bcf     STATUS,C  
  return


_EEFound:
  bsf     STATUS,C  
  return
  


  return


;-----------------------------------------------------------------------
; Decode a received VAN packet 
;
; In: W = address 0x10, 0x30, 0x50 to read from
;
; Destroys: FSR and IRP bit

_HexDecodePacket:
  movwf   dec_readfrom
  bsf     STATUS,IRP      ; Point to packet buffer at 0x110 in RAM
  movf    dec_readfrom,W
  movwf   FSR
  movwf   dec_ptr
  
  movf    INDF,W          ; Read length of packet without CRC
  movwf   dec_data
  andlw   0x1f
  movwf   dec_count
  movlw   0x02
  subwf   dec_count,F
  btfss   STATUS,C
  return
  btfsc   STATUS,Z
  return
  
_DecOk:
  incf    dec_ptr,F       ; Move on to first data byte
  
_WriteDecByte:
  movf    dec_ptr,W       ; Read bit 7..4 of data byte and convert
  movwf   FSR             ; it to hex
  bsf     STATUS,IRP    
  swapf   INDF,W
  movwf   dec_temp
  call    _HexConv  
  call    _QueueRs232

  movf    dec_readfrom,W
  addlw   0x02
  subwf   dec_ptr,W       
  btfss   STATUS,Z
  goto    _DecNotCmd
  
  movlw   ' '             ; Add a Space after addres
  btfsc   dec_data,6
  movlw   '>'
  call    _QueueRs232 
  
  movlw   'R'             ; Decode R/W
  btfss   dec_temp,5
  movlw   'W'
  call    _QueueRs232 
  movlw   'A'             ; Decode RAK
  btfss   dec_temp,6
  movlw   '-'
  call    _QueueRs232 
  movlw   'T'             ; Decode RTR 
  btfss   dec_temp,4
  movlw   '-'
  call    _QueueRs232   
  movlw   ' '             ; Add a Space after address
  call    _QueueRs232 
  goto    _DecSkipLSB
  
_DecNotCmd:
  movf    dec_ptr,W       ; Read bit 3..0 of data byte and convert
  movwf   FSR             ; it to hex
  bsf     STATUS,IRP    
  movf    INDF,W
  call    _HexConv  
  call    _QueueRs232
  
_DecSkipLSB:
  
  incf    dec_ptr,F       ; Move on to next data byte
  decfsz  dec_count,F
  goto    _WriteDecByte

  movlw   ' '
  call    _QueueRs232

  movf    dec_readfrom,W
  movwf   FSR
_DecAck:  
  movlw   '-'             ; Write an 'A' if an ACK was recived, '-' if not
  btfss   INDF,7
  movlw   'A'
  call    _QueueRs232
  
  movlw   0x0d            ; Write < CR > 
  call    _QueueRs232
  
  return


;-----------------------------------------------------------------------
; Add character to RS232 buffer
;
; Input:    W  : Character to add
;
; Output:   0x00 : Ok
;           0x01 : Buffer overflow, byte not queued
;
; Destroys: FSR and IRP bit

_QueueRs232:
  movwf   rs232_temp
  movf    rx232_bytes,W 
  bsf     STATUS,RP0      ; Switch to register bank 1 
  btfsc   STATUS,Z
  btfss   TXSTA,TRMT      ; Check if Rs232 Tx in progrress
  goto    _AddToRs232Queue
  bcf     STATUS,RP0      ; Switch to register bank 0
  movf    rs232_temp,W
  movwf   TXREG           
  retlw   0x00
_QueueRs232Wait:
  call    _SendRs232
  movf    rx232_bytes,W 
_AddToRs232Queue:
  bcf     STATUS,RP0      ; Switch to register bank 0
  sublw   0x40
  btfsc   STATUS,Z
  goto    _QueueRs232Wait
  ; retlw   0x01            ; Queue is full - exit with code 0x01

  movf    rs232_txinptr,W ; Read byte from buffer 
  andlw   0x3f            
  addlw   low rs232tx_buff
  movwf   FSR
  bsf     STATUS,IRP      
  movf    rs232_temp,W    ; Add byte to queue
  movwf   INDF
  bsf     STATUS,RP0      ; Switch to register bank 1 
  bcf     PIE1,TXIE
  bcf     STATUS,RP0      ; Switch to register bank 0
  incf    rs232_txinptr,F
  incf    rx232_bytes,F
  bsf     STATUS,RP0      ; Switch to register bank 1 
; bsf     PIE1,TXIE
  bcf     STATUS,RP0      ; Switch to register bank 0
  retlw   0x00


;-----------------------------------------------------------------------
; Send RS232 buffer
;
; Output: W = x 0.6 us to wait after routine to remain sync
;
; Destroys: FSR and IRP bit

_SendRs232:
  bsf     STATUS,RP0      ; Switch to register bank 1 
  bsf     STATUS,IRP      ; Update FSR 9 th bit
  btfsc   TXSTA,TRMT      ; Exit if transmission queue is full
  goto    _ChkRs232Queue
  bcf     STATUS,RP0      ; Switch to register bank 0
  retlw   0x04            ; Yes - exit

_ChkRs232Queue:
  bcf     STATUS,RP0      ; Switch to register bank 0
  movf    rx232_bytes,W   ; Are there are any bytes to transmit?
  btfsc   STATUS,Z
  retlw   0x03            ; No - exit
  
  movf    rs232_txptr,W   ; Read byte from buffer 
  andlw   0x3f            
  addlw   low rs232tx_buff
  movwf   FSR
  movf    INDF,W          ; Sent the byte
  movwf   TXREG
  incf    rs232_txptr,F   ; Update pointer and counter
  decf    rx232_bytes,F   
  retlw   0x00  

;-----------------------------------------------------------------------
; Read EEPROM data
;
; In:   W = address to read from
;
; Out:  W = data read

_EERead:
  bsf     STATUS, RP1     ; Bank 2
  bcf     STATUS, RP0     ; 
  movwf   EEADR           ; Write address to read from
  bsf     STATUS, RP0     ; Bank 3
  bcf     EECON1, EEPGD   ; Point to Data memory
  bsf     EECON1, RD      ; Start read operation
  bcf     STATUS, RP0     ; Bank 2
  movf    EEDATA, W       ; W = EEDATA
  bcf     STATUS, RP1     ; Bank 0
  return


;-----------------------------------------------------------------------
; Write EEPROM data
;
; In:   W = data to store
;       EEADR must contain address to write to
;
_EEWrite:
  bsf     STATUS, RP1     ;
  bcf     STATUS, RP0     ; Bank 2
  movwf   EEDATA          ; Write
  bsf     STATUS, RP0     ; Bank 3
  bcf     EECON1, EEPGD   ; Point to Data memory
  bsf     EECON1, WREN    ; Enable writes
  bcf     INTCON, GIE     ; disable interrupts
  movlw   0x55            ; Write 55h to
  movwf   EECON2          ; EECON2
  movlw   0xaa            ; Write AAh to
  movwf   EECON2          ; EECON2
  bsf     EECON1, WR      ; Start write operation
  nop
  btfsc   EECON1, WR      ; Wait for
  goto    $-2             ; write to finish
  bsf     INTCON, GIE     ; enable interrupts
  bcf     EECON1, WREN    ; Disable writes
  bcf     STATUS, RP1     ;
  bcf     STATUS, RP0     ; Bank 0
  return

;-----------------------------------------------------------------------
; Send packet on VAN bus 
;
; Input:  W = Number of bytes in VAN package (excluding CRC)
;
; Output: W = 0x00 -> Transmission OK, no ACK
;             0x01 -> Transmission OK, got ACK
;             0x*4 -> Read Reply Request Frame packet
;                     * = read result buffer 0x10, 0x30, 0x50

_Tx_Packet:
  movwf   main_txcount

  movlw   low txbuffer    ; Setup FSR to point to first byte in
  movwf   FSR             ; package buffer  
  bcf     STATUS,IRP

  movf    main_txcount,W  ; Load number of bytes to calculate CRC for
  call    _CalcCrc        ; Calculate CRC
  movf    crc_h,W         ; Store CRC last in package
  movwf   INDF            ; MSB
  incf    FSR,F
  movf    crc_l,W       
  movwf   INDF            ; LSB
  movlw   0x02            ; Add 0x02 to package length
  addwf   main_txcount,F
  
  movf    main_txcount,W
  iorlw   0x80
  movwf   tx_status 
  clrf    T2CON
  movlw   0x00-TX_DELAY
  movwf   TMR2
  bcf     PIR1,TMR2IF
  movlw   0x08            ; Max 8 retries
  movwf   tx_retries
  Bank1
  bsf     PIE1,TMR2IE
  Bank0
  movlw   0x05            ; Enable Timer2 and prescaler/4
  movwf   T2CON
_PktTxWait:               ; Wait for packet to be transmitted
  nop
  btfsc   tx_status,7
  goto    _PktTxWait
  movf    tx_status,W     ; Return result
  return



;-----------------------------------------------------------------------
; Receive packet from VAN bus 
;
; Input: -
;
; Output: W = 0x00 : Read packet, no ACK
;             0x01 : Read packet, ACK received
;             0x02 : Buffer overflow (>31 bytes)
;             0x03 : Start not detected (low 32 us, high 32 us)

_VAN_rx:

  bsf     PORTB,4
  clrf    tx_bytes        ; No transmission in progress
  bcf     PORTB,4
  movlw   0x08            ; Want to transmit manchester bit 0->1 in RTR
  movwf   tx_output_buf   ; field
  movlw   0x03
  movwf   tx_nibblecnt
  bsf     rx_rtr,7

  movlw   0x01            ; Setup pointer to packet length
  movwf   rx_bytes        ; (packet length is stored first in buffer)

  movlw   0x00-0x20
_Rx_Wait_Hi:              ; Wait for VAN to be low for maximum 32 us
  addlw   0x01
  btfsc   STATUS,Z
  retlw   0x03
  btfss   PORTA,0
  goto    _Rx_Wait_Hi
  bsf     PORTB,4
  bcf     PORTB,4

  movlw   0x00-0x17       ; Wait for VAN to be high during 32 us
_Rx_Wait_Lo:
  btfss   PORTA,0
  retlw   0x03
  addlw   0x01
  btfss   STATUS,Z
  goto    _Rx_Wait_Lo

  bsf     PORTB,4         ; Read syncronization bits and sync on 
  movlw   0x08            ; rising edge
  movwf   rx_input_buf
  bcf     PORTB,4
  movlw   0x0c    
  
_Rx_Nibble:               ; Receive 4 NRZ bits 
  movwf   rx_delay  
  
_Rx_Wait:                 ; Wait W * 0.6 us
  decfsz  rx_delay,F
  goto    _Rx_Wait
  
  rrf     PORTA,W         ; Read bit
  bsf     PORTB,4
  rlf     rx_input_buf,F  
  nop
  bcf     PORTB,4
; call    _SendRs232      ; Send any RS232 data from buffer
; addlw   0x03
  movlw   0x0b
  
  btfss   rx_input_buf,4  
  goto    _Rx_Nibble      ; < 4 bits has been read

  btfss   rx_rtr,7        ; In packet reply?
  goto    _Tx_reply
  
; movlw   0x00            
  btfss   rx_input_buf,0  ; Sync on manchester coded bit
  goto    _Rx_Sync0
  
_Rx_Sync1:
  btfss   PORTA,0         ; 0.0   (Sync on falling edge)
  goto    _Rx_Synced
  btfss   PORTA,0         ; 0.4
  goto    _Rx_Synced
  btfss   PORTA,0         ; 0.8
  goto    _Rx_Synced
  btfss   PORTA,0         ; 1.2
  goto    _Rx_Synced
  btfss   PORTA,0         ; 1.6
  goto    _Rx_Synced
  btfss   PORTA,0         ; 2.0
  goto    _Rx_Synced
  btfss   PORTA,0         ; 2.4
  goto    _Rx_Synced
  btfss   PORTA,0         ; 2.8
  goto    _Rx_Synced
  btfss   PORTA,0         ; 3.2
  goto    _Rx_Synced
  btfss   PORTA,0         ; 3.6
  goto    _Rx_Synced
  btfss   PORTA,0         ; 4.0
  goto    _Rx_Synced
  
  retlw   0x05
  
_Rx_Sync0:
  btfsc   PORTA,0         ; 0.0   (Sync on rising edge)
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 0.4
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 0.8
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 1.2
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 1.6
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 2.0
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 2.4
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 2.8
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 3.2
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 3.6
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 4.0
  goto    _Rx_Synced
  
  rrf     rx_bytes,W      ; Sync failed (no rising edge detected)
  andlw   0x1f            ; It must be EOP 
  addwf   rx_curr_buf,W
  movwf   FSR
  bsf     STATUS,IRP

  swapf   INDF,F          ; Store last 4 bits of CRC
  movf    rx_input_buf,W
  andlw   0x0f
  iorwf   INDF,F

  movf    rx_curr_buf,W
  movwf   FSR

  incf    FSR,F           ; 1
  clrf    rx_reply_data
  movf    rx_reply1_h,W
  subwf   INDF,W          ; 2
  btfss   STATUS,Z
  bsf     rx_reply_data,0
  movf    rx_reply2_h,W   ; 3
  subwf   INDF,W
  btfss   STATUS,Z
  bsf     rx_reply_data,1 ; 4
  incf    FSR,F
  movf    INDF,W
  andlw   0xf0            ; 5
  subwf   rx_reply1_l,W
  btfss   STATUS,Z
  bsf     rx_reply_data,0 ; 6
  movf    INDF,W
  andlw   0xf0
  subwf   rx_reply2_l,W   ; 7
  btfss   STATUS,Z
  bsf     rx_reply_data,1
  btfsc   INDF,2          ; 8
  bsf     rx_reply_data,2
  decf    FSR,F           
  decf    FSR,F           ; 9
  movf    rx_reply_data,W
  btfss   rx_reply_data,2
  movlw   0x03            ; 10
  andlw   0x03
  sublw   0x03            
  btfss   STATUS,Z        ; 11
  goto    _RxReplyReq     ; 5.4 us (1.6 us to early?)

  movf    tx_bytes,W
  btfss   STATUS,Z
  goto    _RxReplyReq
  
  movlw   0x1a-0x0b       ; Wait for ACK bit
  movwf   rx_delay  
  
_Rx_Wait_Ack: 
  decfsz  rx_delay,F
  goto    _Rx_Wait_Ack

  movlw   0x00
  bsf     PORTB,4         
  btfsc   PORTA,0         ; Set bit 7 in packet legnth byte if no
  movlw   0x80            ; ACK pulse is detected 
  movwf   INDF
  bcf     PORTB,4

_Rx_Finished:
  btfss   rx_reply_data,0
  bsf     INDF,6
  btfss   rx_reply_data,1
  bsf     INDF,6
  
  clrf    rx_delay
  btfss   INDF,7
  incf    rx_delay,F
  
_RxEnd:
  rrf     rx_bytes,W      ; Divide received bytes with 2
  andlw   0x3f
  iorwf   INDF,F          ; Store package length first in the buffer

  movlw   0x20            ; Move on to next packet buffer
  addwf   rx_curr_buf,F
  movf    rx_curr_buf,W
  sublw   low rxbuffer3+0x20
  movlw   low rxbuffer1
  btfsc   STATUS,Z
  movwf   rx_curr_buf

_exit:    
  movf    rx_delay,W
  return
    

  ; ----------------

_RxReplyReq:
  movlw   0x0d-0x09       ; Wait to send ACK bit
  movwf   rx_delay  
_Rx_Wait_SAck:  
  decfsz  rx_delay,F
  goto    _Rx_Wait_SAck
  
  bsf     PORTA,3         ; Send ACK

  movlw   0x0d            ; Wait for ACK bit duration
  movwf   rx_delay    
_Rx_AckSend:  
  decfsz  rx_delay,F
  goto    _Rx_AckSend
  
  bcf     PORTA,3

  clrf    INDF

  movf    tx_bytes,W      ; Reply with ACK
  btfsc   STATUS,Z
  goto    _Rx_Finished

  Bank1
  movf    low txbuffer,W  ; Move address to receive buffer
  incf    FSR,F
  movwf   INDF
  movf    low txbuffer+1,W
  incf    FSR,F
  movwf   INDF
  decf    FSR,F
  decf    FSR,F
  Bank0

  movlw   0x04            ; Return 0x*4 and buffer address
  iorwf   rx_curr_buf,W
  movwf   rx_delay
  
  goto    _RxEnd

  ; ----------------  
  
_Rx_Synced:
  rrf     rx_bytes,W      ; Syncronized in manchester bit
  andlw   0x1f
  addwf   rx_curr_buf,W
  movwf   FSR
  bsf     STATUS,IRP
  
  btfss   rx_bytes,0      
  clrf    INDF

  swapf   INDF,F          ; Store 4 bits at a time in buffer
  movf    rx_input_buf,W
  andlw   0x0f
  iorwf   INDF,F
  
  incf    rx_bytes,F      ; Increase number of received groups of 4 bits
  
  movf    rx_bytes,W      ; Is the 32 byte buffer filled?
  sublw   0x40
  btfsc   STATUS,Z
  retlw   0x02            ; Error - buffer overflow. Return 0x02
  
  movlw   0x01
  movwf   rx_input_buf

; call    _SendRs232      ; Send any buffered RS232 data
  addlw   0x05
; movlw   0x0c
; goto    _Rx_Nibble      ; Receive next 4 bits

  movf    rx_bytes,W
  sublw   0x05
  movwf   rx_rtr
  
  decf    FSR,F
  movf    INDF,W
  subwf   rx_rtaddr_h,W

  iorwf   rx_rtr,F
  incf    FSR,F
  swapf   INDF,W
  
  subwf   rx_rtaddr_l,W
  iorwf   rx_rtr,F
  btfss   STATUS,Z
  
  bsf     rx_rtr,7
  btfsc   STATUS,Z
  rlf     rx_input_buf,F
  
  movlw   0x07
; call    _SendRs232      ; Send any buffered RS232 data
  goto    _Rx_Nibble      ; Receive next 4 bits
                

_Tx_reply:

  movlw   low rtr_buffer+2 
  movwf   FSR
  bsf     STATUS,IRP      ; Point to buffer at 0x190 
  
  movf    rx_rtdata_len,W
  addwf   rx_rtdata_len,W
  addlw   0x01
  movwf   tx_bytes
  
  movf    INDF,W
  movwf   tx_byte_buf
  
  goto    _NibbleTx

;-----------------------------------------------------------------------
; Send packet on VAN bus 
;
; Ensure the VAN bus has been "free" for atleast 96 us before calling
; this routine.
;
; Input:  W = Number of bytes in VAN package (including CRC)
;         Packet on address 0x110-0x0x12F (incl CRC)
;
; Output: W = 0x00 -> Transmission OK, no ACK
;             0x01 -> Transmission OK, got ACK
;             0x02 -> Transmission aborted by arbitation
;             0x04 -> Read Reply Request Frame packet

_VAN_tx:
  movwf   tx_bytes
  incf    tx_bytes,F
  rlf     tx_bytes,F
  bcf     tx_bytes,0

  bsf     PORTB,4         
  nop
  nop
  bcf     PORTB,4

  movlw   low txbuffer-1
  movwf   FSR
  bcf     STATUS,IRP
  
  movlw   0x0e
  movwf   tx_byte_buf
  
_ByteLoop:
  
  nop
  nop
  
  swapf   tx_byte_buf,F
  movf    tx_byte_buf,W
  movwf   tx_output_buf
  
  btfsc   tx_bytes,0
  incf    FSR,F
  movf    INDF,W
  btfsc   tx_bytes,0
  movwf   tx_byte_buf
  
  rrf     tx_output_buf,W
  rlf     tx_output_buf,W
  xorlw   0x01
  movwf   tx_output_buf
  
  decf    tx_bytes,W
  btfsc   STATUS,Z
  bcf     tx_output_buf,0
  
  clrf    tx_nibblecnt
  movlw   0x02
  
_NibbleLoop:
  movwf   tx_delay        
_WaitDel0:
  decfsz  tx_delay,F
  goto    _WaitDel0
_NibbleTx:  
  btfsc   tx_output_buf,4 
  goto    _Bit0
  movlw   0x01
  bsf     PORTA,3         ; Bus=0
  incf    tx_nibblecnt,F    
  rlf     tx_output_buf,F 
  nop
  nop
  goto    _ChkArbitation  
_Bit0:
  bcf     PORTA,3         ; Bus=1
  incf    tx_nibblecnt,F    
  rlf     tx_output_buf,F 
  nop
  nop
  movf    PORTA,W
_ChkArbitation:
  andlw   0x01
  btfsc   STATUS,Z
  goto    _ChkCollision
  nop
                        
  movlw   0x07            
  btfsc   tx_nibblecnt,2
  btfss   tx_nibblecnt,0
  goto    _NibbleLoop
  
  decfsz  tx_bytes,F
  goto    _ByteLoop

  movlw   0x08
  movwf   tx_delay        ; Wait W * 0.6 us
_WaitDel1:
  decfsz  tx_delay,F
  goto    _WaitDel1
  nop
  
  bcf     PORTA,3

  movlw   0x14
  movwf   tx_delay        ; Wait W * 0.6 us
_WaitDel2:
  decfsz  tx_delay,F
  goto    _WaitDel2
  
  btfss   PORTA,0         ; Check of ACK
  retlw   0x01
  retlw   0x00

_ChkCollision:

  movf    FSR,W           ; Check if it's a Reply Request Frame
  sublw   low txbuffer+2
  btfss   STATUS,Z
  retlw   0x02            ; Collision -> Exit

  movf    tx_nibblecnt,W  ; Only the RTR command bit is allowed 
  sublw   0x04            ; to change
  btfss   STATUS,Z
  retlw   0x02            ; Collision -> Exit
  
  bsf     PORTB,4         ; It was a Reply Request Frame
  clrf    INDF
  movlw   0x05            ; Setup pointer to packet length
  movwf   rx_bytes        ; (packet length is stored first in buffer)
  movlw   0x08            ; rising edge
  movwf   rx_input_buf
  bcf     PORTB,4
  movlw   0x01      
  goto    _Rx_Nibble      ; Start reading from the requested device
  
  
;-----------------------------------------------------------------------
; DATA EEPROM
;

  ORG 0x2100 

  ; Ensure packet filtering list is cleared 
  DE  0x00,0x00

  END
