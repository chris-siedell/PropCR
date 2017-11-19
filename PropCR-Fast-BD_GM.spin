{
======================================
PropCR-Fast-BD (with break detection)
Version 0.1 (alpha/experimental)
23 May 2017 - Chris Siedell
http://siedell.com/projects/PropCR/
======================================

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

{ conNumPayloadRegisters determines the size of the payload buffer. This buffer is where PropCR
    puts received command payloads. It is also where PropCR sends response payloads from unless
    sendBufferPointer is changed (by default it points to Payload).
 Due to the requirement that bitPeriod0 must be at an even-addressed register this number must
    be even, otherwise transmitting will fail with weird looking framing errors. }
    
conNumPayloadRegisters  = 128       'Important: this MUST be an even number.

{ conUserProtocol identifies the user protocol number that PropCR will listen for. This number must
    match the protocol number sent with user commands from the PC. }

conUserProtocol         = $0        'Must be two byte value.

'These constants are used in the code.
conMuteFlag             = %0100_0000
conAddressMask          = %0001_1111
conMaxPayloadLength     = 4*conNumPayloadRegisters


var

    long    __params[8]


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
    
    __params[0] := __tmp >> 1                                                           'bitPeriod0
    __params[1] := __params[0] + (__tmp & 1)                                            'bitPeriod1 = bitPeriod0 + [0 or 1]
    __params[2] := (__params[0] >> 1) - 10 #> 5                                         'startBitWait (an offset used for receiving)
    __params[3] := ((10*clkfreq) / __baudrate) - 5*__params[0] - 4*__params[1] + 1      'stopBitDuration (for sending; add extra bit period if required)
    
    __tmp <<= 3                                 '__tmp is now 16 bit periods, in clocks
    
    __params[4] := __tmp                                                                'timeout, in clocks; see "The Interbyte Timeout" in User Guide
    
    'The default 16 bit period timeout above is based on the assumption that the PC's command 
    ' packet will be received in a steady stream, with no pauses between bytes. If this assumption
    ' is not true then the timeout may be defined in milliseconds, as shown below.
    'See "The Interbyte Timeout" section of the User Guide for more details.
    '__params[4] := (clkfreq/1000) * <non-zero number of milliseconds>    'timeout set using milliseconds
    
    __params[5] := __tmp                                                                'recoveryTime (in clocks; see "Recovery Mode" in User Guide)
    __params[6] := ((clkfreq/1000) * __minBreakDurationInMS) / __params[5] #> 1         'breakMultiple (see "Recovery Mode" in User Guide)
    __params.byte[28] := __txPin
    __params.byte[29] := __rxPin
    __params.byte[30] := __address


{
new()
Call setParams() first.
Starts an instance using cognew. Calls to setParams() have no effect after this call.
}
pub new
    
    cognew(@Payload, @__params)
    waitcnt(cnt + 10000)            'wait for cog to load params


{
init(id)
Call setParams() first.
Starts an instance using coginit and the provided cog ID. Calls to setParams() have no effect
after this call.
}
pub init(__id) 
    
    coginit(__id, @Payload, @__params)
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
                                      and are not shifted. }
                                mov         inb, #initShiftLimit - ReceiveCommand
initShift                       mov         initShiftLimit-1, initShiftLimit-1-(ReceiveCommand - (initEnd + 1))
                                sub         initShift, initOneInDAndSFields
                                djnz        inb, #initShift

                                { Get settings from hub. }
                                mov         _initHub, par

                                { The first seven settings can be stored via loop. }
                                mov         inb, #7
initHubLoop                     rdlong      bitPeriod0, _initHub
                                add         initHubLoop, initOneInDField
                                add         _initHub, #4
                                djnz        inb, #initHubLoop

                                { Most of the remaining settings will require processing. }
                                rdbyte      _initTxPin, _initHub
                                add         _initHub, #1
                                rdbyte      _initRxPin, _initHub
                                add         _initHub, #1
                                rdbyte      _initDeviceAddress, _initHub

                                { ctrb setup - used in recovery mode }
                                movs        rcvyLowCounterMode, _initRxPin
                                mov         frqb, #1

                                { rx mask }
                                mov         rxMask, #1
                                shl         rxMask, _initRxPin

                                { tx mask }
                                mov         txMask, #1
                                shl         txMask, _initTxPin
                                or          outa, txMask            'must occur before making tx an output

                                { device address }
                                movs        rxVerifyAddress, _initDeviceAddress

                                jmp         #ReceiveCommand

initOneInDAndSFields            long    $201

{ initEnd is the last real (not reserved) register before the first unshifted register of the
    ReceiveCommand routine. Its address is used by the initialization shifting code. }
initEnd
initOneInDField                 long    $200


fit conNumPayloadRegisters      'If this fails then the payload buffer is too small for the initialization code.
org conNumPayloadRegisters


{ ==========  Begin PropCR Block  ========== }


{ Settings }
{ It is almost always an error to have res'd symbols before real instructions or data, but
    in this case it is correct -- the shifting code at the beginning takes it into account. }
bitPeriod0              res     'bitPeriod0 must be at even address (see txBitX)
bitPeriod1              res     'bitPeriod1 must immediately follow bitPeriod0
startBitWait            res
stopBitDuration         res
timeout                 res
recoveryTime            res
breakMultiple           res
                                'userProtocol stored as nop elsewhere (set at compile time)
                                'userProtocol also stored in byte swapped form in adminGetDeviceInfoBuffer
txMask                  res
rxMask                  res     'rx pin number also stored in s-field of rcvyLowCounterMode
                                'deviceAddress stored in s-field of rxVerifyAddress


{ Other Res'd Variables }
token                   res     'potential nop; one byte value
packetInfo              res     'potential nop; upper bytes always set to 0
payloadLength           res     'potential nop; 11 bit value


{ Receive Command 1 - Start }
{ The first instruction of ReceiveCommand must occupy the register at initEnd+1 (before shifting),
    so there must be nothing but res'd symbols in between. }
ReceiveCommand
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
rxBit0                          waitcnt     _rxWait0, bitPeriod1
                                testn       rxMask, ina                     wz
                        if_nc   mov         _rxF16L, #0                             'F16 1 - see page 90
                        if_c    add         _rxF16L, rxByte                         'F16 2
                        if_c    cmpsub      _rxF16L, #255                           'F16 3
                                muxz        rxByte, #%0000_0001
rxBit1                          waitcnt     _rxWait0, bitPeriod0
                                testn       rxMask, ina                     wz
                                muxz        rxByte, #%0000_0010
                        if_nc   mov         inb, #0                                 'F16 4 - inb is upper rxF16
                        if_c    add         inb, _rxF16L                            'F16 5
                        if_c    cmpsub      inb, #255                               'F16 6
rxBit2                          waitcnt     _rxWait0, bitPeriod0
                                testn       rxMask, ina                     wz
                                muxz        rxByte, #%0000_0100
                        if_nc   mov         _rxOffset, _rxResetOffset               'Shift 1 - see page 93
                                subs        _rxResetOffset, _rxOffset               'Shift 2
                                adds        rxMovA, _rxOffset                       'Shift 3
rxBit3                          waitcnt     _rxWait0, bitPeriod0
                                testn       rxMask, ina                     wz
                                muxz        rxByte, #%0000_1000
                                adds        rxMovB, _rxOffset                       'Shift 4
                                adds        rxMovC, _rxOffset                       'Shift 5
                                mov         _rxOffset, #3                           'Shift 6
rxBit4                          waitcnt     _rxWait0, bitPeriod0
                                testn       rxMask, ina                     wz
                                muxz        rxByte, #%0001_0000
rxMovA                          mov         rxShiftedA, 0-0                         'Shift 7
rxMovB                          mov         rxShiftedB, 0-0                         'Shift 8
rxMovC                          mov         rxShiftedC, 0-0                         'Shift 9
rxBit5                          waitcnt     _rxWait0, bitPeriod0
                                testn       rxMask, ina                     wz
                                muxz        rxByte, #%0010_0000
                                mov         _rxWait1, _rxWait0                      'Wait 2
                                mov         _rxWait0, startBitWait                  'Wait 3
                        if_nc   mov         _rxCountdown, #511                      'Countdown 1
rxBit6                          waitcnt     _rxWait1, bitPeriod1
                                test        rxMask, ina                     wc
                                muxc        rxByte, #%0100_0000
                                sub         _rxCountdown, #1                wz      'Countdown 2
rxShiftedA                      long    0-0                                         'Shift 10
                                shl         _rxLong, #8                             'Buffering 1
rxBit7                          waitcnt     _rxWait1, bitPeriod0
                                test        rxMask, ina                     wc
                                muxc        rxByte, #%1000_0000
                                or          _rxLong, rxByte                         'Buffering 2
rxShiftedB                      long    0-0                                         'Shift 11
rxShiftedC                      long    0-0                                         'Shift 12
rxStopBit                       waitcnt     _rxWait1, bitPeriod0                    'see page 98
                                testn       rxMask, ina                     wz      'z=0 framing error
rxStartWait                     long    0-0                                         'wait for start bit, or exit loop
                        if_z    add         _rxWait0, cnt                           'Wait 1
rxStartBit              if_z    waitcnt     _rxWait0, bitPeriod0
                        if_z    test        rxMask, ina                     wz      'z=0 framing error
                        if_z    mov         phsb, _rxWait0                          'Timeout 1 - phsb used as scratch since ctrb should be off
                        if_z    sub         phsb, _rxWait1                          'Timeout 2 - see page 98 for timeout notes
                        if_z    cmp         phsb, timeout                    wc     'Timeout 3 - c=0 reset, c=1 no reset
                        if_z    jmp         #rxBit0

                    { fall through to recovery mode for framing errors }

{ Recovery Mode with Break Detection }
RecoveryMode
                                mov         ctrb, rcvyLowCounterMode
                                mov         cnt, recoveryTime
                                add         cnt, cnt
                                mov         _rcvyPrevPhsb, phsb                     'first interval always recoveryTime+1 counts, so at least one loop for break 
                                mov         inb, breakMultiple                      'inb is countdown to break detection
rcvyLoop                        waitcnt     cnt, recoveryTime
                                mov         _rcvyCurrPhsb, phsb
                                cmp         _rcvyPrevPhsb, _rcvyCurrPhsb    wz      'z=1 line always high, so exit
                        if_z    mov         ctrb, #0                                'ctrb must be off before exit
                        if_z    jmp         #ReceiveCommand
                                mov         par, _rcvyPrevPhsb
                                add         par, recoveryTime
                                cmp         par, _rcvyCurrPhsb              wz      'z=0 line high at some point
                        if_nz   mov         inb, breakMultiple                      'reset break detection countdown
                                mov         _rcvyPrevPhsb, _rcvyCurrPhsb
                                djnz        inb, #rcvyLoop
                                mov         ctrb, #0                                'ctrb must be off before exit
                                jmp         #BreakHandler                           '(could use fall-through to save a jmp)


{ Receive Command 2 - Finishing Up After Packet Arrival }
ReceiveCommand2
                                { prepare to store any leftover payload }
                                test        payloadLength, #%11             wz      'z=0 leftovers exist
                        if_nz   movd        rxStoreLeftovers, _rxNextAddr
                                { evaluate F16 for last byte; these are also spacer instructions that don't change z;
                                    no need to compute upper F16, it should already be 0 if there are no errors }
                                add         _rxF16L, rxByte
                                cmpsub      _rxF16L, #255
                                { store the leftover payload, if any }
rxStoreLeftovers        if_nz   mov         0-0, _rxLeftovers
                                { verify the last F16 }
                                or          inb, _rxF16L                    wz      'z=0 bad F16; inb is upper rxF16
                        if_nz   jmp         #RecoveryMode                           '...bad F16 (invalid packet)
                                { verify reserved bit 5 of CH3 }
                                test        packetInfo, #%0010_0000         wc      'c=1 bad bit 5 (must be 0); packetInfo=CH3 from rxH3
                        if_c    jmp         #RecoveryMode                           '...bad reserved bit 5 of CH3 (invalid packet)
                                { finish parsing address and verify it }
                                and         cnt, #conAddressMask            wz      'z=1 broadcast address; cnt is now packet's address (originally from rxH3)
                                test        packetInfo, #conMuteFlag        wc      'c=1 mute response
                    if_z_and_nc jmp         #RecoveryMode                           '...broadcast must mute (invalid packet)
                                { verify address if not broadcast }
rxVerifyAddress         if_nz   cmp         cnt, #0-0                       wz      'cnt is packet's address (from above); device address (s-field) set at initialization
                        if_nz   jmp         #ReceiveCommand                         '...wrong non-broadcast address
                                { test command type and protocol }
                                test        ina, #%0001_0000                wc      'c=1 user command; ina=CH0 from rxH0
                                cmp         par, userProtocol               wz      'z=0 protocol doesn't match user protocol; par is packet's protocol (from rxH2 or rxH5)
                    if_c_and_nz jmp         #ReceiveCommand                         '...wrong protocol for user command
                        if_c    jmp         #UserCode                               '...valid user command with correct protocol, so invoke user code

                            { fall through to admin code }

{ Admin Code }
{ Admin code handles responses to admin commands, such as ping and getDeviceInfo. Admin code must 
    always save and restore sendBufferPointer so that user code can assume it doesn't change.
  At this point the admin protocol number has not been checked to see if it's supported. }
AdminCode                       cmp         par, #0                         wz      'z=1 universal admin protocol (=0); par is packet's protocol (from rxH2 or rxH5)
                        if_nz   jmp         #ReceiveCommand                         '...not admin protocol 0 (so unsupported admin protocol)
                                test        packetInfo, #conMuteFlag        wc      'c=1 muted response (and possible broadcast command)
                        if_c    jmp         #RecoveryMode                           '...admin protocol 0 commands must not be muted or broadcast (invalid command)
                                { admin protocol 0 with no payload is ping }
                                cmp         payloadLength, #0               wz      'z=1 ping command
                        if_nz   jmp         #adminCheckForGetDeviceInfo             '...command not ping
                                { perform ping - params all ready (no payload, so sendBufferPointer not used }
                                jmp         #SendFinalResponse
                                { other admin protocol 0 command, getDeviceInfo, has 0x00 as payload }
adminCheckForGetDeviceInfo      cmp         payloadLength, #1               wz      'z=0 wrong payload length for getDeviceInfo
                        if_z    test        Payload, #$ff                   wz      'z=0 wrong payload for getDeviceInfo
                        if_nz   jmp         #RecoveryMode                           '...command not getDeviceInfo or ping, so invalid for admin protocol 0
                                { perform getDeviceInfo }
                                mov         _adminTmp, sendBufferPointer            'save sendBufferPointer
                                mov         sendBufferPointer, #adminGetDeviceInfoBuffer
                                mov         payloadLength, #12
                                call        #SendFinalAndReturn
                                mov         sendBufferPointer, _adminTmp            'restore sendBufferPointer
                                jmp         #ReceiveCommand

{ This is the prepared getDeviceInfo response payload. }
adminGetDeviceInfoBuffer
    long    $51800100                                                                               'Crow v1, implementationID = $8051 (PropCR-Fast-BD)
    long    $01010000 | ((conMaxPayloadLength & $ff) << 8) | ((conMaxPayloadLength & $700) >> 8)    'conMaxPayloadLength, supports 1 admin protocol and 1 user protocol
    long    ((conUserProtocol & $ff) << 24) | ((conUserProtocol & $ff00) << 8)                      'admin protocol 0, conUserProtocol


{ Receive Command 3 - Shifted Code }
{ There are three parsing instructions per byte received. Shifted parsing code executes inside the
    receive loop at rxShiftedA-C. See pages 102, 97, 94. }
rxH0                    if_c    test        rxByte, #%0010_1000         wz      'A - z=1 good reserved bits 3, 5, and 6 (z=0 before due to countdown reset)
                    if_nz_or_c  jmp         #RecoveryMode                       ' B - ...abort if bad reserved bits (bit 7 must be 0); might be another device's response
                                mov         ina, rxByte                         ' C - ina used to save the T field (command type)
rxH1                            and         _rxLong, #$7                        'A - mask off upper three bits for payloadLength (shift occurs between A and B)
                                mov         payloadLength, _rxLong              ' B
                                mov         _rxRemaining, payloadLength         ' C - _rxRemaining = number of bytes of payload yet to receive
rxH2                            mov         par, #0                             'A - par used to hold packet's protocol; must set implicit 0 value
                                mov         _rxNextAddr, #Payload               ' B - must reset _rxNextAddr before rxP* code
                                mov         token, rxByte                       ' C
rxH3                            mov         cnt, rxByte                         'A - cnt used to hold packet's address; used in ReceiveCommand2
                                mov         packetInfo, rxByte                  ' B
                        if_nc   mov         _rxOffset, #9                       ' C
rxH4
rcvyLowCounterMode              long    $3000_0000                              'A - required nop - rx pin number set in initialization
kFFFF                           long    $ffff                                   ' B - required nop
k7FF                            long    $7FF                                    ' C - required nop; 2047 = maximum payload length allowed by Crow specification
rxH5
maxPayloadLength                long    conMaxPayloadLength & $7ff              'A - required nop - must be 2047 or less by Crow specification
                                mov         par, _rxLong                        ' B - reminder: par is packet's protocol
                                and         par, kFFFF                          ' C
rxF16C0                         mov         _rxLeftovers, _rxLong               'A - store any leftover bytes in case this is the end
                                mov         _rxCountdown, _rxRemaining          ' B
                                max         _rxCountdown, #128                  ' C - _rxCountdown = number of payload bytes in next chunk
rxF16C1                         add         _rxCountdown, #1            wz      'A - undo automatic decrement
                                sub         _rxRemaining, _rxCountdown          ' B
                        if_z    mov         rxStartWait, rxExit                 ' C - no payload left, so exit
rxP0Eval                if_z    subs        _rxOffset, #9                       'A - go to rxF16C0 if done with chunk's payload
                                or          inb, _rxF16L                wz      ' B - z=0 bad F16 - inb is upper rxF16
                        if_nz   jmp         #RecoveryMode                       ' C - ...bad F16
rxP1                    if_z    subs        _rxOffset, #12                              'A - go to rxF16C0 if done with chunk's payload
                                cmp         payloadLength, maxPayloadLength     wc, wz  ' B
                if_nc_and_nz    jmp         #RecoveryMode                               ' C - ...payload too big for buffer
rxP2                    if_z    subs        _rxOffset, #15                      'A - go to rxF16C0 if done with chunk's payload
txByte
rxByte                          long    0                                       ' B - required nop - upper bytes must always be 0 for F16
                                movd        rxStoreLong, _rxNextAddr            ' C
rxP3                    if_z    subs        _rxOffset, #18                      'A - go to rxF16C0 if done with chunk's payload
                                add         _rxNextAddr, #1                     ' B - incrementing _rxNextAddr and storing the long must occur in same block
rxStoreLong                     mov         0-0, _rxLong                        ' C
rxP0                    if_z    subs        _rxOffset, #21                      'A - go to rxF16C0 if done with chunk's payload
                        if_nz   subs        _rxOffset, #12                      ' B - otherwise go to rxP1
userProtocol                    long    conUserProtocol & $ffff                 ' C - required nop

rxContinue              if_z    waitpne     rxMask, rxMask                  'executed at rxStartWait
rxExit                  if_z    jmp         #ReceiveCommand2                'executed at rxStartWait


{ txSendAndResetF16 }
{ Helper routine to send the current F16 checksum (upper sum, then lower sum). It also resets
    the checksum after sending. }
txSendAndResetF16
                                mov         _txLong, _txF16L
                                shl         _txLong, #8
                                or          _txLong, _txF16U
                                mov         _txCount, #2
                                movs        txHandoff, #_txLong
                                call        #txSendBytes
                                mov         _txF16L, #0
                                mov         _txF16U, #0
txSendAndResetF16_ret           ret


{ txSendBytes }
{ Helper routine used to send bytes. It also updates the running F16 checksum. It assumes
    the tx pin is already an output.
  Usage:    mov         _txCount, <number to send != 0>
            movs        txHandoff, #<buffer register>   (no # if using pointer)
            call        #txSendBytes                                                }
txSendBytes
                                mov         par, #0                                 'par used to perform handoff every 4 bytes
                                mov         cnt, cnt                                'cnt used for timing
                                add         cnt, #21
txByteLoop                      test        par, #%11                   wz
txHandoff               if_z    mov         _txLong, 0-0
                        if_z    add         txHandoff, #1
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
txSendBytes_ret                 ret


{ Sending Routines: SendFinalResponse (jmp)
                    SendFinalAndReturn (call)
                    SendIntermediate (call)         }
SendFinalResponse
                                movs        Send_ret, #ReceiveCommand
SendFinalAndReturn
                                movs        txApplyTemplate, #$90
                                jmp         #txPerformChecks
SendIntermediate
                                movs        txApplyTemplate, #$80
                                { check if muted, and ensure payload length is within specification limits }
txPerformChecks                 test        packetInfo, #conMuteFlag            wc      'c=1 muted
                        if_c    jmp         Send_ret                                    '...must not send anything if responses muted
                                max         payloadLength, k7FF                         'must not exceed specification max
                                { compose header bytes RH0-RH2 }
                                mov         _txLong, token
                                shl         _txLong, #8
                                mov         _txCount, payloadLength                     '_txCount being used as a scratch register for next 8 instructions
                                and         _txCount, #$ff
                                or          _txLong, _txCount
                                shl         _txLong, #8
                                mov         _txCount, payloadLength
                                shr         _txCount, #8
txApplyTemplate                 or          _txCount, #0-0
                                or          _txLong, _txCount
                                { reset F16 }
                                mov         _txF16L, #0
                                mov         _txF16U, #0
                                { send header }
                                mov         _txCount, #3
                                movs        txHandoff, #_txLong
txRetainLine                    or          dira, txMask
                                call        #txSendBytes
                                call        #txSendAndResetF16
                                { send body, in chunks (payload data + F16 sums) }
                                movs        txSetHandoff, sendBufferPointer
                                mov         _txRemaining, payloadLength
txPayloadLoop                   mov         _txCount, _txRemaining              wz
                        if_z    jmp         #txLoopExit
                                max         _txCount, #128                              'chunks are 128 bytes of payload data
                                sub         _txRemaining, _txCount
txSetHandoff                    movs        txHandoff, #0-0
                                call        #txSendBytes
                                call        #txSendAndResetF16
                                add         txSetHandoff, #32                           'next chunk (if any) is at +32 registers
                                jmp         #txPayloadLoop
txLoopExit
txReleaseLine                   andn        dira, txMask
Send_ret
SendFinalAndReturn_ret
SendIntermediate_ret            ret

sendBufferPointer       long    Payload     'potential nop if only lower 9 bits set


{ ==========  Begin User Block  ========== }


{ User Code }
{ This is where PropCR code will jmp to when a valid user command packet has arrived.
  Refer to "PropCR-Fast User Guide.txt" for more information. }
UserCode
                                jmp         #ReceiveCommand


{ Break Handler }
{ This code is jmp'd to when PropCR detects a break condition. }
BreakHandler
                                waitpeq     rxMask, rxMask          'wait for break to end
                                jmp         #ReceiveCommand


{ ==========  Begin Temporaries  ========== }


{ Registers 486 to 495 are reserved for temporaries. }

fit 486     'If this fails then either user code or the payload buffer must be reduced.
org 486

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
_adminTmp               '_adminTmp must not alias a _tx* temporary
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


fit 496
