//
//  PropCRDefs.hpp
//  Final Sprint
//
//  Created by admin on 5/14/17.
//  Copyright © 2017 Chris Siedell. All rights reserved.
//

#ifndef PropCRDefs_hpp
#define PropCRDefs_hpp

#include <string>
#include <vector>
#include <chrono>


namespace propcr {

    // This is the information obtained from a getDeviceInfo query.
    struct DeviceInfo {

        // The version of the Crow protocol the implementation claims to conform to.
        uint8_t crowVersion;

        // Two byte implementation identifier.
        uint16_t implementationID;

        // The maximum command payload length supported by the device.
        uint16_t maxPayloadLength;

        // The protocols supported by the device.
        std::vector<uint16_t> adminProtocols;
        std::vector<uint16_t> userProtocols;
    };



    // Devices do not send error messages for low level errors. (Higher level protocols
    //  built on PropCR may define their own error messages.) The only way a device can indicate
    //  lower level errors is by not sending an expected response. So the following errors will
    //  manifest as Error::Timeout:
    //  - incorrect baudrate,
    //  - incorrect address,
    //  - unsupported protocol number,
    //  - command payloads that are too large for the device,
    //  - spurious bytes received by the device,
    //  - framing errors, and
    //  - corrupted packets received by the device.
    enum class Error {
        None = 0,
        Cancelled,
        CallbackException,

        FailedToObtainPortAccess,  // i.e. failed to make the serial port controller active
        FailedToOpenPort,
        FailedToFlushBuffers,
        FailedToSetBytesize,
        FailedToSetParity,
        FailedToSetFlowcontrol,
        FailedToSetBaudrate,
        FailedToSetSerialTimeout,
        FailedToSetStopbits,
        FailedToSendBytes,
        FailedToReceiveBytes,

        Timeout,                    // see notes above
        CorruptResponsePayload,

        InvalidResponse,            // protocol level error
        FailedToSendBreak,
        UnhandledTransaction,
        UnhandledException
    };

    std::string strForError(Error error);

    enum class Transaction {
        None = 0,
        UserCommand,
        Ping,
        GetDeviceInfo,
        Break
    };



    std::string strForTransaction(Transaction transaction);


    struct HostTransactionStats {

        Error error;

        Transaction transaction;

        // Total time is from calling the public function to the transaction being completed.
        std::chrono::microseconds totalTime;

        // The response time is the amount of time it takes to receive and process a response.
        //  It starts at the time a command is sent for the first response, and at the time the
        //  previous response was received for subsequent responses.
        std::chrono::microseconds minResponseTime;
        std::chrono::microseconds maxResponseTime;
        std::chrono::microseconds avgResponseTime;

        size_t numIntermediateResponses;
        size_t numFinalResponses;
    };


    class PropCR;

    class StatusMonitor {
    public:

        // All of these callbacks are performed on a special
        //  worker thread created to perform the transaction. Importantly, this is not the main
        //  thread (this matters for some GUI APIs, for example). The worker thread exists for the
        //  lifetime of the host.
        // When a callback is executing the host is idle, so timely returns are important.
        //  User code may want to redispatch work to other threads if it depends
        //  on user interaction, networking, GUIs, etc., or is especially CPU intensive.

        // Do not call cancelAndWait or waitUntilFinished from these callbacks. Do not begin
        //  a new transaction except from the transactionDidEnd callback.

        // All transactions make these two callbacks. Specific transactions may have other
        //  callbacks that will be made in between these two callbacks. For example, a user command
        //  (initiated by calling sendCommand) may result in responseReceived callbacks.
        virtual void transactionWillBegin(PropCR& host, Transaction transaction, void* context) {} // exceptions cause the transaction to abort
        virtual void transactionDidEnd(PropCR& host, Transaction transaction, void* context,
                                       Error error, const std::string& errorDetails,
                                       const HostTransactionStats& stats) noexcept {}

        // For responses to user commands.
        virtual void responseReceived(PropCR& host,
                                      const std::vector<uint8_t>& payload,
                                      bool isFinal,
                                      void* context,
                                      std::chrono::milliseconds& timeout,   // changes apply to future responses within this transaction
                                      const HostTransactionStats& stats) {} // exceptions cause the transaction to abort

        // For the getDeviceInfo admin command.
        virtual void deviceInfoReceived(PropCR& host,
                                        DeviceInfo& deviceInfo,
                                        void* context,
                                        const HostTransactionStats& stats) noexcept {} // no exceptions allowed since the transaction is over
    };


#pragma mark - Packet Header Structs

    struct CommandHeader {
        uint8_t address;
        uint16_t protocol;
        bool isUserCommand;
        bool muteResponse;
        uint16_t payloadLength;
        uint8_t token;
    };

    struct ResponseHeader {
        bool isFinal;
        uint16_t payloadLength;
        uint8_t token;
    };

    
}

#endif /* PropCRDefs_hpp */
