package main

import "core:fmt"

import prof "./otprofiller"

main :: proc ( ) {
    
    fmt.printfln( "\nBegin OTProfiller test...\n\n" )
    
    prof.test_example_main( )
    
    fmt.printfln( "\n\n...end OTProfiller test.\n" )
}
