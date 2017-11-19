//
//  PropCR.cpp
//  Final Sprint
//
//  Created by admin on 5/14/17.
//  Copyright © 2017 Chris Siedell. All rights reserved.
//

#include "PropCR.hpp"

#include "PropCRInternal.hpp"

#include <iostream>
#include <sstream>
#include <iomanip>
#include <cassert>

#include "HSerialExceptions.hpp"

#include "SimpleErrors.hpp"




using simple::Milliseconds;
using simple::Microseconds;
using simple::SteadyTimePoint;
using simple::SteadyClock;


// todo: don't flush


using std::cout;


namespace propcr {

    static std::vector<uint8_t> EmptyPayload;


#pragma mark - PropCR

    PropCR::PropCR(hserial::HSerialPort port) : HSerialController(port) {
        // Designated constructor.

        t_thread = std::thread(&PropCR::transactionThreadEntry, this);

        // The read_timeout_constant will be set to be the minimum of the time remaining for the
        //  transaction and the CancellationCheckInterval.
        // The other fields of the Timeout struct don't change.
        t_serialTimeout.inter_byte_timeout = serial::Timeout::max(); // disabled
        t_serialTimeout.read_timeout_multiplier = 0;
        t_serialTimeout.write_timeout_constant = static_cast<uint32_t>(CancellationCheckInterval.count());
        t_serialTimeout.write_timeout_multiplier = 0;

        // Largest valid packet is 4166 bytes. The extra
        //  two bytes are for the Fletcher 16 sums of the last chunk of a maximal packet (see
        //  t_receiveResponse).
        t_buffer.reserve(4168);
    }

    PropCR::PropCR(const std::string& deviceName) : PropCR(hserial::HSerialPort(deviceName)) {}

    PropCR::~PropCR() {

        //cout << "PropCR destructor called\n";

        cancelAndWait(simple::Milliseconds(0));
        removeFromAccess();

        // Collect transaction thread.
        std::unique_lock<std::mutex> lock(t_mutex);
        t_continueThread = false;
        lock.unlock();
        t_wakeupCondition.notify_all();
        t_thread.join();

        //cout << "PropCR destructor is finished\n";
    }

    std::string PropCR::getControllerType() const {
        return "PropCR";
    }


#pragma mark - Settings

    uint32_t PropCR::getBaudrate() {
        return s_baudrate.load();
    }

    void PropCR::setBaudrate(uint32_t baudrate) {
        if (baudrate == 0) {
            throw std::invalid_argument("Baudrate cannot be zero.");
        }
        s_baudrate.store(baudrate);
    }

    serial::stopbits_t PropCR::getStopbits() {
        return s_stopbits.load();
    }

    void PropCR::setStopbits(serial::stopbits_t stopbits) {
        s_stopbits.store(stopbits);
    }

    simple::Milliseconds PropCR::getTimeout() {
        return s_timeout.load();
    }

    void PropCR::setTimeout(simple::Milliseconds timeout) {
        if (timeout.count() <= 0) {
            throw std::invalid_argument("Timeout must be at least 1 ms.");
        }
        s_timeout.store(timeout);
    }

    StatusMonitor* PropCR::getStatusMonitor() {
        return s_monitor.load();
    }

    void PropCR::setStatusMonitor(StatusMonitor* monitor) {
        s_monitor.store(monitor);
    }


#pragma mark - Transactions: User Commands

    void PropCR::sendCommand(uint8_t address, uint16_t protocol, std::vector<uint8_t>& payload, bool muteResponse, void* context) {

        TransactionInitiator initiator(*this);

        // Do setup between initiator creation and startTransaction call.

        t_command.address = address;
        t_command.protocol = protocol;
        t_command.isUserCommand = true;
        t_command.muteResponse = muteResponse;
        t_command.payloadLength = payload.size();
        t_command.token = t_nextToken++;

        // createCommandPacket throws if the arguments are invalid. It also copies the payload
        //  as it creates the packet.
        createCommandPacket(t_command, payload, t_buffer);

        initiator.startTransaction(Transaction::UserCommand, context);
    }


#pragma mark - Transactions: Universal Admin Commands

    void PropCR::ping(uint8_t address, void* context) {

        throwIfAddressIsInvalid(address);
        throwIfBroadcastAddress(address);

        TransactionInitiator initiator(*this);

        // Do setup between initiator creation and startTransaction call.

        t_command.address = address;
        t_command.protocol = 0;
        t_command.isUserCommand = false;
        t_command.muteResponse = false;
        t_command.payloadLength = 0;
        t_command.token = t_nextToken++;

        createCommandPacket(t_command, EmptyPayload, t_buffer);

        initiator.startTransaction(Transaction::Ping, context);
    }

    void PropCR::getDeviceInfo(uint8_t address, void* context) {

        throwIfAddressIsInvalid(address);
        throwIfBroadcastAddress(address);

        TransactionInitiator initiator(*this);

        // Do setup between initiator creation and startTransaction call.

        // getDeviceInfo payload is a single NUL byte.
        
        t_command.address = address;
        t_command.protocol = 0;
        t_command.isUserCommand = false;
        t_command.muteResponse = false;
        t_command.payloadLength = 1;
        t_command.token = t_nextToken++;

        std::vector<uint8_t> payload;
        payload.push_back(0);

        createCommandPacket(t_command, payload, t_buffer);

        initiator.startTransaction(Transaction::GetDeviceInfo, context);
    }

    void PropCR::sendBreak(int duration, void* context) {

        TransactionInitiator initiator(*this);

        t_breakDuration = duration;

        initiator.startTransaction(Transaction::Break, context);
    }


#pragma mark - Transaction Control

    bool PropCR::isBusy() const {
        // Based on AsyncPropLoader::isBusy.
        // Note that a non-None transaction is used to inidicate that the controller is busy,
        //  instead of a dedicated flag as in AsyncPropLoader.
        return t_transaction.load() != Transaction::None;
    }

    void PropCR::cancel() {
        // Based on AsyncPropLoader::cancel.
        std::lock_guard<std::mutex> lock(t_mutex);
        t_isCancelled.store(true);
    }

    void PropCR::cancelAndWait(const simple::Milliseconds& timeout) {
        // Based on AsyncPropLoader::cancelAndWait.
        std::unique_lock<std::mutex> lock(t_mutex);
        if (t_transaction.load() != Transaction::None) return;
        t_isCancelled.store(true);
        waitUntilFinishedInternal(lock, timeout);
    }

    void PropCR::waitUntilFinished(const simple::Milliseconds& timeout) {
        // Based on AsyncPropLoader::waitUntilFinished.
        std::unique_lock<std::mutex> lock(t_mutex);
        waitUntilFinishedInternal(lock, timeout);
    }

    void PropCR::waitUntilFinishedInternal(std::unique_lock<std::mutex>& lock, const simple::Milliseconds& timeout) {
        // Based on AsyncPropLoader::waitUntilFinishedInternal.
        uint32_t originalCounter = t_counter;
        auto predicate = [this, originalCounter]() {
            if (t_transaction.load() != Transaction::None) {
                return originalCounter != t_counter;
            } else {
                return true;
            }
        };
        if (timeout.count() <= 0) {
            t_finishedCondition.wait(lock, predicate);
        } else {
            bool success = t_finishedCondition.wait_for(lock, timeout, predicate);
            if (!success) {
                throw simple::TimeoutError("Timeout occured while waiting for the transaction to finish.");
            }
        }
    }


#pragma mark - [Internal] Transaction Lifecycle

    void PropCR::t_performTransaction(Transaction transaction) {
        // This is the base class implementation.
        // Derived classes that define their own transactions should call their parent class's
        //  implementation if they don't handle the transaction.
        switch (transaction) {
            case Transaction::UserCommand:
                t_performUserCommand();
                break;
            case Transaction::Ping:
                t_performPing();
                break;
            case Transaction::GetDeviceInfo:
                t_performGetDeviceInfo();
                break;
            case Transaction::Break:
                t_performBreak();
                break;
            default:
                std::stringstream ss;
                ss << "Transaction: " << strForTransaction(transaction) << ".";
                throw TransactionError(Error::UnhandledTransaction, ss.str());
        }
    }


#pragma mark - [Internal] Transaction Settings (getter/setters)

    uint32_t PropCR::t_getBaudrate() {
        return t_baudrate;
    }

    void PropCR::t_setBaudrate(uint32_t baudrate) {
        t_baudrate = baudrate;
        t_recalculateMicrosecondsPerByte();
        try {
            HSerialController::setBaudrate(baudrate, true);
        } catch (const std::exception& e) {
            throw TransactionError(Error::FailedToSetBaudrate, e.what());
        }
    }

    serial::stopbits_t PropCR::t_getStopbits() {
        return t_stopbits;
    }

    void PropCR::t_setStopbits(serial::stopbits_t stopbits) {
        t_stopbits = stopbits;
        t_recalculateMicrosecondsPerByte();
        try {
            HSerialController::setStopbits(t_stopbits, true);
        } catch (const std::exception& e) {
            throw TransactionError(Error::FailedToSetStopbits, e.what());
        }
    }

    simple::Milliseconds PropCR::t_getTimeout() {
        return t_timeout;
    }

    void PropCR::t_setTimeout(simple::Milliseconds timeout) {
        // Note: this is the transaction timeout, not the timeout for the serial reads.
        // This value is used by t_receiveBytes to set the appropriate timeout for reads.
        t_timeout = timeout;
    }

    StatusMonitor* PropCR::t_getMonitor() {
        return t_monitor;
    }

    void* PropCR::t_getContext() {
        return t_context;
    }


#pragma mark - [Internal] Transaction Utilities

    void PropCR::t_initializePort() {

        try {
            makeActive();
        } catch (const std::exception& e) {
            if (!isActive()) {
                throw TransactionError(Error::FailedToObtainPortAccess, e.what());
            } else {
                // Since the controller is active keep going.
            }
        }

        try {
            ensureOpen();
        } catch (const std::exception& e) {
            throw TransactionError(Error::FailedToOpenPort, e.what());
        }

        // Apply the fixed port settings: bytesize, parity, and flowcontrol --
        //  but only if different, to avoid redundant reconfigurePort calls within Serial.

        try {
            setBytesize(serial::eightbits, true);
        } catch (const std::exception& e) {
            throw TransactionError(Error::FailedToSetBytesize, e.what());
        }

        try {
            setParity(serial::parity_none, true);
        } catch (const std::exception& e) {
            throw TransactionError(Error::FailedToSetParity, e.what());
        }

        try {
            setFlowcontrol(serial::flowcontrol_none, true);
        } catch (const std::exception& e) {
            throw TransactionError(Error::FailedToSetFlowcontrol, e.what());
        }

        // Set the serial timeout. t_receiveBytes will make further adjustments to
        //  read_timeout_constant as necessary.
        t_serialTimeout.read_timeout_constant = static_cast<uint32_t>(CancellationCheckInterval.count());
        try {
            HSerialController::setTimeout(t_serialTimeout, true);
        } catch (const std::exception& e) {
            throw TransactionError(Error::FailedToSetSerialTimeout, e.what());
        }

        t_setBaudrate(t_baudrate);
        t_setStopbits(t_stopbits);
        t_setTimeout(t_timeout); // the transaction timeout, not the serial timeout
    }

    void PropCR::t_throwIfCancelled() {
        if (t_isCancelled.load()) {
            std::stringstream ss;
            ss << "todo: indicate what was happening";
            throw TransactionError(Error::Cancelled, ss.str());
        }
    }

    SteadyTimePoint PropCR::t_sendBytes(const std::vector<uint8_t>& bytes) {
        // Based on AsyncPropLoader::sendBytes.

        size_t totalToSend = bytes.size();
        const uint8_t* data = bytes.data();

        Microseconds transitDuration = t_transitDuration(totalToSend);

        SteadyTimePoint now = SteadyClock::now();
        SteadyTimePoint drainTime = now + transitDuration; // assumes immediate start and uninterrupted transmission
        SteadyTimePoint responsivenessTimeoutTime = now + t_responsivenessTimeout(transitDuration);

        size_t numSent = 0;

        while (true) {

            t_throwIfCancelled();

            try {
                numSent += write(&data[numSent], totalToSend - numSent);
            } catch (const std::exception& e) {
                std::stringstream ss;
                ss << "Writing to the port failed. Error: " << e.what();
                throw TransactionError(Error::FailedToSendBytes, ss.str());
            }

            if (numSent >= totalToSend) break;

            if (SteadyClock::now() > responsivenessTimeoutTime) {
                throw TransactionError(Error::FailedToSendBytes, "The port was unresponsive.");
            }
        }

        return drainTime;
    }

    SteadyTimePoint PropCR::t_receiveBytes(uint8_t* bytes, size_t totalToReceive, SteadyTimePoint& timeoutTime, const char* description, const char* description2) {

        uint32_t cancellationInterval = static_cast<uint32_t>(CancellationCheckInterval.count());

        SteadyTimePoint receiveTime = SteadyClock::now();

        size_t numReceived = 0;

        //cout << "t_receiveBytes called to received " << totalToReceive << " bytes for " << description << description2 << "\n";

        while (true) {

            t_throwIfCancelled();

            // Check for transaction timeout.
            Milliseconds remaining = std::chrono::duration_cast<Milliseconds>(timeoutTime - receiveTime);
            if (remaining.count() < 1) {
                std::stringstream ss;
                ss << "Transaction timeout occurred while receiving " << description
                    << description2 << ". " << numReceived << " of " << totalToReceive << " expected bytes received.";
                throw TransactionError(Error::Timeout, ss.str());
            }

            // Use the minimum of the cancellation interval or the remaining time until timeoutTime
            //  as the timeout for the next read call.
            uint32_t timeout = std::min(cancellationInterval, static_cast<uint32_t>(remaining.count()));
            if (t_serialTimeout.read_timeout_constant != timeout) {
                t_serialTimeout.read_timeout_constant = timeout;
                try {
                    HSerialController::setTimeout(t_serialTimeout);
                } catch (const std::exception& e) {
                    throw TransactionError(Error::FailedToSetSerialTimeout, e.what());
                }
            }

            try {
                //cout << "will attempt to read " << (totalToReceive - numReceived) << " bytes\n";
                size_t tmp = read(&bytes[numReceived], totalToReceive - numReceived);
                numReceived += tmp;
                //cout << "received " << tmp << " bytes\n";
            } catch (const std::exception& e) {
                std::stringstream ss;
                ss << "Reading from the port failed while receiving " << description
                    << description2 << ". Error: " << e.what();
                throw TransactionError(Error::FailedToReceiveBytes, ss.str());
            }

            receiveTime = SteadyClock::now();

            if (numReceived >= totalToReceive) break;
        }

        return receiveTime;
    }

    std::string stringForBytes(const std::vector<uint8_t>& bytes) {
        if (bytes.size() > 0) {
            std::stringstream ss;
            ss << std::setw(2) << std::uppercase << std::hex;
            for (uint8_t value : bytes) {
                ss << static_cast<unsigned int>(value) << " ";
            }
            return ss.str();
        } else {
            return "(empty)";
        }
    }

    SteadyTimePoint PropCR::t_receiveResponse(ResponseHeader& header, uint8_t expectedToken, std::vector<uint8_t>& payload, SteadyTimePoint& timeoutTime, const char* description) {

        //cout << "will attempt to receive " << description << "\n";
        //cout << " bytes available at start: " << available() << "\n";
        
        // First, get the header. Read only as many bytes at a time as
        //  necessary to complete the header. Once the header is parsed we'll know how many bytes
        //  are in the body.

        // responseTime is the return value. It will be the time returned by the
        //  last t_receiveBytes call.
        SteadyTimePoint responseTime;

        // todo: consider a different parsing strategy; this one seems inefficient if significant
        //  spurious are received (includes stale responses for timed-out transactions)
        // ...especially if a single wire is used, so that the host sees its owns transmissions

        // r (remaining) is the number of bytes that need to be received to complete a possible
        //  response header. A response header is always 5 bytes long. See
        //  parseResponseHeaderAndGetParams for details.
        unsigned int r = 5;
        uint8_t h[5];
        while (r > 0) {

            responseTime = t_receiveBytes(&h[5-r], r, timeoutTime, description, " header");

            bool success = parseResponseHeaderAndGetParams(h, header);
            if (success) {
                // A viable header was found. Does it have the correct token?
                if (header.token == expectedToken) {
                    break;
                }
                // If the tokens don't match just keep parsing as if the potential header was just
                //  random data.
            }
            
            for (r = 1; r < 5; ++r) {
                if ((h[r] & 0xE8) == 0x80) {
                    // A byte has been found with the correct reserved bits pattern for RH0.

                    // Shift potentially valid header bytes down.
                    for (unsigned int i = 0; i < 5 - r; ++i) {
                        h[i] = h[r + i];
                    }

                    break;
                }
            }

            // Previous bytes are spurious.
            spuriousBytesCounter.fetch_add(r);
        }

        //cout << " header was parsed, payload length: " << header.payloadLength << "\n";

        // A valid header with the expected token was parsed. Now get the body.

        /*
         The Response Body
         =================

         The response body has the same format as the command body, except the last two bytes
         of each chunk are the Fletcher 16 result for the chunk's 1-128 payload bytes (and not
         zeroing check bytes, as in the command body). The upper (second) sum is received before
         the lower (first) sum. The device initializes the Fletcher 16 sums to zero before
         processing each chunk.
         */

        // Quick exit for empty body.
        if (header.payloadLength == 0) {
            payload.clear();
            return responseTime;
        }

        // If the previous five bytes describe a valid header then just assume the remaining
        //  bytes are the body. That is, if error detection fails on a payload chunk then
        //  we won't go back and look for another potential header.
        // todo: consider changing this.

        // To avoid an extra copy the body's chunks are read directly into the payload vector.
        //  This is why there's an additional +2 in the payload size, to allow for the last chunk's
        //  Fletcher 16 bytes. When we're done we will resize the vector to its correct length.

        payload.resize(header.payloadLength + 2);
        uint8_t* data = payload.data();

        size_t numChunks = header.payloadLength/128;
        if (header.payloadLength%128 != 0) numChunks += 1;

        size_t bodySize = header.payloadLength + 2*numChunks;

        // chunkCount is used in error message.
        size_t chunkCount = 1;

        size_t index = 0;
        size_t remaining = bodySize;
        while (remaining > 0) {

            // Read the body by chunks.
            // For a steady 3 Mbps stream this amounts to ~2300 receiveBytes calls per second for
            //  payload chunks.
            // todo: see if this is acceptable

            // Receive a chunk directly in payload buffer.
            size_t chunkSize = std::min<size_t>(remaining, 130);
            size_t dataSize = chunkSize - 2;
            responseTime = t_receiveBytes(&data[index], chunkSize, timeoutTime, description, " payload");

            // Verify checksum.
            uint8_t fLower, fUpper;
            getFletcher16(&data[index], dataSize, fLower, fUpper);
            index += dataSize;
            if (unequalFletcher16Sums(fLower, fUpper, data[index+1], data[index])) {
                //cout << "fLower: " << int(fLower) << ", fUpper: " << int(fUpper) << ", data[index+1]: " << int(data[index+1]) << ", data[index]: " << int(data[index]) << "\n";

                //cout << "data (" << payload.size() << "): " << stringForBytes(payload) << "\n";




                std::stringstream ss;
                ss << "Chunk " << chunkCount << " of " << numChunks
                    << " failed checksum test while receiving " << description << ".";
                throw TransactionError(Error::CorruptResponsePayload, ss.str());
            }

            // Next loop prep.
            remaining -= chunkSize;
            chunkCount += 1;
        }

        // Truncate the last chunk's check bytes.
        payload.resize(header.payloadLength);

        return responseTime;
    }

    void PropCR::t_waitUntil(const SteadyTimePoint& waitTime) {
        // todo: update from AsyncPropLoader
        while (SteadyClock::now() < waitTime) {
            t_throwIfCancelled();
            std::this_thread::sleep_for(CancellationCheckInterval);
        }
    }

    void PropCR::t_flushBuffers() {
        try {
            spuriousBytesCounter.fetch_add(static_cast<unsigned int>(available()));
            flush();
        } catch (const std::exception& e) {
            throw TransactionError(Error::FailedToFlushBuffers, e.what());
        }
    }

    Microseconds PropCR::t_transitDuration(size_t numBytes) {
        long long n = numBytes * t_microsecondsPerByte;
        if (n < 1) n = 1;
        return Microseconds(n);
    }

    Milliseconds PropCR::t_responsivenessTimeout(Microseconds transitDuration) {
        return Milliseconds(std::max(static_cast<long long>(ResponsivenessTimeoutMultiplier * transitDuration.count() / 1000.0f),
                                     MinResponsivenessTimeoutDuration.count()));
    }


#pragma mark - [Internal] HSerialController Transition Callbacks

    void PropCR::willMakeInactive() {

        std::lock_guard<std::mutex> lock(t_mutex);

        if (isBusy()) {
            throw hserial::ControllerRefuses(*this, "The controller is busy.");
        }

        // Use the default implementation to fulfill obligations.
        HSerialController::willMakeInactive();

        // We don't need to worry about a transaction starting between the return of this function
        //  and the actual active controller transition. (If we did then we would need to keep the
        //  mutex locked over the transition and unlock it in didCancelMakeInactive and
        //  didMakeInactive.)
        // The controller doesn't need to be active to start a transaction -- it just needs to be
        //  active when it uses the port. When makeActive is called on the transaction thread
        //  (in t_performTransaction or subcalls) it either makes the controller active or throws.
        //  If it succeeds in making the controller active the controller will stay active
        //  until the transaction is cleared (because of the isBusy check above).
        // This is why it is good practice to call makeActive on the transaction thread before
        //  doing any work with the port (redundant calls are OK). Making the port active
        //  is the first thing done in t_initializePort.
    }


#pragma mark - [Private] Miscellaneous

    void PropCR::t_recalculateMicrosecondsPerByte() {
        t_microsecondsPerByte = 1000000.0f / t_baudrate;
        if (t_stopbits == serial::stopbits_two) {
            t_microsecondsPerByte *= 11.0f;
        } else if (t_stopbits == serial::stopbits_one_point_five) {
            t_microsecondsPerByte *= 10.5f;
        } else {
            t_microsecondsPerByte *= 10.0f;
        }
    }


#pragma mark - [Private] Transaction Lifecycle

    void PropCR::transactionThreadEntry() {
        //cout << "transaction thread starting\n";
        std::unique_lock<std::mutex> lock(t_mutex);

        auto predicate = [this]() {
            return !t_continueThread || t_transaction.load() != Transaction::None;
        };

        while (t_continueThread) {
                        //cout << "transaction thread will wait\n";

            t_wakeupCondition.wait(lock, predicate);
                        //cout << "transaction thread is woke\n";


            while (t_continueThread && t_transaction.load() != Transaction::None) {


                Transaction transaction = t_transaction.load();
                //cout << "transaction thread will call performTransaction for " << strForTransaction(transaction) << "\n";

                // Release lock during most of transaction.
                lock.unlock();

                try {
                    t_transactionWillBegin(transaction);
                    t_performTransaction(transaction);
                    t_transactionDidEnd(Error::None, "");
                } catch (const TransactionError& e) {
                    t_transactionDidEnd(e.error, e.what());
                } catch (const std::exception& e) {
                    std::stringstream ss;
                    ss << "Error: " << e.what();
                    t_transactionDidEnd(Error::UnhandledException, ss.str());
                } catch (...) {
                    t_transactionDidEnd(Error::UnhandledException, "...");
                }

                // Reacquire lock for wait.
                lock.lock();
            }

        }

        //cout << "transaction thread stopping\n";
    }

    void PropCR::t_transactionWillBegin(Transaction transaction) {
        // Based on AsyncPropLoader::actionWillBegin.
        // callbackOrderEnforcingMutex (in AsyncPropLoader) is absent. It is not
        //  necessary in this controller since there's one thread to perform all transactions. In
        //  AsyncPropLoader each action spawns its own thread, requiring coordination between them.
        if (t_monitor) {
            try {
                t_monitor->transactionWillBegin(*this, transaction, t_context);
            } catch (const TransactionError& e) {
                throw;
            } catch (const std::exception& e) {
                std::stringstream ss;
                ss << "Error: " << e.what();
                throw TransactionError(Error::CallbackException, ss.str());
            } catch (...) {
                throw TransactionError(Error::CallbackException, "...");
            }
        }
    }

    void PropCR::t_transactionDidEnd(Error error, const std::string& errorDetails) {
        // Based on AsyncPropLoader::actionHasFinishedOK and ::actionHasFinishedWithError.

        // These t_* variables may change as soon as the transaction is cleared.
        StatusMonitor* monitor = t_monitor;
        Transaction transaction = t_transaction.load();
        void* context = t_context;
        t_stats_copy = t_stats;

        // Note: callbackOrderEnforcingMutex is used in AsyncPropLoader but not here. See
        //  comments in t_transactionWillBegin for explanation.

        // The transaction is cleared before calling the DidEnd callback. This allows chaining
        //  transactions.
        t_clearTransaction();

        if (monitor) {
            monitor->transactionDidEnd(*this, transaction, context, error, errorDetails, t_stats_copy); // noexcept
        }
    }

    void PropCR::t_clearTransaction() {
        // Based on AsyncPropLoader::endAction.

        std::unique_lock<std::mutex> lock(t_mutex);
        t_transaction.store(Transaction::None);
        lock.unlock();

        t_finishedCondition.notify_all();
    }


#pragma mark - [Private] Base's Transactions

    void PropCR::t_performUserCommand() {

        t_initializePort();

        // todo: test that the estimated drain time method won't result in previous muted command
        //  clipping (esp. with slow baudrates and large packets)
        t_flushBuffers();

        // Send the user command packet (prepared in sendCommand).
        SteadyTimePoint timeoutTime = t_sendBytes(t_buffer);

        if (t_command.muteResponse) {

            // Responses are muted, so simply wait until the drain time. (If we didn't and the
            //  baudrate is low enough it is possible that another transaction could clip off
            //  the end of the transmission when it flushes the buffers.)


            t_waitUntil(timeoutTime);

        } else {
            // Responses are allowed and expected if there are no low level errors.


            // the receiveThread was a test to see if another approach would support higher rates (partial success)
//            rxThreadException = nullptr;
//            std::thread receiveThread = std::thread(&PropCR::receiveThreadEntry, this, timeoutTime);
//            receiveThread.join();
//            if (rxThreadException) {
//                std::rethrow_exception(rxThreadException);
//            }


            Milliseconds timeout = t_timeout;

            do {
                timeoutTime += timeout; // calculated from command packet drain time or last response received time

                timeoutTime = t_receiveResponse(t_response, t_command.token, t_buffer, timeoutTime, "a user command response");

                Milliseconds updatedTimeout = timeout;

                if (t_monitor) {
                    // Exceptions thrown from the responseReceived callback abort the transaction.
                    try {
                        t_monitor->responseReceived(*this, t_buffer, t_response.isFinal, t_context, updatedTimeout, t_stats);
                    } catch (const TransactionError& e) {
                        throw;
                    } catch (const std::exception& e) {
                        std::stringstream ss;
                        ss << "Error: " << e.what();
                        throw TransactionError(Error::CallbackException, ss.str());
                    } catch (...) {
                        throw TransactionError(Error::CallbackException, "...");
                    }
                }

                // If the timeout from the callback is unreasonable then silently ignore it.
                if (updatedTimeout.count() >= 1) timeout = updatedTimeout;
                
            } while (!t_response.isFinal);
        }

        //cout << "rxLength: " << rxLength << "\n";


    }
    
    void PropCR::t_performPing() {

        t_initializePort();
        t_flushBuffers();

        SteadyTimePoint timeoutTime;

        //cout << "ping: ";
        for (uint8_t byte : t_buffer) {
            //cout << " " << int(byte);
        }
        //cout << "\n";
        
        timeoutTime = t_sendBytes(t_buffer);
        timeoutTime += t_timeout;
        
        t_receiveResponse(t_response, t_command.token, t_buffer, timeoutTime, "a ping response");
        
        if (!t_response.isFinal) {
            throw TransactionError(Error::InvalidResponse, "A ping response should be final.");
        }
        
        if (t_response.payloadLength != 0) {
            throw TransactionError(Error::InvalidResponse, "A ping response should have no payload.");
        }
    }
    
    void PropCR::t_performGetDeviceInfo() {
        
        t_initializePort();
        t_flushBuffers();

        SteadyTimePoint timeoutTime;
        
        timeoutTime = t_sendBytes(t_buffer);
        timeoutTime += t_timeout;
        
        t_receiveResponse(t_response, t_command.token, t_buffer, timeoutTime, "a getDeviceInfo response");

        DeviceInfo info;
        std::string failureReason;
        bool success = parseGetDeviceInfoResponse(t_response, t_buffer, info, failureReason);
        if (!success) {
            throw TransactionError(Error::InvalidResponse, failureReason);
        }

        if (t_monitor) {
            t_monitor->deviceInfoReceived(*this, info, t_context, t_stats); // noexcept
        }
    }

    void PropCR::t_performBreak() {
        t_initializePort();

        try {
            HSerialController::sendBreak(t_breakDuration);
        } catch (const std::exception& e) {
            throw TransactionError(Error::FailedToSendBreak, e.what());
        }
    }
    
    
#pragma mark - [Internal] Transaction Utilities
    
    
    
#pragma mark - HSerialController Transition Callbacks
    
    
    simple::Milliseconds t_getTimeout();
    void t_setTimeout(simple::Milliseconds timeout);
    


    enum class RxState {

        H0,
        H1,
        H2,
        P,
        Fu,
        Fl,
    };




    void parser(const uint8_t* bytes, size_t numBytes) {


        uint32_t fu = 0;
        uint32_t fl = 0;

        static RxState state = RxState::H0;
        uint8_t RH0 = 0, RH1 = 0;
        uint startOverIndex = 0;

        uint16_t payloadLength = 0;
        bool isFinal = false;
        uint8_t token = 0;

        uint chunkRemaining = 0;
        uint payloadRemaining = 0;

        int packetNum = 0;


        int badFu = 0;
        int badFl = 0;
        int badH0 = 0;

        uint i = 0;
        while (i < numBytes) {

            switch (state) {
                case RxState::P:
                    fu += fl += bytes[i];
                    chunkRemaining -= 1;
                    if (chunkRemaining == 0) {
                        state = RxState::Fu;
                    }
                    i += 1;
                    break;
                case RxState::Fu:
                    if ((fu%255) == (bytes[i]%255)) {
                        state = RxState::Fl;
                        i += 1;
                    } else {
                        badFu += 1;
                        state = RxState::H0;
                        i = startOverIndex;
                    }
                    break;
                case RxState::Fl:
                    if ((fl%255) == (bytes[i]%255)) {
                        if (payloadRemaining > 0) {
                            chunkRemaining = (payloadRemaining > 128) ? 128 : payloadRemaining;
                            payloadRemaining -= chunkRemaining;
                            fu = fl = 0;
                            state = RxState::P;
                        } else {
//                            //cout << "Rx Packet " << packetNum << ", isFinal: " << isFinal << ", token: " << token << ", " << "payload length: " << payloadLength << "\n";
                            packetNum++;
                            state = RxState::H0;
                        }
                        i += 1;
                        startOverIndex = i;
                    } else {
                        badFl += 1;
                        state = RxState::H0;
                        i = startOverIndex;
                    }
                    break;
                case RxState::H0:
                    if ((bytes[i] & 0xE8) == 0x80) {
                        state = RxState::H1;
                        RH0 = bytes[i];
                        fu = fl = RH0;
                    } else {
                        badH0 += 1;
                    }
                    i += 1;
                    break;
                case RxState::H1:
                    RH1 = bytes[i];
                    state = RxState::H2;
                    fu += fl += RH1;
                    startOverIndex = i;
                    i += 1;
                    break;
                case RxState::H2:
                    isFinal = RH0 & 0x10;
                    payloadLength = (RH0 & 0x07) << 8 | RH1;
                    payloadRemaining = payloadLength;
                    token = bytes[i];
                    state = RxState::Fu;
                    fu += fl += token;
                    i += 1;
                    break;
            }


        }


//        //cout << "badH0: " << badH0 << ", badFu: " << badFu << ", badFl: " << badFl << "\n";

    }
    



    void PropCR::receiveThreadEntry(SteadyTimePoint timeoutTime) {

//        cout << "starting receive thread\n";

        rxStart = 0;
        rxEnd = 0;
        rxLength = 0;

        size_t count = 0;
        size_t maxRead = 0;


        try {
            while (true) {

                // Check for transaction timeout.
                Milliseconds remaining = std::chrono::duration_cast<Milliseconds>(timeoutTime - simple::SteadyClock::now());
                if (remaining.count() < 1) {
                    std::stringstream ss;
                    ss << "Transaction timeout occurred while receiving packet.";
                    throw TransactionError(Error::Timeout, ss.str());
                }

                size_t numExpected = 5;

                size_t numAvailable = available();
                size_t numToRead = std::max(numAvailable, numExpected);
                size_t numToRollover = rxBufferSize - rxLength;
                numToRead = std::min(numToRead, numToRollover);

                if (numToRead > maxRead) maxRead = numToRead;
                size_t numRead = read(&rxBuffer[rxEnd], numToRead);

                rxEnd += numRead;
                rxLength += numRead;
                if (rxEnd >= rxBufferSize) {
                    rxEnd -= rxBufferSize;
                }

                count++;
            }
        } catch (...) {
            rxThreadException = std::current_exception();
        }

//        while (continueReceiveThread) {
//
//            size_t numExpected = 5;
//
//            try {
//                size_t numAvailable = available();
//                size_t numToRead = std::max(numAvailable, numExpected);
//                size_t numToRollover = rxBufferSize - rxLength;
//                numToRead = std::min(numToRead, numToRollover);
//
//                if (numToRead > maxRead) maxRead = numToRead;
//                size_t numRead = read(&rxBuffer[rxEnd], numToRead);
//
//                rxEnd += numRead;
//                rxLength += numRead;
//                if (rxEnd >= rxBufferSize) {
//                    rxEnd -= rxBufferSize;
//                }
//
//            } catch (const hserial::NotActiveController& e) {
//
//                cout << "exception in receive thread: " << e.what() << "\n";
//                continueReceiveThread.store(false);
//            }
//
//            count++;
//
//        }

//        cout << "stopping receive thread\n";
//        cout << " maxRead: " << maxRead << ", count: " << count << "\n";

        parser(&rxBuffer[rxStart], rxLength);



    }


}
