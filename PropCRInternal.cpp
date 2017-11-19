//
//  PropCRInternal.cpp
//  Final Sprint
//
//  Created by admin on 5/14/17.
//  Copyright © 2017 Chris Siedell. All rights reserved.
//

#include "PropCRInternal.hpp"


#include <cassert>

#include "SimpleErrors.hpp"

#include <iostream>
#include <iomanip>



using std::cout;


namespace propcr {


#pragma mark - Parameter Verification

    void throwIfAddressIsInvalid(uint8_t address) {
        if (address > 31) {
            throw std::invalid_argument("Address must be 31 or less.");
        }
    }

    void throwIfBroadcastAddress(uint8_t address) {
        if (address == 0) {
            throw std::invalid_argument("Specific address required -- not the broadcast address (0).");
        }
    }

#pragma mark - Packet Creation and Parsing

    void createCommandPacket(const CommandHeader& header, std::vector<uint8_t>& payload, std::vector<uint8_t>& buffer, bool reorderForProp) {

        uint8_t* payloadData = payload.data();
        size_t payloadSize = payload.size();

        if (payloadSize != header.payloadLength) {
            throw std::invalid_argument("Inconsistent payload lengths in createCommandPacket.");
        }

        if (header.payloadLength > 2047) {
            throw std::invalid_argument("Payload too big.");
        }

        throwIfAddressIsInvalid(header.address);

        if (header.address == 0 && !header.muteResponse) {
            throw std::invalid_argument("Broadcast commands (address 0) must mute responses.");
        }

        buffer.clear();

        // reduce reallocations of buffer
        size_t headerSize = (header.protocol == 0) ? 6 : 8;
        size_t numChunks = payloadSize/128;
        if (payloadSize%128 != 0) numChunks += 1;
        size_t packetSize = headerSize + payloadSize + 2*numChunks;
        //cout << "packet size: " << packetSize << "\n";
        buffer.reserve(packetSize);

        /* Command Header
         *
         *       |7|6|5|4|3|2|1|0|
         * ------|---------------|
         *  CH0  |0|1|0|T|0| Lu  |
         *  CH1  |      Ll       |
         *  CH2  |       K       |
         *  CH3  |X|M|0|    A    |
         * (CH4) |      Pu       |
         * (CH5) |      Pl       |
         *  CH6  |      C0       |
         *  CH7  |      C1       |
         */

        // CH0, CH1, CH2
        uint8_t CH0 = 0x40 | header.payloadLength >> 8;
        if (header.isUserCommand) {
            CH0 |= 0x10;
        }
        buffer.push_back(CH0);
        buffer.push_back(header.payloadLength);
        buffer.push_back(header.token);

        // CH3, (CH4, CH5)
        uint8_t CH3 = header.address;
        if (header.muteResponse) {
            CH3 |= 0x40;
        }
        if (header.protocol == 0) {
            buffer.push_back(CH3);

        } else {
            buffer.push_back(CH3 | 0x80);
            buffer.push_back(header.protocol >> 8); // CH4
            buffer.push_back(header.protocol); // CH5
        }

        // CH5, CH6
        uint8_t CH5, CH6, fLower, fUpper;
        getFletcher16(buffer.data(), buffer.size(), fLower, fUpper);
        getFletcher16Checkbytes(fLower, fUpper, CH5, CH6);
        buffer.push_back(CH5);
        buffer.push_back(CH6);

        // The body consists of chunks of 3-130 bytes. Each chunk has payload data and two checkbytes.
        // See "Crow Specification v1.txt" for exact details.

        // The payload is reordered in transmission for the convenience of the prop. Each four byte
        //  chunk (long) has its bytes reversed. A two or three byte remainder chunk will also
        //  have its bytes reversed. The F16 is performed on the reordered sequence.

        // Example:   payload = {P0, P1, P2, P3, P4, P5, P6, P7, P8, P9}
        //          reordered = {P3, P2, P1, P0, P7, P6, P5, P4, P9, P8}

        // When received by the propeller the bytes will be reordered again so that they are in the
        //  expected order. Specifically, they will look like this in cog memory:

        //    Register            | byte3 | byte2 | byte1 | byte0 |
        //    --------------------|-------|-------|-------|-------|
        //    Payload             |   P3  |   P2  |   P1  |   P0  |
        //    +1                  |   P7  |   P6  |   P5  |   P4  |
        //    +2                  |   0   |   0   |   P9  |   P8  |

        // Non-payload upper bytes of the last long will be zeroed out.

        // task: copy payload to buffer, reordering as required, and adding checkbytes after
        //       each chunk

        size_t payloadRemaining = payloadSize;
        size_t mvIndex = 0; // base index of each four byte value to copy during reordering

        uint8_t check0, check1;

        uint8_t longValue[4];
        uint8_t* plus2 = longValue + 2;
        uint8_t* plus3 = longValue + 3;
        uint8_t* plus4 = longValue + 4;

        size_t bIndex = buffer.size(); // starting at position after header

        while (payloadRemaining > 0) {

            // Add chunk's reordered payload data to buffer.
            size_t cpSize = std::min<size_t>(128, payloadRemaining);
            payloadRemaining -= cpSize;
            size_t cpRemaining = cpSize;
            while (cpRemaining > 0) {
                if (cpRemaining >= 4) {
                    longValue[3] = payloadData[mvIndex++];
                    longValue[2] = payloadData[mvIndex++];
                    longValue[1] = payloadData[mvIndex++];
                    longValue[0] = payloadData[mvIndex++];
                    buffer.insert(buffer.end(), longValue, plus4);
                    cpRemaining -= 4;
                } else if (cpRemaining == 3) {
                    longValue[2] = payloadData[mvIndex++];
                    longValue[1] = payloadData[mvIndex++];
                    longValue[0] = payloadData[mvIndex++];
                    buffer.insert(buffer.end(), longValue, plus3);
                    cpRemaining -= 3;
                } else if (cpRemaining == 2) {
                    longValue[1] = payloadData[mvIndex++];
                    longValue[0] = payloadData[mvIndex++];
                    buffer.insert(buffer.end(), longValue, plus2);
                    cpRemaining -= 2;
                } else {
                    buffer.push_back(payloadData[mvIndex++]);
                    cpRemaining -= 1;
                }
            }

            // Add chunk's check bytes.
            getFletcher16(&buffer.data()[bIndex], cpSize, fLower, fUpper);
            bIndex += cpSize + 2;
            getFletcher16Checkbytes(fLower, fUpper, check0, check1);
            buffer.push_back(check0);
            buffer.push_back(check1);

        }
    }

    bool parseResponseHeaderAndGetParams(uint8_t* bytes, ResponseHeader& header) {
        // Assumes bytes has 5 bytes available.

        /* Response Header
         *
         *       |7|6|5|4|3|2|1|0|
         * ------|---------------|
         *  RH0  |1|0|0|F|0| Lu  |
         *  RH1  |      Ll       |
         *  RH2  |       K       |
         *  RH3  |      Fu       |
         *  RH4  |      Fl       |
         */

        // Verify reserved bits.
        if ((bytes[0] & 0xE8) != 0x80) {
            cout << "*** bad reserved bits, bytes[0]: " << int(bytes[0]) << "\n";
            return false;
        }

        // Verify checksum.
        uint8_t fLower, fUpper;
        getFletcher16(bytes, 3, fLower, fUpper);
        if (unequalFletcher16Sums(fLower, fUpper, bytes[4], bytes[3])) {
            cout << "*** unequal Fletcher16Sums, bytes[4]: " << int(bytes[4]) << ", bytes[3]: " << int(bytes[3]) << ", fLower: " << int(fLower) << ", fUpper: " << int(fUpper) << "\n";
            return false;
        }

        // Success.
        header.isFinal = bytes[0] & 0x10;
        header.payloadLength = (bytes[0] & 0x07) << 8 | bytes[1];
        header.token = bytes[2];

        return true;
    }



    bool parseGetDeviceInfoResponse(const ResponseHeader& header, const std::vector<uint8_t>& payload, DeviceInfo& info, std::string& failureReason) {

        if (!header.isFinal) {
            failureReason = "A getDeviceInfo response should be final.";
            return false;
        }

        const uint8_t* payloadData = payload.data();
        size_t payloadSize = payload.size();

        if (header.payloadLength != payloadSize) {
            std::stringstream ss;
            ss << "Inconsistent values for payload length (" << header.payloadLength << " and " << payloadSize << ").";
            failureReason = ss.str();
            return false;
        }

        if (payloadSize < 8) {
            std::stringstream ss;
            ss << "The getDeviceInfo response is too short (" << payloadSize << " bytes).";
            failureReason = ss.str();
            return false;
        }

        if (payloadData[0] != 0) {
            std::stringstream ss;
            ss << std::setw(2) << std::uppercase << std::hex;
            ss << "Incorrect first byte of getDeviceInfo response (" << static_cast<int>(payloadData[0]) << ").";
            failureReason = ss.str();
            return false;
        }

        info.crowVersion = payloadData[1];
        info.implementationID = payloadData[2] << 8 | payloadData[3];
        info.maxPayloadLength = payloadData[4] << 8 | payloadData[5];

        size_t numAdminProtocols = payloadData[6];
        size_t numUserProtocols = payloadData[7];

        size_t expectedPayloadSize = 8 + 2*numAdminProtocols + 2*numUserProtocols;

        if (expectedPayloadSize != payloadSize) {
            std::stringstream ss;
            ss << "Unexpected payload length (" << expectedPayloadSize << ") for the given number of supported protocols ("
            << numAdminProtocols << " admin, " << numUserProtocols << " user).";
            failureReason = ss.str();
            return false;
        }

        size_t index = 8;

        info.adminProtocols.clear();
        info.userProtocols.clear();

        for (int i = 0; i < numAdminProtocols; ++i) {
            info.adminProtocols.push_back(payloadData[index] << 8 | payloadData[index+1]);
            index += 2;
        }

        for (int i = 0; i < numUserProtocols; ++i) {
            info.userProtocols.push_back(payloadData[index] << 8 | payloadData[index+1]);
            index += 2;
        }

        return true;
    }
    

#pragma mark - HostTransactionInitiator


    PropCR::TransactionInitiator::TransactionInitiator(PropCR& _host) : host(_host), lock(host.t_mutex) {

        assert(lock.owns_lock());

        // Only one transaction at a time.
        if (host.t_transaction.load() != Transaction::None) {
            throw simple::IsBusyError("Host is busy.");
        }

        // Caller is now free to set up the transaction in a thread safe way.
        // startTransaction must still be called after setup to perform the transaction.
    }

    void PropCR::TransactionInitiator::startTransaction(Transaction transaction, void* context) {

        if (transaction == Transaction::None) {
            assert(false);
            throw std::logic_error("TransactionInitiator::startTransaction does not accept Transaction::None.");
        }

        if (transactionStarted) {
            assert(false);
            throw std::logic_error("TransactionInitiator::startTransaction must be called only once.");
        }

        transactionStarted = true;

        assert(lock.owns_lock());

        // Copy the current settings after user setup. Public changes to settings do not apply to a
        //  transaction in progress.
        host.t_baudrate = host.s_baudrate.load();
        host.t_stopbits = host.s_stopbits.load();
        host.t_timeout = host.s_timeout.load();
        host.t_monitor = host.s_monitor.load();

        // Context is reported with the callbacks.
        host.t_context = context;

        // Set state to begin a new transaction.
        host.t_counter += 1;
        host.t_isCancelled.store(false);
        host.t_transaction.store(transaction);

        // Notify transaction thread that a transaction is ready.
        lock.unlock();
        host.t_wakeupCondition.notify_one();

        assert(!lock.owns_lock());
    }


#pragma mark - Fletcher 16 Error Detection

    void getFletcher16(uint8_t* bytes, size_t numBytes, uint8_t& lower, uint8_t& upper) {
        // This algorithm was copied (4 May 2017) from
        // https://en.wikipedia.org/wiki/Fletcher%27s_checksum
        // todo: this code is expected to run on at least 32 bit machines, so could use uint32_t
        //  sums and increase the number of additions before first reduction step
        uint16_t sum1 = 0xff, sum2 = 0xff;
        size_t tlen;
        while (numBytes) {
            tlen = ((numBytes >= 20) ? 20 : numBytes);
            numBytes -= tlen;
            do {
                sum2 += sum1 += *bytes++;
                tlen--;
            } while (tlen);
            sum1 = (sum1 & 0xff) + (sum1 >> 8);
            sum2 = (sum2 & 0xff) + (sum2 >> 8);
        }
        /* Second reduction step to reduce sums to 8 bits */
        lower = (sum1 & 0xff) + (sum1 >> 8);
        upper = (sum2 & 0xff) + (sum2 >> 8);
    }

    void getFletcher16Checkbytes(uint8_t lower, uint8_t upper, uint8_t& check0, uint8_t& check1) {
        // Formula from the wikipedia entry for Fletcher's checksum.
        check0 = 0xff - ((lower + upper) % 0xff);
        check1 = 0xff - ((lower + check0) % 0xff);
    }
    
    bool unequalFletcher16Sums(uint8_t lowerA, uint8_t upperA, uint8_t lowerB, uint8_t upperB) {
        lowerA %= 0xff;
        upperA %= 0xff;
        lowerB %= 0xff;
        upperB %= 0xff;
        return lowerA != lowerB || upperA != upperB;
    }
    
}
