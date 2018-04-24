con
    _xinfreq = 5_000_000
    _clkmode = xtal1 + pll16x


obj
    propcr: "PropCR.spin"
    propcr_bd: "PropCR-BD.spin"


pub main

    propcr.start

    propcr_bd.setAddress(2)
    propcr_bd.start

