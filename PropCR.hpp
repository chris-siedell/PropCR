//
//  PropCR.hpp
//  Final Sprint
//
//  Created by admin on 5/14/17.
//  Copyright © 2017 Chris Siedell. All rights reserved.
//

#ifndef PropCR_hpp
#define PropCR_hpp

#include <condition_variable>
#include <thread>
#include <mutex>
#include <atomic>


#include "HSerialController.hpp"

#include "PropCRDefs.hpp"

#include "SimpleChrono.hpp"


namespace propcr {



#pragma mark - HostBase

    class PropCR : public hserial::HSerialController {


    public:

        PropCR(hserial::HSerialPort port);
        PropCR(const std::string& deviceName);

        virtual ~PropCR();

        PropCR() = delete;
        PropCR(const PropCR&) = delete;
        PropCR& operator=(const PropCR&) = delete;
        PropCR(PropCR&&) = delete;
        PropCR& operator=(PropCR&&) = delete;

        // Returns "PropCR".
        std::string getControllerType() const;


#pragma mark - Settings

        // Default: 115200 bps
        uint32_t getBaudrate();
        void setBaudrate(uint32_t baudrate);

        // Default: serial::stopbits_one
        serial::stopbits_t getStopbits();
        void setStopbits(serial::stopbits_t stopbits);

        // This is the response timeout.
        // The timeout countdown for the first response starts when the command has been sent over
        //  the wire (the drain time, which is estimated). It resets after each response if
        //  there are intermediate responses. It does not take into consideration the amount of
        //  time that it takes for the response to be transmitted. A reasonable transaction timeout
        //  at 3 Mbps may be unreasonable at 9600 bps.
        // The timeout does not apply to broadcast commands, or if responses have been muted. In
        //  these cases the transaction is over as soon as the command has been transmitted.
        // See also: the timeout argument of HostMonitor::responseReceived.
        // Default: 250 ms
        simple::Milliseconds getTimeout();
        void setTimeout(simple::Milliseconds timeout);

        // May be NULL.
        // Default: NULL
        StatusMonitor* getStatusMonitor();
        void setStatusMonitor(StatusMonitor* monitor);


#pragma mark - Transactions: User Commands

        // This function sends a user command. This is the basis for protocols built using Crow.
        // The payload is copied before the function returns. It is not modified.
        // A specific device has an address from 1 to 31. Value 0 is the broadcast address -- all
        //  capable and listening devices receive the command, but they can not respond to it.
        // The provided protocol number must be supported by the device. If it is not then the
        //  device will silently discard the command.
        // Note that protocol 0 is a special value -- using it reduces the packet's header from 8
        //  bytes to 6 bytes. The device must still be programmed to listen for protocol 0 commands.
        // payload is limited to 2047 total bytes by the Crow serial specification. A device
        //  implementation may impose a lower limit. If the payload exceeds the device
        //  limit then no response will be received and the transaction will timeout (assuming that
        //  muteResponse is false).
        // If muteResponse is true for a non-broadcast address then the host considers the
        //  transaction to be successfully finished as soon as the packet has been transmitted. The
        //  receiving device will not send a response in this case.
        // muteResponse must be true for broadcast commands.
        // Responses to this command are obtained using the
        //  StatusMonitor::responseReceived callback.
        void sendCommand(uint8_t address, uint16_t protocol, std::vector<uint8_t>& payload, bool muteResponse = false, void* context = NULL);


#pragma mark - Transactions: Universal Admin Commands

        // Universal admin commands are defined by admin protocol 0 (the only reserved protocol).
        //  All Crow device implementation must support these commands.

        // Instructs the device to reply as quickly as possible.
        // address must not be the broadcast address (0).
        void ping(uint8_t address, void* context = NULL);

        // Obtains the essential information all Crow implementations must report.
        // Information is reported in the HostMonitor::deviceInfoReceived callback.
        // address must not be the broadcast address (0).
        void getDeviceInfo(uint8_t address, void* context = NULL);


#pragma mark - Other Transactions

        // Sending a break condition is treated as a transaction (so the callbacks will be
        //  called). It can not be cancelled.

        void sendBreak(int duration, void* context = NULL);


#pragma mark - Transaction Control

        bool isBusy() const;
        void waitUntilFinished(const simple::Milliseconds& timeout = simple::Milliseconds(0));
        void cancel();
        void cancelAndWait(const simple::Milliseconds& timeout = simple::Milliseconds(0));


#pragma mark - Serial Access Control

        // These functions are exposed to support allowing users to work with the control lines
        //  before initiating a transaction. They aren't required otherwise -- the controller
        //  automatically makes itself active to perform a transaction.
        // Attempting to make the controller inactive during a transaction will fail. Use cancel()
        //  or cancelAndWait() to stop a transaction. Alternatively, one can throw an exception
        //  from some monitor callbacks to abort a transaction.

        using HSerialController::isActive;
        using HSerialController::makeActive;
        using HSerialController::makeInactive;
        using HSerialController::removeFromAccess;


#pragma mark - Serial Port Control Line Functions

        // This host controller does not use control lines so it exposes them for the benefit of
        //  users. These can be used for out-of-band communication. One weakness of the PropCR
        //  protocol is that transactions are purely host initiated. An input control line could
        //  be used to signal to the host that the device wishes to communicate. For example,
        //  the RI line could be used to indicate that a sensor has changed, and then the host
        //  could then issue a command to get the sensor value. The alternative is polling.

        using HSerialController::setRTS;
        using HSerialController::setDTR;
        using HSerialController::waitForChange; // careful with this one in MT environment
        using HSerialController::getCTS;
        using HSerialController::getDSR;
        using HSerialController::getRI;
        using HSerialController::getCD;


    protected:

#pragma mark - [Internal] Transaction Lifecycle

        // Note: internal functions beginning with "t_" are meant to be used only on the
        //  transaction thread. These should throw only TransactionError exceptions, recasting if
        //  necessary. Throwing exceptions from such functions causes the transaction to abort.
        // Rule of thumb: t_ functions should be called only from t_performTransaction or subcalls.

        // This function is called by the base implementation from the transaction thread when there
        //  is an transaction to be performed. It should not be called at any other time.
        // If a derived class's implementation does not recognize the transaction then it is
        //  expected to invoke the parent's implementation.
        // It should throw only TransactionError.
        virtual void t_performTransaction(Transaction transaction);


#pragma mark - [Internal] Transaction Settings (getter/setters)

        // When a transaction starts the settings are locked in to the current values. Future
        //  changes to the settings using the public setters (e.g. setBaudrate) will not affect
        //  a transaction in progress. Internally, some of the transaction's settings may be
        //  changed using these functions.
        // These functions must be called on the transaction thread only (from t_performTransaction
        //  subcalls). This is not checked.

        uint32_t t_getBaudrate();
        void t_setBaudrate(uint32_t baudrate);

        serial::stopbits_t t_getStopbits();
        void t_setStopbits(serial::stopbits_t stopbits);

        simple::Milliseconds t_getTimeout();
        void t_setTimeout(simple::Milliseconds timeout);

        // monitor is read-only during a transaction.
        StatusMonitor* t_getMonitor();

        // context is read-only during a transaction.
        void* t_getContext();


#pragma mark - [Internal] Transaction Utilities

        // This function makes the controller active, makes sure the port is open, and then
        //  applies the settings to the port.
        void t_initializePort();

        // Throws TransactionError with Error::Cancelled if the transaction has been cancelled.
        void t_throwIfCancelled();

        // Sends bytes over the serial port. Either succeeds or throws TransactionError.
        // Returns the drain time (estimated based on the assumption that transmission begins
        //  immediately and continues without pause). Do not call t_sendBytes while data is still
        //  being transmitted if the drain time is important. Either flush the buffer or wait until
        //  previous sends are complete in that case.
        simple::SteadyTimePoint t_sendBytes(const std::vector<uint8_t>& bytes);

        // Reads the requested number of bytes from the port, waiting until timeoutTime.
        // Returns the time at the last serial port read.
        // If timeoutTime is reached then the function throws TransactionError with Error::Timeout.
        simple::SteadyTimePoint t_receiveBytes(uint8_t* bytes, size_t totalToReceive, simple::SteadyTimePoint& timeoutTime, const char* description, const char* description2);

        // Receives bytes until a valid response packet is obtained.
        // This function either succeeds or throws. It returns the time at which the packet was
        //  finally received.
        // If there's the possibility of a lot of spurious bytes being received then it would
        //  probably be advisable to flush the input buffer just before sending the command.
        // It uses t_receiveBytes so some of the comments there apply here.
        simple::SteadyTimePoint t_receiveResponse(ResponseHeader& header, uint8_t expectedToken, std::vector<uint8_t>& payload, simple::SteadyTimePoint& timeoutTime, const char* description);

        // Waits until the given time, checking periodically for cancellation.
        void t_waitUntil(const simple::SteadyTimePoint& waitTime);

        // Flushes the port's sending and receiving buffers (serial::Serial does not support
        //  separate methods on all platforms).
        // It also increments the spurious bytes counter by the number of bytes reported as
        //  available for reading before the flush.
        // Catches exceptions and recasts them as TransactionError.
        void t_flushBuffers();

        // The time it will take to send the given number of bytes at the current settings,
        //  assuming uninterrupted transmission.
        simple::Microseconds t_transitDuration(size_t numBytes);

        // Used by t_sendBytes. The responsiveness timeout is different than the response timeout.
        //  The idea behind the responsiveness timeout is that if the port is not accepting
        //  data at a rate consistent with the baudrate then something is wrong (allowing for
        //  some margin).
        simple::Milliseconds t_responsivenessTimeout(simple::Microseconds transitDuration);


#pragma mark - [Internal] HSerialController Transition Callbacks

        // Refuses if busy.
        virtual void willMakeInactive();


#pragma mark - [Internal] Constants

        // The host attempts to check for cancellation at intervals not exceeding this amount.
        const simple::Milliseconds CancellationCheckInterval {100};

        // See t_responsivenessTimeout for an explanation of these variables.
        const simple::Milliseconds MinResponsivenessTimeoutDuration {1000};
        const float ResponsivenessTimeoutMultiplier = 1.5f;


    private:


#pragma mark - [Private] Miscellaneous

        // Called when t_baudrate or t_stopbits changes.
        void t_recalculateMicrosecondsPerByte();

        // Used in t_transitDuration.
        float t_microsecondsPerByte;


#pragma mark - [Private] Transaction Control

        void waitUntilFinishedInternal(std::unique_lock<std::mutex>& lock, const simple::Milliseconds& timeout);


#pragma mark - [Private] Transaction Lifecycle

        void transactionThreadEntry();

        // These helper functions bookend the performance of a transaction.
        void t_transactionWillBegin(Transaction transaction);
        void t_transactionDidEnd(Error errorCode, const std::string& errorDetails);
        void t_clearTransaction();


#pragma mark - [Private] Base's Transactions

        void t_performUserCommand();
        void t_performPing();
        void t_performGetDeviceInfo();
        void t_performBreak();


#pragma mark - [Private] Settings Variables

        std::atomic<uint32_t> s_baudrate {115200};
        std::atomic<serial::stopbits_t> s_stopbits {serial::stopbits_one};
        std::atomic<simple::Milliseconds> s_timeout {simple::Milliseconds(2500)}; // todo
        std::atomic<StatusMonitor*> s_monitor {NULL};


#pragma mark - [Private] Transaction Setting Variables

        // These are the host settings used during a transaction. These are initialized to the
        //  controller's settings at the beginning of the transaction. Subsequent changes using
        //  the public setters do not affect these values.

        uint32_t t_baudrate;
        serial::stopbits_t t_stopbits;
        simple::Milliseconds t_timeout;
        StatusMonitor* t_monitor;
        void* t_context;


#pragma mark - [Private] Transaction Variables

        // t_mutex is used for
        //  - HostTransactionInitiator (it is locked between creation and startTransaction),
        //  - t_transaction (w),
        //  - t_isCancelled (w),
        //  - t_counter (r+w),
        //  - t_finishedCondition,
        //  - t_wakeupCondition
        std::mutex t_mutex;

        // t_transaction identifies the transaction currently being performed. It combines the
        //  functionality of _isBusy and currAction in AsyncPropLoader, which this host controller
        //  is based on.
        // A non-None value indicates that the controller is busy, and vice-versa.
        //  None -> non-None associated with t_wakeCondition
        //  non-None -> None associated with t_finishedCondition
        std::atomic<Transaction> t_transaction {Transaction::None};

        // Flag used to signal to the transaction thread that the transaction is cancelled.
        std::atomic_bool t_isCancelled;

        // This flag is used to join the transaction thread on destruction.
        bool t_continueThread = true;

        // The transaction counter is used to identify transactions for the waiting functions.
        uint32_t t_counter;

        // The transaction thread. Exists for the lifetime of the controller.
        std::thread t_thread;

        // The serial::Timeout struct used with the port.
        serial::Timeout t_serialTimeout;

        // Wakes up the transaction thread, either to perform a transaction or to exit.
        std::condition_variable t_wakeupCondition;

        // Used to signal that a transaction is finished. It unblocks waiting threads.
        std::condition_variable t_finishedCondition;

        // This struct holds information about the transaction, such as the time taken.
        HostTransactionStats t_stats;
        HostTransactionStats t_stats_copy; // used for DidEnd callback

        // Token counter. Used for matching responses to commands.
        uint8_t t_nextToken = 0;


#pragma mark - [Private] Transaction Scratch Variables
        
        // These variables are used in the performance of the base class's supported
        //  transactions (e.g. ping). They are used either 1) under the protection of a
        //  HostTransactionInitiator object, to pass along arguments from the initiating
        //  function call, or 2) on the transaction thread (i.e. in t_performTransaction subcalls).
        
        CommandHeader t_command;
        ResponseHeader t_response;
        std::vector<uint8_t> t_buffer;
        int t_breakDuration;


#pragma mark - misc

        class TransactionInitiator;

        std::atomic_uint spuriousBytesCounter;


        std::exception_ptr rxThreadException = nullptr;
        

        void receiveThreadEntry(simple::SteadyTimePoint timeoutTime);

        std::atomic_bool continueReceiveThread;

        static const size_t rxBufferSize = 100000;
        uint8_t rxBuffer[rxBufferSize];

        size_t rxStart = 0;
        size_t rxEnd = 0;
        size_t rxLength = 0;
    };
    
}

#endif /* PropCR_hpp */
