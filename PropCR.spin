{
======================================
PropCR.spin
Version 0.2 (alpha/experimental)
16 April 2018
Chris Siedell
http://siedell.com/projects/Crow/
http://siedell.com/projects/PropCR/
======================================

  This file is intended to serve as a base for implementing a Crow service. By default
it doesn't do anything except respond to standard Crow admin commands on port 0: ping,
echo, hostPresence, getDeviceInfo, getOpenPorts, and getPortInfo.

  This version does NOT have break detection. If break detection is required, use PropCR-BD.
 
  See "PropCR User Guide.txt" for more details.

  The following methods are available to change the default settings before launch:
    setPins(rxPin, txPin)
    setBaudrate(baudrate) - MUST come before set*InBitPeriods
    setInterbyteTimeoutInMS(milliseconds) - MUST follow setBaudrate
    setInterbyteTimeoutInBitPeriods(count) - MUST follow setBaudrate
    setRecoveryTimeInMS(milliseconds)
    setRecoveryTimeInBitPeriods(count)
    setAddress(address)
    setPort(port)

  Setting the baudrate must come before setting the interbyte timeout or recovery time.

  Calling the set* methods has no effect on launched instances.

  start will not return until the new instance is completely loaded, so calling code
may immediately prepare to launch another instance.
}

con
    
    { Compile-Time Constants
        cNumPayloadRegisters determines the size of the payload buffer. This buffer is where PropCR
      puts received command payloads. It is also where PropCR sends response payloads from, unless
      sendBufferPointer is changed (by default it points to Payload).
    }
    cNumPayloadRegisters    = 128       'MUST be even. Needs to be large enough for initialization code.
    cMaxPayloadSize = 4*cNumPayloadRegisters
    
    { Default Settings
        These settings may be changed before cog launch -- see Spin methods.
    }
    cClkfreq                    = 80_000_000    'used just for calculating derived default settings
    cRxPin                      = 31            'must be 0-31
    cTxPin                      = 30            'must be 0-31
    cBaudrate                   = 115200        'the minimum supported bit period (clkfreq/baudrate) is 26 clocks
    cInterbyteTimeoutInMS       = 1
    cRecoveryTimeInBitPeriods   = 16            'recoveryTime should be greater than a byte period
    cAddress                    = 1             'must be 1-31
    cUserPort                   = 32            'must be a one-byte value other than 0, recommended to use 32+
    
    { Derived Default Settings }
    cTwoBitPeriod = (2*cClkfreq) / cBaudrate
    cBitPeriod0 = cTwoBitPeriod >> 1
    cBitPeriod1 = cBitPeriod0 + (cTwoBitPeriod & 1) 
    cStartBitWait = (cBitPeriod0 >> 1) - 10 #> 5
    cStopBitDuration = ((10*cClkfreq) / cBaudrate) - 5*cBitPeriod0 - 4*cBitPeriod1 + 1
    cTimeout = (cClkfreq/1000) * cInterbyteTimeoutInMS
    cRecoveryTime = cBitPeriod0 * cRecoveryTimeInBitPeriods
    
    { Flags and Masks for packetInfo (which is CH2). }
    cRspExpectedFlag        = $80
    cAddressMask            = %0001_1111
    
    { Crow error response types. }
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
    
    { Crow admin error status numbers. }
    cAdminCommandNotAvailable   = 1
    cAdminMissingParameters     = 2
    
    { Special Purpose Registers
        To save space, PropCR makes use of some special purpose registers. The following SPRs are used for
      variables and temporaries: sh-par, sh-cnt, sh-ina, sh-inb, outb, dirb, vcfg, and vscl.
        The "_SH" suffix is a reminder to always used the variable/temporary as a destination register.
        PropCR uses the counter B module in RecoveryMode (when waiting for rx line idle).
        PropCR never uses the counter A module or its registers -- it leaves it free for custom use.
        PropCR does not use the actual PAR register (only the shadow register), so it is free for custom use.
    }
    _txWait_SH          = $1f0  'sh-par
    _rxPort_SH          = $1f0  'sh-par
    
    _txByteNum_SH       = $1f1  'sh-cnt
    _rxTmp_SH           = $1f1  'sh-cnt
    
    _txBitCountdown_SH  = $1f2  'sh-ina
    _rxCH0inc_SH        = $1f2  'sh-ina - CH0 (incomplete -- does not include bit 7) is saved in-loop for reserved bits testing
   
    _rxF16U_SH          = $1f3  'sh-inb
    
    token               = $1f5  'outb - token is assigned in the recieve loop; this register is also used for composing the response header (unsuitable as nop)
    packetInfo          = $1f7  'dirb -  packetInfo is CH2; potential nop; upper bytes always set to 0 (from _rxByte)
    sendBufferPointer   = $1fe  'vcfg - (video generator is off if bits 29-30 are zero); points to Payload (0) by default; should always be 9-bit value; potential nop
    
    'Important: the upper bytes of _rxByte (i.e. VSCL) must be zero before ReceiveCommand is executed.
    _txByte             = $1ff  'vscl - same as for _rxByte (upper bytes temporarily non-zero until masked, so not suitable for vcfg or ctrx, but ok to alias _rxByte)
    _rxByte             = $1ff  'vscl - important: it is assumed the upper bytes of this register are always zero (required for F16 calculation)
    

var
    long __twoBitPeriod

pub setPins(__rxPin, __txPin)
    rxMask := |< __rxPin
    txMask := |< __txPin
    rcvyLowCounterMode := (rcvyLowCounterMode & $ffff_ffe0) | (__rxPin & $1f)

pub setBaudrate(__baudrate)
    __twoBitPeriod := (clkfreq << 1) / __baudrate #> 52
    bitPeriod0 := __twoBitPeriod >> 1
    bitPeriod1 := bitPeriod0 + (__twoBitPeriod & 1)
    startBitWait := (bitPeriod0 >> 1) - 10 #> 5
    stopBitDuration := ((10*clkfreq) / __baudrate) - 5*bitPeriod0 - 4*bitPeriod1 + 1

pub setInterbyteTimeoutInMS(__milliseconds)
    timeout := __milliseconds*(clkfreq/1000) #> __twoBitPeriod

pub setInterbyteTimeoutInBitPeriods(__count)
    timeout := __count*bitPeriod0 #> __twoBitPeriod

pub setRecoveryTimeInMS(__milliseconds)
    recoveryTime := __milliseconds*(clkfreq/1000)

pub setRecoveryTimeInBitPeriods(__count)
    recoveryTime := __count*bitPeriod0

pub setAddress(__address)
    _RxCheckAddress := (_RxCheckAddress & $ffff_ffe0) | (__address & $1f)

pub setPort(__port)
    _AdminOpenPortsList := (_AdminOpenPortsList & $ffff_ff00) | (__port & $ff)
    _AdminCheckUserPort := (_AdminCheckUserPort & $ffff_ff00) | (__port & $ff)
    _RxCheckUserPort := (_RxCheckUserPort & $ffff_ff00) | (__port & $ff)

pub start
    result := cognew(@Init, 0) + 1          'PropCR does not use par, so it is free for user code
    waitcnt(cnt + 10000)                    'wait for cog loading to finish to protect settings of just launched cog


dat

{ ==========  Begin Payload Buffer and Initialization  ========== }

{ Payload and Init
    The payload buffer is where PropCR will put received payloads. It is also where it will send
  response payloads from unless sendBufferPointer is changed.
    The payload buffer is placed at the beginning of the cog for two reasons:
        - this is a good place to put one-time initialization code, and
        - having a fixed location is convenient for executing compiled code sent as a payload.
    Since the initialization code may not take up the entire buffer, shifting code is included that
  will shift the permanent code into place. This prevents wasting excessive hub space with an empty buffer.
}
org 0
Init
Payload
                                { First, shift everything into place. Assumptions:
                                    - The actual content (not address) of the register after initEnd is initShiftStart (nothing
                                      but org and res'd registers between them).
                                    - All addresses starting from initShiftLimit and up are res'd and are not shifted. }
                                mov         _initCount, #initShiftLimit - initShiftStart
initShift                       mov         initShiftLimit-1, initShiftLimit-1-(initShiftStart - (initEnd + 1))
                                sub         initShift, initOneInDAndSFields
                                djnz        _initCount, #initShift

                                { As originally written, this implementation will include "P8X32A (cog N)" as the
                                    device description in response to a getDeviceInfo admin command. Here we
                                    determine the 'N'. }
                                cogid       _initTmp
                                shl         _initTmp, #16
                                add         getDeviceInfoCogNum, _initTmp

                                { Misc. }
                                mov         frqb, #1
                                or          outa, txMask                            'prevent glitch when retaining tx line for first time

                                jmp         #ReceiveCommand


{ initEnd is the last real (not reserved) register before initShiftStart. Its address is used by the initialization shifting code. }
initEnd
initOneInDAndSFields            long    $201

fit cNumPayloadRegisters 'On error: not enough room for init code.
org cNumPayloadRegisters

{ ==========  Begin PropCR Block  ========== }

{   It is possible to place res'd registers here (between initEnd and initShiftStart) -- the shifting
  code will accommodate them. However, bitPeriod0 must always be at an even address register. }

{ Settings Notes
    The following registers store some settings. Some settings are stored in other locations (within
  instructions in some cases), and some are stored in multiple locations.
}
initShiftStart
bitPeriod0              long    cBitPeriod0
bitPeriod1              long    cBitPeriod1
startBitWait            long    cStartBitWait 
stopBitDuration         long    cStopBitDuration
timeout                 long    cTimeout
recoveryTime            long    cRecoveryTime
rxMask                  long    |< cRxPin           'rx pin also stored in rcvyLowCounterMode
txMask                  long    |< cTxPin


{ ReceiveCommand (jmp)
    This routine waits for a command and then processes it in ReceiveCommandFinish. It makes use
  of instructions that are shifted into the receive loop (see 'RX Parsing Instructions' and
  'RX StartWait Instructions').
}
ReceiveCommand
                                { Pre-loop initialization. }
                                mov         _rxWait0, startBitWait                  'see page 99
                                mov         _RxStartWait, rxContinue
                                movs        _RxMovA, #rxFirstParsingGroup
                                movs        _RxMovB, #rxFirstParsingGroup+1
                                movs        _RxMovC, #rxFirstParsingGroup+2
                                mov         _rxResetOffset, #0

                                { Wait for start bit edge. }
                                waitpne     rxMask, rxMask
                                add         _rxWait0, cnt

                                { Sample start bit. }
                                waitcnt     _rxWait0, bitPeriod0
                                test        rxMask, ina                     wc      'c=1 framing error; c=0 continue, with reset
                        if_c    jmp         #RecoveryMode

                                { The receive loop -- c=0 will reset parser. }
_RxLoopTop
:bit0                           waitcnt     _rxWait0, bitPeriod1
                                testn       rxMask, ina                     wz
                        if_nc   mov         _rxF16L, #0                             'F16 1 - see page 90
                        if_c    add         _rxF16L, _rxByte                        'F16 2
                        if_c    cmpsub      _rxF16L, #255                           'F16 3
                                muxz        _rxByte, #%0000_0001

:bit1                           waitcnt     _rxWait0, bitPeriod0
                                testn       rxMask, ina                     wz
                                muxz        _rxByte, #%0000_0010
                        if_nc   mov         _rxF16U_SH, #0                          'F16 4
                        if_c    add         _rxF16U_SH, _rxF16L                     'F16 5
                        if_c    cmpsub      _rxF16U_SH, #255                        'F16 6

:bit2                           waitcnt     _rxWait0, bitPeriod1
                                testn       rxMask, ina                     wz
                                muxz        _rxByte, #%0000_0100
                        if_nc   mov         _rxOffset, _rxResetOffset               'Shift 1 - see page 93
                                subs        _rxResetOffset, _rxOffset               'Shift 2
                                adds        _RxMovA, _rxOffset                      'Shift 3

:bit3                           waitcnt     _rxWait0, bitPeriod0
                                testn       rxMask, ina                     wz
                                muxz        _rxByte, #%0000_1000
                                adds        _RxMovB, _rxOffset                      'Shift 4
                                adds        _RxMovC, _rxOffset                      'Shift 5
                                mov         _rxOffset, #3                           'Shift 6

:bit4                           waitcnt     _rxWait0, bitPeriod1
                                testn       rxMask, ina                     wz
                                muxz        _rxByte, #%0001_0000
_RxMovA                         mov         _RxShiftedA, 0-0                        'Shift 7
_RxMovB                         mov         _RxShiftedB, 0-0                        'Shift 8
_RxMovC                         mov         _RxShiftedC, 0-0                        'Shift 9

:bit5                           waitcnt     _rxWait0, bitPeriod0
                                testn       rxMask, ina                     wz
                                muxz        _rxByte, #%0010_0000
                                mov         _rxWait1, _rxWait0                      'Wait 2
                                mov         _rxWait0, startBitWait                  'Wait 3
                                sub         _rxCountdown, #1                wz      'Countdown (undefined on reset)

:bit6                           waitcnt     _rxWait1, bitPeriod1
                                test        rxMask, ina                     wc
                                muxc        _rxByte, #%0100_0000
                        if_nc   mov         _rxCH0inc_SH, _rxByte                   'save CH0 (up through bit 6) for reserved bits testing
_RxShiftedA                     long    0-0                                         'Shift 10
                                shl         _rxLong, #8                             'Buffering 1 (_rxLong undefined on reset)

:bit7                           waitcnt     _rxWait1, bitPeriod0
                                test        rxMask, ina                     wc
                                muxc        _rxByte, #%1000_0000
                                or          _rxLong, _rxByte                        'Buffering 2
_RxShiftedB                     long    0-0                                         'Shift 11
_RxShiftedC                     long    0-0                                         'Shift 12

:stopBit                        waitcnt     _rxWait1, bitPeriod0                    'see page 98
                                testn       rxMask, ina                     wz      'z=0 framing error

_RxStartWait                    long    0-0                                         'wait for start bit, or exit loop
                        if_z    add         _rxWait0, cnt                           'Wait 1

:startBit               if_z    waitcnt     _rxWait0, bitPeriod0
                        if_z    test        rxMask, ina                     wz      'z=0 framing error
                        if_z    mov         _rxTmp_SH, _rxWait0                     'Timeout 1
                        if_z    sub         _rxTmp_SH, _rxWait1                     'Timeout 2 - see page 98 for timeout notes
                        if_z    cmp         _rxTmp_SH, timeout              wc      'Timeout 3 - c=0 reset, c=1 no reset
                        if_z    jmp         #_RxLoopTop

                        { fall through to RecoveryMode for framing errors }

{ RecoveryMode (jmp)
    In recovery mode the implementation waits for the rx line to be idle for at least recoveryTime clocks, then
  it will jump to ReceiveCommand to wait for a command.
    RecoveryMode uses the counter B module to count the number of clocks that the rx line is low. It turns the
  counter module off before exiting since it consumes some extra power, but this is not required.
}
RecoveryMode
                                mov         ctrb, rcvyLowCounterMode                'start counter B module counting clocks the rx line is low
                                mov         _rcvyWait, recoveryTime
                                add         _rcvyWait, cnt
                                mov         _rcvyPrevPhsb, phsb

:loop                           waitcnt     _rcvyWait, recoveryTime
                                mov         _rcvyCurrPhsb, phsb
                                cmp         _rcvyPrevPhsb, _rcvyCurrPhsb    wz      'z=1 line is idle (was never low), so exit
                        if_z    mov         ctrb, #0                                'turn off counter B module
                        if_z    jmp         #ReceiveCommand
                                mov         _rcvyPrevPhsb, _rcvyCurrPhsb
                                jmp         #:loop


{ RX Parsing Instructions, used by ReceiveCommand
    There are three parsing instructions per byte received. Shifted parsing code executes inside the
  receive loop at _RxShiftedA-C. See pages 102, 97, 94.
}
rxFirstParsingGroup
rxH0                
                                xor         _rxCH0inc_SH, #1                    'A - _rxCH0inc was saved in-loop (up through bit 6); bit 0 should be 1 (invert to test)
                                test        _rxCH0inc_SH, #%0100_0111   wz      ' B - z=1 good reserved bits 0-2 and 6
                    if_nz_or_c  jmp         #RecoveryMode                       ' C - ...abort if bad reserved bits (c = bit 7 must be 0)
rxH1                            
                                shr         _rxLong, #3                         'A - prepare _rxLong to hold payloadSize (_rxLong buffering occurs between A and B)
                                mov         payloadSize, _rxLong                ' B - payloadSize still needs to be masked (upper bits undefined)
                                and         payloadSize, k7FF                   ' C - payloadSize is ready
rxH2 
                                test        _rxByte, #%0110_0000        wz      'A - test reserved bits 5 and 6 of CH2 (they must be zero)
                        if_nz   jmp         #RecoveryMode                       ' B - ...abort for bad reserved bits
                                mov         packetInfo, _rxByte                 ' C - save CH2 as packetInfo for later use
rxH3
                                mov         _rxRemaining, payloadSize           'A - _rxRemaining = number of bytes of payload yet to receive
                                mov         _rxNextAddr, #Payload               ' B - must reset _rxNextAddr before rxP* code
                                mov         _rxPort_SH, _rxByte                 ' C - save the port number
rxH4
kFFFF                           long    $ffff                                   'A - (spacer nop) lower word mask
k7FF                            long    $7ff                                    ' B - (spacer nop) 2047 = maximum payload length allowed by Crow specification
                                mov         token, _rxByte                      ' C - save the token
rxF16_C0 
                                mov         _rxLeftovers, _rxLong               'A - preserve any leftover bytes in case this is the end
                                mov         _rxCountdown, _rxRemaining          ' B - _rxCountdown = number of payload bytes in next chunk
                                max         _rxCountdown, #128                  ' C - chunks have up to 128 payload bytes
rxF16_C1
                                add         _rxCountdown, #1            wz      'A - undo automatic decrement; z=1 the next chunk is empty -- i.e. done
                                sub         _rxRemaining, _rxCountdown          ' B - decrement the payload bytes remaining counter by the number in next chunk
                        if_z    mov         _RxStartWait, rxExit                ' C - z=1 no payload left, so exit
rxP0_Eval
                        if_z    subs        _rxOffset, #9                       'A - go to rxF16_C0 if done with chunk's payload
                                or          _rxF16U_SH, _rxF16L         wz      ' B - z=0 bad F16 (both F16L and F16U should be zero at this point)
                        if_nz   jmp         #RecoveryMode                       ' C - ...abort for bad F16
rxP1                    
                        if_z    subs        _rxOffset, #12                      'A - go to rxF16_C0 if done with chunk's payload
                                cmp         payloadSize, maxPayloadSize wc, wz  ' B - test for potential buffer overrun
                if_nc_and_nz    mov         _rxNextAddr, #Payload               ' C - payload too big for buffer so keep rewriting first long (will report Crow error later)
rxP2                    
                        if_z    subs        _rxOffset, #15                      'A - go to rxF16_C0 if done with chunk's payload
maxPayloadSize                  long    cMaxPayloadSize & $7ff                  ' B - (spacer nop) payloads must be 2047 or less by Crow specification
                                movd        _RxStoreLong, _rxNextAddr           ' C - prep to write next long to buffer
rxP3                    
                        if_z    subs        _rxOffset, #18                      'A - go to rxF16_C0 if done with chunk's payload
_RxStoreLong                    mov         0-0, _rxLong                        ' B
                                add         _rxNextAddr, #1                     ' C - incrementing _rxNextAddr and storing the long must occur in same block
rxP0                    
                        if_z    subs        _rxOffset, #21                      'A - go to rxF16_C0 if done with chunk's payload
                        if_nz   subs        _rxOffset, #12                      ' B - otherwise go to rxP1
rcvyLowCounterMode              long    $3000_0000 | ($1f & cRxPin)             ' C - (spacer nop) rx pin number should be set before launch


{ RX StartWait Instructions, used by ReceiveCommand
    These instructions are shifted to _RxStartWait in the receive loop to either receive more bytes or
  to exit the loop. The 'if_z' causes the instruction to be skipped if a framing error is detected on the stop bit.
}
rxContinue              if_z    waitpne     rxMask, rxMask                      'executed at _RxStartWait
rxExit                  if_z    jmp         #ReceiveCommandFinish               'executed at _RxStartWait


{ ReceiveCommandFinish 
    This is where the receive loop exits to when all bytes of the packet have arrived.
}
ReceiveCommandFinish
                                { Prepare to store any leftover (unstored) payload. This is OK even if the payload exceeds capacity. In
                                    that case _rxNextAddr will be Payload or Payload+1, and we assume there is at least two long's
                                    worth of payload capacity, so no overrun occurs. }
                                test        payloadSize, #%11               wz      'z=0 leftovers exist
                        if_nz   movd        _RxStoreLeftovers, _rxNextAddr

                                { Evaluate F16 for last byte. These are also spacer instructions that don't change z.
                                    There is no need to compute upper F16 -- it should already be 0 if there are no errors. }
                                add         _rxF16L, _rxByte
                                cmpsub      _rxF16L, #255

                                { Store the leftover payload, if any. Again, this is safe even if the command's payload
                                    exceeds capacity (see above). }
_RxStoreLeftovers       if_nz   mov         0-0, _rxLeftovers

                                { Verify the last F16. }
                                or          _rxF16U_SH, _rxF16L             wz      'z=0 bad F16
                        if_nz   jmp         #RecoveryMode                           '...bad F16 (invalid packet)

                                { Extract the address. }
                                mov         _rxTmp_SH, packetInfo
                                and         _rxTmp_SH, #cAddressMask        wz      'z=1 broadcast address; _rxTmp is now packet's address
                                test        packetInfo, #cRspExpectedFlag   wc      'c=1 response is expected/required
                    if_z_and_c  jmp         #RecoveryMode                           '...broadcast commands must not expect a response (invalid packet)

                                { Check the address if not broadcast. }
_RxCheckAddress         if_nz   cmp         _rxTmp_SH, #cAddress            wz      'z=0 addresses don't match; address (s-field) may be set before launch
                        if_nz   jmp         #ReceiveCommand                         '...valid packet, but not addressed to this device

                                { At this point we have determined that the command was properly formatted and
                                    intended for this device (whether specifically addressed or broadcast). }

                                { Verify that the payload size was under the limit. If it exceeded capacity then the
                                    payload bytes weren't actually saved, so there's nothing to do except report
                                    that the command was too big. }
                                cmp         payloadSize, maxPayloadSize     wc, wz
                if_nc_and_nz    mov         Payload, #cCommandTooLarge
                if_nc_and_nz    jmp         #SendCrowError

                                { Check the port. }
_RxCheckUserPort                cmp         _rxPort_SH, #cUserPort          wz      'z=1 command is for user code; s-field set before launch
                        if_z    jmp         #UserCode
                                cmp         _rxPort_SH, #0                  wz      'z=1 command is for Crow admin (using fall-through to save a jmp)

                                { Report that the port is not open (if not Crow admin). }
                        if_nz   mov         Payload, #cPortNotOpen
                        if_nz   jmp         #SendCrowError 

                        { fall through to CrowAdmin for port 0 }

{ CrowAdmin
    CrowAdmin starts the process of responding to standard admin commands (port 0). The admin
  code assumes that sendBufferPointer points to Payload.
    Supported admin commands: ping, echo/hostPresence, getDeviceInfo, getOpenPorts, and getPortInfo.
}
CrowAdmin
                                { Crow admin command with no payload is ping. }
                                cmp         payloadSize, #0                 wz      'z=1 ping command
                        if_z    jmp         #SendResponse                           'the ping response also has no payload

                                { All other Crow admin commands must have at least three bytes, starting
                                    with 0x43 and 0x41. }
                                cmp         payloadSize, #3                 wc      'c=1 too few bytes
                        if_nc   mov         _admTmp, Payload
                        if_nc   and         _admTmp, kFFFF
                        if_nc   cmp         _admTmp, k4143                  wz      'z=0 bad identifying bytes
                    if_c_or_nz  jmp         #ReportUnknownProtocol

                                { The third byte provides the specific command. }
                                mov         _admTmp, Payload
                                shr         _admTmp, #16
                                and         _admTmp, #$ff                   wz      'z=1 type==0 -> echo/hostPresence
                        if_z    jmp         #SendResponse                           'payload is identical for echo (command 0x00 becomes status OK)
                                cmp         _admTmp, #1                     wz      'z=1 type==1 -> getDeviceInfo
                        if_z    jmp         #AdminGetDeviceInfo
                                cmp         _admTmp, #2                     wz      'z=1 type==2 -> getOpenPorts
                        if_z    jmp         #AdminGetOpenPorts
                                cmp         _admTmp, #3                     wz      'z=1 type==3 -> getPortInfo
                        if_z    jmp         #AdminGetPortInfo

                                { PropCR does not support any other admin commands. }
                                mov         Payload, #cAdminCommandNotAvailable

                            { fall through to AdminSendError }

{ AdminSendError (jmp)
    This routine sends an admin protocol level error response. It should be used only if we are confident
  that the command was an admin command.
    Payload should be set with the error status code before jumping to this code.
}
AdminSendError
                                shl         Payload, #16
                                or          Payload, k4143
                                mov         payloadSize, #3
                                jmp         #SendResponse


{ AdminGetDeviceInfo (jmp)
    This routine provides basic info about the Crow device. The response has already been prepared -- all we need to
  do is direct sendBufferPointer to its location, and then remember to set the pointer back to Payload afterwards.
}
AdminGetDeviceInfo
                                mov         sendBufferPointer, #getDeviceInfoBuffer
                                mov         payloadSize, #40
                                call        #SendResponseAndReturn
                                mov         sendBufferPointer, #Payload
                                jmp         #ReceiveCommand


{ AdminGetOpenPorts (jmp)
    The getOpenPorts response consists of six bytes: 0x43, 0x41, 0x00, 0x00, plus the user port and admin port 0.
}
AdminGetOpenPorts
                                mov         Payload, k4143
_AdminOpenPortsList             mov         Payload+1, #cUserPort                   's-field set before launch (admin port 0 gets set automatically)
                                mov         payloadSize, #6
                                jmp         #SendResponse

{ AdminGetPortInfo (jmp)
    The getPortInfo response returns information about a specific port.
}
AdminGetPortInfo                { The port number of interest is in the fourth byte of the command. }
                                cmp         payloadSize, #4                 wc      'c=1 command too short
                        if_c    mov         Payload, #cAdminMissingParameters
                        if_c    jmp         #AdminSendError
                                mov         _admTmp, Payload
                                shr         _admTmp, #24                    wz      '_admTmp is the requested port number; z=1 admin port 0
                
                                { If z=1 then the requested port number is 0 (Crow admin). }
                        if_z    mov         sendBufferPointer, #getPortInfoBuffer_Admin
                        if_z    mov         payloadSize, #16
                        if_z    jmp         #_AdminGetPortInfoFinish

                                { Check if it is the user port. }
_AdminCheckUserPort             cmp         _admTmp, #cUserPort             wz      'z=1 user port; s-field set before launch
                        if_z    mov         sendBufferPointer, #getPortInfoBuffer_User
                        if_z    mov         payloadSize, #4
            
                                { If it is not the admin port or the user port, then the port is closed. }
                        if_nz   mov         sendBufferPointer, #getPortInfoBuffer_Closed
                        if_nz   mov         payloadSize, #4

_AdminGetPortInfoFinish         call        #SendResponseAndReturn
                                mov         sendBufferPointer, #Payload
                                jmp         #ReceiveCommand


{ The following buffers are prepared values for admin responses. If any of these buffers are changed
    remember to update the payload sizes in the above code. }

getDeviceInfoBuffer
long $0200_4143         'packet identifier (0x43, 0x41), status=0 (OK), implementation's Crow version = 2
long ((cMaxPayloadSize & $ff) << 24) | ((cMaxPayloadSize & $0700) << 8) | ((cMaxPayloadSize & $0700) >> 8) | ((cMaxPayloadSize & $ff) << 8) 'buffer sizes, MSB first
long $0b0f_0005         'packet includes implementation ascii description and device ascii description; implAsciiDesc has 11 bytes length at offset 15
long $500e_1a00         'device ascii description has length of 14 bytes at offset 26; first char of implAsciiDesc is 'P' (final string is "PropCR v0.2")
long $4370_6f72         '"ropC"
long $3076_2052         '"R v0"
long $3850_322e         '".2"; deviceAsciiDesc starts with "P8" (final string is "P8X32A (cog N)")
long $4132_3358         '"X32A"
long $6f63_2820         '" (co"
getDeviceInfoCogNum
long $2930_2067         '"g N)" - initializing code adds cogID to third byte to get numeral

getPortInfoBuffer_Admin
long $0300_4143         'packet identifier (0x43, 0x41), status=0 (OK), port is open, protocolIdentStr included
long $4309_0700         'protocolIdentStr starts at offset 7 and has length 9; first char is "C"; final string = "CrowAdmin"
long $4177_6f72         '"rowA"
long $6e69_6d64         '"dmin"

getPortInfoBuffer_User
long $0100_4143         'packet identifier (0x43, 0x41), status=0 (OK), port is open, no other details

getPortInfoBuffer_Closed                            'k4143 works as prepared response for getPortInfo for a closed port (size 4 bytes)
k4143                           long    $4143       'identifying bytes for Crow admin packets; potential nop


{ TxSendAndResetF16 (call)
    Helper routine to send the current F16 checksums (upper sum, then lower sum). It also resets
  the checksums after sending.
}
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
    Helper routine used to send bytes. It also updates the running F16 checksums. It assumes
  the tx pin is already an output.
    Usage:  mov         _txCount, <number of bytes to send, MUST be non-zero>
            movs        _TxHandoff, <buffer address, sending starts with low byte>
            call        #TxSendBytes
    After: _txCount = 0                                         
}
TxSendBytes
                                mov         _txByteNum_SH, #0
                                mov         _txWait_SH, cnt
                                add         _txWait_SH, #21
_TxByteLoop                     test        _txByteNum_SH, #%11         wz          'z=1 byteNum%4 == 0, so load next long
_TxHandoff              if_z    mov         _txLong, 0-0
                        if_z    add         _TxHandoff, #1
:startBit                       waitcnt     _txWait_SH, bitPeriod0
                                andn        outa, txMask
                                mov         _txByte, _txLong
                                and         _txByte, #$ff                           '_txByte MUST be masked for F16 (also required since it aliases _rxByte)
                                add         _txF16L, _txByte
                                ror         _txLong, #1                 wc
:bit0                           waitcnt     _txWait_SH, bitPeriod1
                                muxc        outa, txMask
                                cmpsub      _txF16L, #255
                                add         _txF16U, _txF16L
                                cmpsub      _txF16U, #255
                                ror         _txLong, #1                 wc
:bit1                           waitcnt     _txWait_SH, bitPeriod0
                                muxc        outa, txMask
                                add         _txByteNum_SH, #1
                                mov         _txBitCountdown_SH, #6
:bitLoop                        ror         _txLong, #1                 wc
:bits2to7                       waitcnt     _txWait_SH, bitPeriod1
                                muxc        outa, txMask
                                xor         :bits2to7, #1                           'this is why bitPeriod0 must be at even address, with bitPeriod1 next
                                djnz        _txBitCountdown_SH, #:bitLoop
:stopBit                        waitcnt     _txWait_SH, stopBitDuration
                                or          outa, txMask
                                djnz        _txCount, #_TxByteLoop
                                waitcnt     _txWait_SH, #0                          'do not return until stop bit duration expires
TxSendBytes_ret                 ret


{ ReportUnknownProtocol (jmp)
    Both admin and user code may use this routine to send a UnknownProtocol Crow-level
  error response. This is the correct action to take if the received command does not
  conform to the expected protocol format.
    After sending the error response execution goes to ReceiveCommand.
}
ReportUnknownProtocol
                                mov         Payload, #cUnknownProtocol

                            { fall through to SendCrowError }

{ SendCrowError (jmp)
    This routine sends a Crow-level error response.
    It assumes the low byte of Payload has been set to the error number (and that no
  other bits of E0 are set -- PropCR does not send error details).
}
SendCrowError                   movs        _SendApplyTemplate, #$82                'this modification of the RH0 template is automatically reverted at end of sending
                                mov         payloadSize, #1

                            { fall through to SendResponse }

{ SendResponse (jmp), SendResponseAndReturn (call)
    Usage:  mov     payloadSize, <size of payload, in bytes, may be zero>
           (mov     sendBufferPointer, #<register of start of buffer>) 'sendBufferPointer = Payload = 0 by default; warning: admin code assumes sendBufferPointer = Payload
            jmp     #SendResponse
            -or-
            call    #SendResponseAndReturn
    After: payloadSize will be undefined. All tmp*v temporaries will also be undefined (i.e. those that alias _tx* temporaries).
}
SendResponse                    movs        Send_ret, #ReceiveCommand
SendResponseAndReturn
                                { Verify that there's an open transaction (i.e. that we are allowed to send a response). }
                                test        packetInfo, #cRspExpectedFlag       wc      'c=0 response forbidden
                        if_nc   jmp         #_SendDone                                  '...must not send if responses forbidden

                                { Make sure the payload size is within specification -- truncate if necessary. This is done to prevent
                                    sending too many payload bytes -- the payload size in the header will always be 11 bits. }
                                max         payloadSize, k7FF

                                { Compose header bytes RH0-RH2 in token (so RH2 already set). }
                                shl         token, #8                                   'RH2 = token
                                mov         _txCount, payloadSize                       '_txCount being used for scratch
                                and         _txCount, #$ff
                                or          token, _txCount                             'RH1 = lower eight bits of payloadSize
                                shl         token, #8
                                mov         _txCount, payloadSize
                                shr         _txCount, #5
                                and         _txCount, #%0011_1000
_SendApplyTemplate              or          _txCount, #2                                'RH0 template (s-field) is changed only for error responses, then reverted when done
                                or          token, _txCount                             'RH0 = upper three bits of payloadSize, errorFlag, and reserved bits

                                { Reset F16. }
                                mov         _txF16L, #0
                                mov         _txF16U, #0

                                { Retain line (make output). }
                                or          dira, txMask

                                { Send the header (in token). }
                                mov         _txCount, #3
                                movs        _TxHandoff, #token
                                call        #TxSendBytes
                                call        #TxSendAndResetF16

                                { Send body, in chunks (payload data + F16 sums). }
                                movs        :setHandoff, sendBufferPointer
                                mov         _txRemaining, payloadSize
:loop                           mov         _txCount, _txRemaining              wz
                        if_z    jmp         #:loopExit
                                max         _txCount, #128                              'chunks are 128 bytes of payload data
                                sub         _txRemaining, _txCount
:setHandoff                     movs        _TxHandoff, #0-0
                                call        #TxSendBytes
                                call        #TxSendAndResetF16
                                add         :setHandoff, #32                            'next chunk (if any) is at +32 registers
                                jmp         #:loop

:loopExit                       { Release line (make high-z). }
                                andn        dira, txMask
                                
_SendDone                       { Revert the RH0 template (in case this was an error response). }
                                movs        _SendApplyTemplate, #2
Send_ret
SendResponseAndReturn_ret       ret


{ ==========  Begin User Block  ========== }

{ UserCode (jmp)
    This is where PropCR code will jump to when a valid user command packet has arrived at the
  user port.
    Variables of interest:
        - Payload (register 0), the buffer where the command payload has been stored. Received
          data is stored in little-endian order within each long (assuming that 'propcr ordering'
          was used by the PC). If the payload size is not a multiple of four the remaining upper
          bytes of the last long will be undefined.
        - payloadSize, the size of the command payload, which may be zero (this variable is also 
          used for sending).
        - packetInfo, which is the third byte of the command header. It contains the address
          in the cAddressMask bits, and the responseExpected flag in the cRspExpectedFlag bit.
        - sendBufferPointer, which points to the first register of the response payload. By 
          default it points to Payload. It may be changed, but it must be restored to Payload
          before receiving the next command (the admin code assumes it is Payload).
    PropCR routines for user code:
        - SendResponse (jmp) or SendResponseAndReturn (call) to send a response. First, prepare
          the response payload and set payloadSize.
        - ReceiveCommand (jmp) to listen for another command.
        - ReportUnknownProtocol (jmp) to report that the command's format is not known and
          so no response can safely be sent.
        - SendCrowError (jmp) to send any other Crow-level error, such as RequestTooLarge. Set
          the low byte of Payload to the error number before jumping. 
    Other useful registers:
        - tmp0-tmp4 and tmp5v-tmp9v, scratch registers available for use. The 'v' temporaries
          are undefined after a SendResponseAndReturn call. All are undefined when
          UserCode is invoked.
        - the counter A registers, which user code is entirely free to use.
        - the PAR register, which PropCR does not use (it does use the shadow register).
    Warning: don't use other SPRs without consulting the 'Special Purpose Registers' section.
}
UserCode
                                jmp         #ReportUnknownProtocol


{ ==========  Begin Res'd Variables and Temporaries ========== }

fit 485 'On error: must reduce user code, payload buffer, or admin code.
org 485
initShiftLimit          'The initialization shifting code will ignore registers at and above this address.

{ Variables }
payloadSize     res     'used for both sending and receiving; potential nop; 11-bit value

{ Temporaries
    Registers 486 to 495 are reserved for temporaries. These are temporary (aka local or scratch) variables used
  by PropCR. User code may also use these registers. The temporaries ending with a "v" will be undefined after
  SendResponseAndReturn. All of these will be undefined immediately after a command is received.
    Some variables and temporaries are stored in special purpose registers -- see 'Special Purpose Registers'.
}
fit 486
org 486

{ The following five temporaries -- registers 486 to 490 -- preserve their values during a SendResponseAndReturn call. }

tmp0
_rxWait0        res

tmp1
_rxWait1        res

tmp2
_rxResetOffset  res

tmp3
_rxOffset       res

tmp4
_rxNextAddr     res

{ The following five "v" temporaries -- registers 491 to 495 -- are undefined after a SendResponseAndReturn call. }

tmp5v
_rcvyPrevPhsb
_txF16L
_rxF16L         res

tmp6v
_rcvyCurrPhsb
_txLong
_rxLong         res

tmp7v
_rcvyWait
_txF16U
_rxLeftovers    res

tmp8v
_initTmp
_txRemaining
_rxRemaining    res

tmp9v
_initCount
_admTmp
_txCount
_rxCountdown    res

fit 496



