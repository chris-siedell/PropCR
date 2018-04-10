{
======================================
PropCR-BD (with break detection)
Version 0.2 (alpha/experimental)
April 2018 - in active development
Chris Siedell
http://siedell.com/projects/PropCR/
======================================

todo: rewrite

Usage: in spin, call setParams(), then init() or new().


By default this code doesn't do much -- it just responds to ping and getDeviceInfo admin
commands. More advanced protocols are implemented by the user. When a valid packet is
received for the specified user protocol (defined by conUserProtocol) then the payload is
received in the Payload buffer, and UserCode is jmp'd to.

UserCode is near the bottom, after the PropCR block but before the temporaries.

This version features break detection. When a break condition is detected PropCR jmp's
to BreakHandler, in the user code block.

See "PropCR-Fast User Guide.txt" for more information.
}


con

{ Basic Settings
    cNumPayloadRegisters determines the size of the payload buffer. This buffer is where PropCR
  puts received command payloads. It is also where PropCR sends response payloads from, unless
  sendBufferPointer is changed (by default it points to Payload).
    cAddress provides the Crow address.
    cUserPort is the port to listen for user code commands on. PropCR listens for commands on
  only two ports: cUserPort and port 0. Port 0 is used for standard admin commands, which PropCR
  handles.
}
cNumPayloadRegisters    = 128       'Compile-time constant. Must be at least 1 for buffer overrun protection mechanism to work.
cAddress                = 17        'Must be 1-31. May be changed before cog launch.
cUserPort               = 100       'Must be a one-byte value other than 0. May be changed before cog launch.

'These constants are used in the code.
cRspExpectedFlag        = $80
cAddressMask            = %0001_1111
cMaxPayloadSize         = 4*cNumPayloadRegisters

'Crow error numbers
cUnspecifiedError       = 0
cDeviceUnavailable      = 1
cDeviceIsBusy           = 2
cCommandTooLarge        = 3
cCorruptPayload         = 4
cPortNotOpen            = 5
cLowResources           = 6
cUnknownProtocol        = 7
cRequestTooLarge        = 8
cImplementationFault    = 9
cServiceFault           = 10

'Standard Admin status numbers
cCommandNotAvailable    = 1

'Special Purpose Registers
_rxPort_SH      = $1f0 'sh-par
_rxTmp_SH       = $1f1  'sh-cnt

{
setParams(rxPin, txPin, baudrate, address, minBreakDurationInMS)
Call before init() or new().
Parameters:
    rxPin, txPin - the sending and receiving pins, which may be the same pin
    baudrate - desired baudrate (e.g. 115200, 3_000_000)
    address - device address (must be 1-31); commands must be sent to this address if not broadcast
    minBreakDurationInMS - the minimum threshold for break detection, in milliseconds (must be 1+)
}
pub setParams(__rxPin, __txPin, __baudrate, __address, __minBreakDurationInMS) | __tmp
    
    __tmp := ( 2 * clkfreq ) / __baudrate       '__tmp is now 2 bit periods, in clocks
    
    initBitPeriod0 := __tmp >> 1                                                                'bitPeriod0
    initBitPeriod1 := initBitPeriod0 + (__tmp & 1)                                              'bitPeriod1 = bitPeriod0 + [0 or 1]
    startBitWait := (initBitPeriod0 >> 1) - 10 #> 5                                             'startBitWait (an offset used for receiving)
    stopBitDuration := ((10*clkfreq) / __baudrate) - 5*initBitPeriod0 - 4*initBitPeriod1 + 1    'stopBitDuration (for sending; add extra bit period if required)
    
    __tmp <<= 3                             '__tmp is now 16 bit periods, in clocks
    
    timeout := __tmp                        'timeout, in clocks; see "The Interbyte Timeout" in User Guide
    
    'The default 16 bit period timeout above is based on the assumption that the PC's command 
    ' packet will be received in a steady stream, with no pauses between bytes. If this assumption
    ' is not true then the timeout may be defined in milliseconds, as shown below.
    'See "The Interbyte Timeout" section of the User Guide for more details.
    '__params[4] := (clkfreq/1000) * <non-zero number of milliseconds>    'timeout set using milliseconds
    
    recoveryTime := __tmp                                                                'recoveryTime (in clocks; see "Recovery Mode" in User Guide)
    breakMultiple := ((clkfreq/1000) * __minBreakDurationInMS) / recoveryTime #> 1         'breakMultiple (see "Recovery Mode" in User Guide)

    rxMask := |< __rxPin
    txMask := |< __txPin
    rxVerifyAddress := (rxVerifyAddress & $ffff_fe00) | (__address & $1ff)
    rcvyLowCounterMode := (rcvyLowCounterMode & $ffff_fe00) | (__rxPin & $1ff)

    pin2 := |< 2


{
Start
}
pub Start(__par)
    result := cognew(@Payload, __par)
    waitcnt(cnt + 10000)            'wait for cog to load params



dat
org 0


{ ==========  Begin Payload Buffer and Initialization  ========== }


Payload
                                { First, shift everything starting from ReceiveCommand and up into place. 
                                    This is done so that having the payload buffer at the start of the
                                    cog doesn't waste excessive hub space. Assumptions:
                                    - initEnd+1 contains the first unshifted instruction of ReceiveCommand.
                                    - All addresses starting from initShiftLimit and up are res'd
                                      and are not shifted. todo: rewrite }
                                mov         inb, #initShiftLimit - initShiftStart
initShift                       mov         initShiftLimit-1, initShiftLimit-1-(initShiftStart - (initEnd + 1))
                                sub         initShift, initOneInDAndSFields
                                djnz        inb, #initShift

                                mov         bitPeriod0, initBitPeriod0
                                mov         bitPeriod1, initBitPeriod1
                                mov         frqb, #1
                                or          outa, txMask

                                { As originally written, this implementation will include "PropCR-BD v0.2 (cog N)" as the
                                    device description in response to a getDeviceInfo admin command. Here we
                                    determine the 'N'. }
                                cogid       _initTmp
                                add         getDeviceInfoCogNum, _initTmp

                                or          dira, pin2
                                or          dira, pin1

                                jmp         #ReceiveCommand

initBitPeriod0                  long    0
initBitPeriod1                  long    0

initOneInDAndSFields            long    $201

{ initEnd is the last real (not reserved) register before the first unshifted register of the
    ReceiveCommand routine. Its address is used by the initialization shifting code. todo rewrite}
initEnd
initOneInDField                 long    $200


fit cNumPayloadRegisters 'On error: the payload buffer is too small for the init code.
org cNumPayloadRegisters


{ ==========  Begin PropCR Block  ========== }

{ Res'd Variables }
{ It is almost always an error to have res'd symbols before real instructions or data, but
    in this case it is correct -- the shifting code at the beginning takes it into account. }
token                   res     'potential nop; one byte value
packetInfo              res     'potential nop; upper bytes always set to 0
payloadLength           res     'potential nop; 11 bit value

initShiftStart      'This initialization shifting code will start with this register.

{ Settings }
startBitWait            long    0
stopBitDuration         long    0
timeout                 long    0
recoveryTime            long    0
breakMultiple           long    0
                                'userProtocol stored as nop elsewhere (set at compile time)
                                'userProtocol also stored in byte swapped form in adminGetDeviceInfoBuffer
txMask                  long    0
rxMask                  long    0     'rx pin number also stored in s-field of rcvyLowCounterMode
                                'deviceAddress stored in s-field of rxVerifyAddress

pin2                    long 0
pin1                    long |< 1

ReceiveCommand
                                or          outa, pin1

                                mov         _rxWait0, startBitWait                  'see page 99
                                mov         rxStartWait, rxContinue
                                movs        rxMovA, #rxH0
                                movs        rxMovB, #rxH0+1
                                movs        rxMovC, #rxH0+2
                                mov         _rxResetOffset, #0
                                waitpne     rxMask, rxMask
                                add         _rxWait0, cnt
                                waitcnt     _rxWait0, bitPeriod0
                                test        rxMask, ina                     wc      'c=1 framing error; c=0 continue, with reset
                        if_c    jmp         #RecoveryMode
                                { the receive loop - c=0 reset parser}
_RxLoopTop
:bit0                           waitcnt     _rxWait0, bitPeriod1
                                testn       rxMask, ina                     wz
                        if_nc   mov         _rxF16L, #0                             'F16 1 - see page 90
                        if_c    add         _rxF16L, rxByte                         'F16 2
                        if_c    cmpsub      _rxF16L, #255                           'F16 3
                                muxz        rxByte, #%0000_0001

:bit1                           waitcnt     _rxWait0, bitPeriod0
                                testn       rxMask, ina                     wz
                                muxz        rxByte, #%0000_0010
                        if_nc   mov         inb, #0                                 'F16 4 - inb is upper rxF16
                        if_c    add         inb, _rxF16L                            'F16 5
                        if_c    cmpsub      inb, #255                               'F16 6

:bit2                           waitcnt     _rxWait0, bitPeriod1
                                testn       rxMask, ina                     wz
                                muxz        rxByte, #%0000_0100
                        if_nc   mov         _rxOffset, _rxResetOffset               'Shift 1 - see page 93
                                subs        _rxResetOffset, _rxOffset               'Shift 2
                                adds        rxMovA, _rxOffset                       'Shift 3

:bit3                           waitcnt     _rxWait0, bitPeriod0
                                testn       rxMask, ina                     wz
                                muxz        rxByte, #%0000_1000
                                adds        rxMovB, _rxOffset                       'Shift 4
                                adds        rxMovC, _rxOffset                       'Shift 5
                                mov         _rxOffset, #3                           'Shift 6

:bit4                           waitcnt     _rxWait0, bitPeriod1
                                testn       rxMask, ina                     wz
                                muxz        rxByte, #%0001_0000
rxMovA                          mov         rxShiftedA, 0-0                         'Shift 7
rxMovB                          mov         rxShiftedB, 0-0                         'Shift 8
rxMovC                          mov         rxShiftedC, 0-0                         'Shift 9

:bit5                           waitcnt     _rxWait0, bitPeriod0
                                testn       rxMask, ina                     wz
                                muxz        rxByte, #%0010_0000
                                mov         _rxWait1, _rxWait0                      'Wait 2
                                mov         _rxWait0, startBitWait                  'Wait 3
                                sub         _rxCountdown, #1                wz      'Countdown

:bit6                           waitcnt     _rxWait1, bitPeriod1
                                test        rxMask, ina                     wc
                                muxc        rxByte, #%0100_0000
                        if_nc   mov         ina, rxByte                             'save CH0 (up to last bit) for reserved bits testing
rxShiftedA                      long    0-0                                         'Shift 10
                                shl         _rxLong, #8                             'Buffering 1

:bit7                           waitcnt     _rxWait1, bitPeriod0
                                test        rxMask, ina                     wc
                                muxc        rxByte, #%1000_0000
                                or          _rxLong, rxByte                         'Buffering 2
rxShiftedB                      long    0-0                                         'Shift 11
rxShiftedC                      long    0-0                                         'Shift 12

:stopBit                        waitcnt     _rxWait1, bitPeriod0                    'see page 98
                                testn       rxMask, ina                     wz      'z=0 framing error

rxStartWait                     long    0-0                                         'wait for start bit, or exit loop
                        if_z    add         _rxWait0, cnt                           'Wait 1

:startBit               if_z    waitcnt     _rxWait0, bitPeriod0
                        if_z    test        rxMask, ina                     wz      'z=0 framing error
                        if_z    mov         phsb, _rxWait0                          'Timeout 1 - phsb used as scratch since ctrb should be off
                        if_z    sub         phsb, _rxWait1                          'Timeout 2 - see page 98 for timeout notes
                        if_z    cmp         phsb, timeout                   wc      'Timeout 3 - c=0 reset, c=1 no reset
                        if_z    jmp         #_RxLoopTop

                    { fall through to recovery mode for framing errors }

{ Recovery Mode with Break Detection }
RecoveryMode
                                or          outa, pin2

                                mov         ctrb, rcvyLowCounterMode
                                mov         cnt, recoveryTime
                                add         cnt, cnt
                                mov         _rcvyPrevPhsb, phsb                     'first interval always recoveryTime+1 counts, so at least one loop for break 
                                mov         inb, breakMultiple                      'inb is countdown to break detection
rcvyLoop                        waitcnt     cnt, recoveryTime
                                mov         _rcvyCurrPhsb, phsb
                                cmp         _rcvyPrevPhsb, _rcvyCurrPhsb    wz      'z=1 line always high, so exit
                        if_z    mov         ctrb, #0                                'ctrb must be off before exita

                        if_z    andn        outa, pin2
                        if_z    jmp         #ReceiveCommand
                                mov         par, _rcvyPrevPhsb
                                add         par, recoveryTime
                                cmp         par, _rcvyCurrPhsb              wz      'z=0 line high at some point
                        if_nz   mov         inb, breakMultiple                      'reset break detection countdown
                                mov         _rcvyPrevPhsb, _rcvyCurrPhsb
                                djnz        inb, #rcvyLoop
                                mov         ctrb, #0                                'ctrb must be off before exit


                                andn        outa, pin2

                                jmp         #BreakHandler                           '(could use fall-through to save a jmp)


{ Receive Command 2 - Finishing Up After Packet Arrival }
ReceiveCommand2

                                andn        outa, pin1

                                { Prepare to store any leftover payload. This is OK even if the payload exceeds capacity. In
                                    that case _rxNextAddr will still be Payload, and we can assume there is at least one long's
                                    worth of payload capacity, so no overrun occurs. }
                                test        payloadLength, #%11             wz      'z=0 leftovers exist
                        if_nz   movd        rxStoreLeftovers, _rxNextAddr

                                { Evaluate F16 for last byte. These are also spacer instructions that don't change z.
                                    There is no need to compute upper F16 -- it should already be 0 if there are no errors. }
                                add         _rxF16L, rxByte
                                cmpsub      _rxF16L, #255

                                { Store the leftover payload, if any. Again, this is safe even if the command's payload
                                    exceeds capacity (see above). }
rxStoreLeftovers        if_nz   mov         0-0, _rxLeftovers

                                { Verify the last F16. }
                                or          inb, _rxF16L                    wz      'z=0 bad F16; inb is upper rxF16
                        if_nz   jmp         #RecoveryMode                           '...bad F16 (invalid packet)

                                { Extract the address. }
                                mov         _rxTmp_SH, packetInfo
                                and         _rxTmp_SH, #cAddressMask        wz      'z=1 broadcast address; _rxTmp_SH is now packet's address
                                test        packetInfo, #cRspExpectedFlag   wc      'c=1 response is expected/required
                    if_z_and_c  jmp         #RecoveryMode                           '...broadcast commands must not expect a response (invalid packet)

                                { Check the address if not broadcast. }
rxVerifyAddress         if_nz   cmp         _rxTmp_SH, #cAddress            wz      'device address (s-field) set before launch
                        if_nz   jmp         #ReceiveCommand                         '...wrong non-broadcast address

                                { At this point we have determined that the command was properly formatted and
                                    intended for this device (whether specifically addressed or broadcast). }

                                { Verify that the payload size was under the limit. If it exceeded capacity then the
                                    payload bytes weren't actually saved, so there's nothing to do except report
                                    that the command was too big. }
                                cmp         payloadLength, maxPayloadSize   wc, wz
                if_nc_and_nz    mov         Payload, #cCommandTooLarge
                if_nc_and_nz    jmp         #SendCrowError

                                { Check the port. }
                                cmp         _rxPort_SH, #0                  wz      'z=1 command is for standard admin
                        if_z    jmp         #StandardAdmin
                                cmp         _rxPort_SH, #cUserPort          wz      'z=1 command is for user code
                        if_z    jmp         #UserCode

                                { Report that the port is not open. }
                                mov         Payload, #cPortNotOpen
                                jmp         #SendCrowError 

{ StandardAdmin
    Admin code handles responses to admin commands, such as ping and getDeviceInfo. Admin code must 
    always save and restore sendBufferPointer so that user code can assume it doesn't change.
  At this point the admin protocol number has not been checked to see if it's supported. }

StandardAdmin
                                { admin command with no payload is ping }
                                cmp         payloadLength, #0               wz      'z=1 ping command
                        if_z    jmp         #SendResponse

                                { all other standard admin commands must have at least three bytes, starting
                                    with 0x53 and 0x41 }
                                cmp         payloadLength, #3               wc      'c=1 command too short
                        if_nc   mov         _admTmp, Payload
                        if_nc   and         _admTmp, kFFFF
                        if_nc   cmp         _admTmp, k4153                  wz      'z=0 bad identifying bytes
                    if_c_or_nz  jmp         #ReportUnknownProtocol

                                { the third byte provides the specific command }
                                mov         _admTmp, Payload
                                shr         _admTmp, #16
                                and         _admTmp, #$ff                   wz      'z=1 type==0 -> echo/hostPresence
                        if_z    jmp         #AdminEcho
                                cmp         _admTmp, #1                     wz      'z=1 type==1 -> getDeviceInfo
                        if_z    jmp         #AdminGetDeviceInfo

                                { PropCR does not support any other admin commands }
                                mov         Payload, #cCommandNotAvailable
                                shl         Payload, #16
                                or          Payload, k4153
                                mov         payloadLength, #3
                                jmp         #SendResponse

AdminEcho                       { echo and hostPresence are the same except for the responseExpected flag. Since the
                                    sending code will not do anything if that flag is clear we can proceed as if it is set. 
                                    All that is required is changing the command type byte to a status=0 byte. }
                                ror         Payload, #16
                                andn        Payload, #$ff
                                rol         Payload, #16
                                jmp         #SendResponse

AdminGetDeviceInfo              { The getDeviceInfo response has already been prepared. All we need to do is direct
                                    sendBufferPointer to its location (and remember to restore the pointer's original value afterwards). }
                                mov         _admTmp, sendBufferPointer                      'save sendBufferPointer (_admTmp must not alias _tx* or _send*)
                                mov         sendBufferPointer, #getDeviceInfoBuffer
                                mov         payloadLength, #34
                                call        #SendResponseAndReturn
                                mov         sendBufferPointer, _admTmp                      'restore sendBufferPointer
                                jmp         #ReceiveCommand

getDeviceInfoBuffer
long $0200_4153         'packet identifier (0x53, 0x41), status=0 (OK), implementation's Crow version = 2
long ((cMaxPayloadSize & $ff) << 24) | ((cMaxPayloadSize & $0700) << 8) | ((cMaxPayloadSize & $0700) >> 8) | ((cMaxPayloadSize & $ff) << 8) 'buffer sizes, MSB first
long $160C_0001         'packet includes implementation ascii description of 22 bytes length at offset 12       
long $706f_7250         '"Prop" - final string: "PropCR-BD v0.2 (cog N)"
long $422d_5243         '"CR-B"
long $3076_2044         '"D v0"
long $2820_322e         '".2 ("
long $2067_6f63         '"cog "
getDeviceInfoCogNum
long $0000_2930         '"N)"   - initializing code adds cogid to lower byte to get numeral

k4153     long  $0000_4153  'identifying bytes for standard admin packets; potential nop

'                                { other admin protocol 0 command, getDeviceInfo, has 0x00 as payload }
'adminCheckForGetDeviceInfo      cmp         payloadLength, #1               wz      'z=0 wrong payload length for getDeviceInfo
'                        if_z    test        Payload, #$ff                   wz      'z=0 wrong payload for getDeviceInfo
'                        if_nz   jmp         #RecoveryMode                           '...command not getDeviceInfo or ping, so invalid for admin protocol 0
'                                { perform getDeviceInfo }
'                                mov         _adminTmp, sendBufferPointer            'save sendBufferPointer
'                                mov         sendBufferPointer, #adminGetDeviceInfoBuffer
'                                mov         payloadLength, #12
'                                call        #SendFinalAndReturn
'                                mov         sendBufferPointer, _adminTmp            'restore sendBufferPointer
'                                jmp         #ReceiveCommand
'
'{ This is the prepared getDeviceInfo response payload. }
'adminGetDeviceInfoBuffer
'    long    $51800100                                                                               'Crow v1, implementationID = $8051 (PropCR-Fast-BD)
'    long    $01010000 | ((conMaxPayloadLength & $ff) << 8) | ((conMaxPayloadLength & $700) >> 8)    'conMaxPayloadLength, supports 1 admin protocol and 1 user protocol
'    long    ((conUserProtocol & $ff) << 24) | ((conUserProtocol & $ff00) << 8)                      'admin protocol 0, conUserProtocol


{ Receive Command 3 - Shifted Code }
{ There are three parsing instructions per byte received. Shifted parsing code executes inside the
    receive loop at rxShiftedA-C. See pages 102, 97, 94. }
rxH0                
                                xor         ina, #1                             'A - ina set to CH0 in loop (up through bit 6); bit 0 should be 1 (invert to test)
                                test        ina, #%0100_0111            wz      ' B - z=1 good reserved bits 0-2 and 6
                    if_nz_or_c  jmp         #RecoveryMode                       ' C - ...abort if bad reserved bits (c = bit 7 must be 0)

rxH1                            shr         _rxLong, #3                         'A - prepare _rxLong to hold payloadSize (_rxLong buffering occurs between A and B)
                                mov         payloadLength, _rxLong              ' B - important: payloadLength still needs to be masked (upper bits undefined)
                                and         payloadLength, k7ff                 ' C - payloadLength is ready
rxH2 
                                test        rxByte, #%0110_0000         wz      'A - test reserved bits 5 and 6 of CH2 (they must be zero)
                        if_nz   jmp         #RecoveryMode                       ' B - ...abort for bad reserved bits
                                mov         packetInfo, rxByte                  ' C - save ch2 for later use
rxH3
                                mov         _rxRemaining, payloadLength         'A - _rxRemaining = number of bytes of payload yet to receive
                                mov         _rxNextAddr, #Payload               ' B - must reset _rxNextAddr before rxP* code
                                mov         _rxPort_SH, rxByte                  ' C - save the port number
rxH4
kFFFF                           long    $ffff                                   'A - spacer nop
k7FF                            long    $7FF                                    ' B - spacer nop; 2047 = maximum payload length allowed by Crow specification
                                mov         token, rxByte                       ' C - save the token
rxF16_C0 
                                mov         _rxLeftovers, _rxLong               'A - preserve any leftover bytes in case this is the end
                                mov         _rxCountdown, _rxRemaining          ' B - _rxCountdown = number of payload bytes in next chunk
                                max         _rxCountdown, #128                  ' C - chunks have up to 128 payload bytes
rxF16_C1
                                add         _rxCountdown, #1            wz      'A - undo automatic decrement; z=1 the next chunk is empty -- i.e. we're done
                                sub         _rxRemaining, _rxCountdown          ' B - decrement the payload bytes remaining counter by the number in next chunk
                        if_z    mov         rxStartWait, rxExit                 ' C - no payload left, so exit
rxP0_Eval
                        if_z    subs        _rxOffset, #9                       'A - go to rxF16_C0 if done with chunk's payload
                                or          inb, _rxF16L                wz      ' B - z=0 bad F16 - inb is upper rxF16
                        if_nz   jmp         #RecoveryMode                       ' C - ...bad F16
rxP1                    
                        if_z    subs        _rxOffset, #12                              'A - go to rxF16_C0 if done with chunk's payload
                                cmp         payloadLength, maxPayloadSize       wc, wz  ' B - test for potential buffer overrun
                if_nc_and_nz    mov         _rxOffset, #12                              ' C - payload too big for buffer so go to rxP_NoStore (doesn't save payload)
rxP2                    
                        if_z    subs        _rxOffset, #15                      'A - go to rxF16C0 if done with chunk's payload
maxPayloadSize                  long    cMaxPayloadSize & $7ff                  ' B - required nop - must be 2047 or less by Crow specification
                                movd        RxStoreLong, _rxNextAddr            ' C - prep to write next long to buffer
rxP3                    
                        if_z    subs        _rxOffset, #18                      'A - go to rxF16_C0 if done with chunk's payload
RxStoreLong                     mov         0-0, _rxLong                        ' B
                                add         _rxNextAddr, #1                     ' C - incrementing _rxNextAddr and storing the long must occur in same block
rxP0                    
                        if_z    subs        _rxOffset, #21                      'A - go to rxF16_C0 if done with chunk's payload
                        if_nz   subs        _rxOffset, #12                      ' B - otherwise go to rxP1
                                nop                                             ' C -
rxP_NoStore
                        if_z    subs        _rxOffset, #24                      'A - go to rxF16_C0 if done with chunk's payload
                        if_nz   mov         _rxOffset, #0                       ' B - otherwise stay at this block (all we're doing is waiting to report crow error) 
                                xor         outa, pin1
                                

rxContinue              if_z    waitpne     rxMask, rxMask                  'executed at rxStartWait
rxExit                  if_z    jmp         #ReceiveCommand2                'executed at rxStartWait



txByte
rxByte                          long    0                                       ' B - required nop - upper bytes must always be 0 for F16

rcvyLowCounterMode              long    $3000_0000                              'A - required nop - rx pin number set in initialization



{ TxSendAndResetF16 }
{ Helper routine to send the current F16 checksum (upper sum, then lower sum). It also resets
    the checksum after sending. }
TxSendAndResetF16
                                mov         _txLong, _txF16L
                                shl         _txLong, #8
                                or          _txLong, _txF16U
                                mov         _txCount, #2
                                movs        _TxHandoff, #_txLong
                                call        #TxSendBytes
                                mov         _txF16L, #0
                                mov         _txF16U, #0
TxSendAndResetF16_ret           ret


{ TxSendBytes (call)
    Helper routine used to send bytes. It also updates the running F16 checksum. It assumes
  the tx pin is already an output.
    Usage:  mov         _txCount, <number of bytes to send, MUST be non-zero>
            movs        _TxHandoff, <buffer address, sending starts with low byte>
            call        #TxSendBytes                                                
}
TxSendBytes
                                mov         par, #0                                 'par used to perform handoff every 4 bytes
                                mov         cnt, cnt                                'cnt used for timing
                                add         cnt, #21
txByteLoop                      test        par, #%11                   wz
_TxHandoff              if_z    mov         _txLong, 0-0
                        if_z    add         _TxHandoff, #1
txStartBit                      waitcnt     cnt, bitPeriod0
                                andn        outa, txMask
                                mov         txByte, _txLong
                                and         txByte, #$ff                            'txByte MUST be masked for F16 (also is a nop)
                                add         _txF16L, txByte
                                ror         _txLong, #1                 wc
txBit0                          waitcnt     cnt, bitPeriod1
                                muxc        outa, txMask
                                cmpsub      _txF16L, #255
                                add         _txF16U, _txF16L
                                cmpsub      _txF16U, #255
                                ror         _txLong, #1                 wc
txBit1                          waitcnt     cnt, bitPeriod0
                                muxc        outa, txMask
                                add         par, #1
                                mov         inb, #6                                 'inb is bit loop count
txBitLoop                       ror         _txLong, #1                 wc
txBitX                          waitcnt     cnt, bitPeriod1
                                muxc        outa, txMask
                                xor         txBitX, #1                              'this is why bitPeriod0 must be at even address, with bitPeriod1 next
                                djnz        inb, #txBitLoop
txStopBit                       waitcnt     cnt, stopBitDuration
                                or          outa, txMask
                                djnz        _txCount, #txByteLoop
                                waitcnt     cnt, #0
TxSendBytes_ret                 ret


{ ReportUnknownProtocol (jmp)
    Both admin and user code may use this routine to send a UnknownProtocol Crow-level
  error response. This is the correct action to take if the received command does not
  conform to the expected protocol.
    After sending the error response execution goes to ReceiveCommand.
}
ReportUnknownProtocol
                                mov         Payload, #cUnknownProtocol

                            { fall through to SendCrowError }

{ SendCrowError (jmp)
    This routine sends a Crow-level error response.
    It assumes the low byte of Payload has been set to the error number (and that no
  other bits are set -- PropCR does not send error details).
}
SendCrowError                   movs        _SendApplyTemplate, #$82
                                mov         payloadLength, #1

                            { fall through to SendResponse }

{ SendResponse (jmp), SendResponseAndReturn (call)
    Usage:  mov     payloadSize, <size of payload, in bytes, may be zero>
           (mov     sendBufferPointer, #<register of start of buffer>) 'sendBufferPointer = Payload = 0 by default
            jmp     #SendResponse
            -or-
            call    #SendResponseAndReturn
    After: payloadSize will be undefined
}
SendResponse                    movs        Send_ret, #ReceiveCommand
SendResponseAndReturn
                                { verify that there's an open transaction (i.e. that we are allowed to send a response) }
                                test        packetInfo, #cRspExpectedFlag       wc      'c=0 response forbidden
                        if_nc   jmp         #_SendDone                                  '...must not send if responses forbidden

                                { make sure the payload size is within specification (truncate if necessary) }
                                max         payloadLength, k7FF                         'must not exceed specification max

                                { compose header bytes RH0-RH2 in _txLong }
                                mov         _txLong, token
                                shl         _txLong, #8
                                mov         _txCount, payloadLength                     '_txCount being used for scratch
                                and         _txCount, #$ff
                                or          _txLong, _txCount
                                shl         _txLong, #8
                                mov         _txCount, payloadLength
                                shr         _txCount, #5
                                and         _txCount, #%0011_1000
_SendApplyTemplate              or          _txCount, #2                                'the template (s-field) is changed only for error responses, then reverted after
                                or          _txLong, _txCount

                                { reset F16 }
                                mov         _txF16L, #0
                                mov         _txF16U, #0

                                { retain line (make output) }
                                or          dira, txMask

                                { send header }
                                mov         _txCount, #3
                                movs        _TxHandoff, #_txLong
                                call        #TxSendBytes
                                call        #TxSendAndResetF16

                                { send body, in chunks (payload data + F16 sums) }
                                movs        :setHandoff, sendBufferPointer
                                mov         _txRemaining, payloadLength
:loop                           mov         _txCount, _txRemaining              wz
                        if_z    jmp         #:loopExit
                                max         _txCount, #128                              'chunks are 128 bytes of payload data
                                sub         _txRemaining, _txCount
:setHandoff                     movs        _TxHandoff, #0-0
                                call        #TxSendBytes
                                call        #TxSendAndResetF16
                                add         :setHandoff, #32                            'next chunk (if any) is at +32 registers
                                jmp         #:loop

:loopExit                       { release line (make high-z) }
                                andn        dira, txMask
                                
_SendDone                       { revert the RH0 template (in case this was an error response) }
                                movs        _SendApplyTemplate, #2
Send_ret
SendResponseAndReturn_ret       ret


sendBufferPointer       long    Payload     'potential nop if only lower 9 bits set


{ ==========  Begin User Block  ========== }


{ User Code }
{ This is where PropCR code will jmp to when a valid user command packet has arrived.
  Refer to "PropCR-Fast User Guide.txt" for more information. }
UserCode
                                jmp         #SendResponse


{ Break Handler }
{ This code is jmp'd to when PropCR detects a break condition. }
BreakHandler
                                waitpeq     rxMask, rxMask          'wait for break to end
                                jmp         #ReceiveCommand


{ ==========  Begin Temporaries  ========== }


{ Registers 484 to 493 are reserved for temporaries. }

fit 484 'If this fails then either user code or the payload buffer must be reduced.
org 484

initShiftLimit      'The initialization shifting code will ignore registers at and above this address.

{ Temporaries }
{ These are the temporary variables used by PropCR. User code may also use these temporaries. 
  See the section "Temporaries" in the User Guide for details. }

{ The following five temporaries -- registers 486 to 490 -- preserve their values during a Send* call. }

tmp0
_rxWait0        res

tmp1
_rxWait1        res

tmp2
_rxResetOffset  res

tmp3
_rxOffset       res

tmp4
_initDeviceID
_admTmp                 '_admTmp must not alias a _tx* or _send* temporary
_rxNextAddr     res

{ The following five "v" temporaries -- registers 491 to 495 -- are undefined after a Send* call. }

tmp5v
_rcvyPrevPhsb
_initTmp
_txF16L
_rxF16L         res

tmp6v
_rcvyCurrPhsb
_initHub
_txLong
_rxLong         res

tmp7v
_initRxPin
_txF16U
_rxLeftovers    res

tmp8v
_initTxPin
_txRemaining
_rxRemaining    res

tmp9v
_initDeviceAddress
_txCount
_rxCountdown    res


fit 494

{ Fixed Location Settings
    The transmit code uses a bit twiddling mechanism to switch between bitPeriod0 and 1,
  so bitPeriod0 must be at an even address and bitPeriod1 must immediately follow.
}
org 494
bitPeriod0  res
bitPeriod1  res

