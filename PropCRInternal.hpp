//
//  PropCRInternal.hpp
//  Final Sprint
//
//  Created by admin on 5/14/17.
//  Copyright © 2017 Chris Siedell. All rights reserved.
//

#ifndef PropCRInternal_hpp
#define PropCRInternal_hpp


#include <vector>
#include <mutex>


#include "PropCR.hpp"


namespace propcr {



#pragma mark - Parameter Verification

    // Throws std::invalid_argument if address is greater than 31.
    void throwIfAddressIsInvalid(uint8_t address);

    // Throws std::invalid_argument if the address is 0.
    void throwIfBroadcastAddress(uint8_t address);


#pragma mark - Packet Creation and Parsing

    // First, std::invalid_argument is thrown if any of the header fields are illegal.
    // std::invalid_argument is thrown if header.payloadLength does not equal payload.size().
    // Then buffer is cleared, and the header fields and payload data are copied into buffer
    //  as a command packet ready to be sent.
    // payload is not modified.
    void createCommandPacket(const CommandHeader& header, std::vector<uint8_t>& payload, std::vector<uint8_t>& buffer, bool reorderForProp = true);

    // Inspects bytes to see if the first four bytes constitute a valid response header (so
    //  bytes must have at least 4 bytes available). If a valid header was
    //  detected then the properties of header are set to the appropriate values --
    //  otherwise they are not changed. Returns a bool indicating if a header
    //  was successfully detected.
    bool parseResponseHeaderAndGetParams(uint8_t* bytes, ResponseHeader& header);

    // If parsing fails...
    //  - the function sets failureReason with details,
    //  - the function returns false, and
    //  - the values in info are undefined.
    bool parseGetDeviceInfoResponse(const ResponseHeader& header, const std::vector<uint8_t>& payload, DeviceInfo& info, std::string& failureReason);


#pragma mark - HostTransactionInitiator

    // Transactions may be started on any thread at any time.
    //  Transactions are performed one at a time on a special worker thread (the transaction
    //  thread) which exists for the life of the host object. The HostTransactionInitiator is a
    //  scope-based object for handing off a transaction from the intiating thread to the
    //  transaction thread.
    // If the host is busy when the initiator is created it will throw IsBusyError, so if the
    //  initiator object exists then the transaction is free to proceed.
    // Between the initiator creation and the startTransaction call the following are
    //  guaranteed:
    //  - No transactions are being performed or can begin. So there is no concurrent
    //    t_performTransaction call.
    //  - Only one initiator object can exist in that state at a time (i.e. created, but without
    //    a transaction started). So the code in that interval never runs concurrently.
    // These guarantees allow setting up the transaction in a thread safe way.
    // Throwing an exception between creating the intiator object and calling startTransaction
    //  is OK -- the host will be free to start another transaction.
    // Calling startTransaction signals to the transaction thread that there is a transaction
    //  to be performed. Eventually, this means that the host's t_performTransaction will be
    //  called on the transaction thread with the original transaction argument that was passed
    //  to startTransaction. Any other parameters that your t_performTransaction code needs to
    //  do its work should have been saved in between the initiator creation and the
    //  startTransaction call.
    // The call to startTransaction is also when the transaction specific settings are locked in.
    //  E.g. calling setBaudrate after that point won't affect the baudrate of the transaction.
    // startTransaction must not be called more than once.
    // The context is a pointer that is provided to the monitor callbacks. It may be ignored.
    // startTransaction has to be called on the thread the initiator was created on (shouldn't
    //  normally be a problem).
    // todo: consider alternative for blocking (instead of throwing IsBusyError), maybe with timeout

    class PropCR::TransactionInitiator {
    public:
        TransactionInitiator(PropCR& host);
        void startTransaction(Transaction transaction, void* context = NULL);
    private:
        bool transactionStarted = false;
        PropCR& host;
        std::unique_lock<std::mutex> lock;
    };


#pragma mark - TransactionError

    // An internal error type, thrown only on the transaction thread from t_performTransaction or
    //  subcalls. This includes the HostMonitor callbacks which allow exceptions, since they are
    //  called on the transaction thread.
    // Based on AsyncPropLoader's ActionError.
    class TransactionError : public std::runtime_error {
    public:
        TransactionError(Error error, const std::string& details) : error(error), std::runtime_error(details) {}
        const Error error;
    };


#pragma mark - Fletcher 16 Error Detection

    void getFletcher16(uint8_t* bytes, size_t numBytes, uint8_t& lower, uint8_t& upper);
    void getFletcher16Checkbytes(uint8_t lower, uint8_t upper, uint8_t& check0, uint8_t& check1);
    bool unequalFletcher16Sums(uint8_t lowerA, uint8_t upperA, uint8_t lowerB, uint8_t upperB);
    
    
}
#endif /* PropCRInternal_hpp */
