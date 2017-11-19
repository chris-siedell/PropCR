//
//  PropCRDefs.cpp
//  Final Sprint
//
//  Created by admin on 5/14/17.
//  Copyright © 2017 Chris Siedell. All rights reserved.
//

#include "PropCRDefs.hpp"



namespace propcr {

    std::string strForError(Error error) {
        switch (error) {
            case Error::None:
                return "none";
            case Error::Timeout:
                return "timeout";
            default:
                return "unknown";
        }
    }

    std::string strForTransaction(Transaction transaction) {
        switch (transaction) {
            case Transaction::None:
                return "None";
            case Transaction::UserCommand:
                return "User Command";
            case Transaction::Ping:
                return "Ping";
            case Transaction::GetDeviceInfo:
                return "Get Device Info";
            case Transaction::Break:
                return "Break";
            default:
                return "Unknown";
        }

    }
    
    
    
    
}