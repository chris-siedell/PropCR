
con
    _xinfreq = 5_000_000
    _clkmode = xtal1 + pll16x


obj

    propcrBD : "PropCR-BD.spin"


pub main

    propcrBD.setParams(31, 30, 230400, 12, 200)

    propcrBD.Start(48)

    dira[26..27] := %11
    outa[26..27] := %11

    repeat
        waitcnt(0)

