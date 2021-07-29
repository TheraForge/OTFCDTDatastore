//
//  TDMultiStreamWriter.m
//  TouchDB
//
//  Created by Jens Alfke on 2/3/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.
//
//  Modifications for this distribution by Cloudant, Inc., Copyright (c) 2014 Cloudant, Inc.

#import "TDMultiStreamWriter.h"
#import "CDTLogging.h"
#import "Test.h"

#define kDefaultBufferSize 32768

@interface TDMultiStreamWriter () <NSStreamDelegate>
@property (readwrite, strong) NSError* error;
@end

@implementation TDMultiStreamWriter

@synthesize error = _error, length = _length;

- (id)initWithBufferSize:(NSUInteger)bufferSize
{
    self = [super init];
    if (self) {
        _inputs = [[NSMutableArray alloc] init];
        _bufferLength = 0;
        _bufferSize = bufferSize;
        _buffer = malloc(_bufferSize);
        if (!_buffer) {
            return nil;
        }
    }
    return self;
}

- (id)init { return [self initWithBufferSize:kDefaultBufferSize]; }

- (void)dealloc
{
    [self close];
    free(_buffer);
}

- (void)addInput:(id)input length:(UInt64)length
{
    [_inputs addObject:input];
    _length += length;
}

- (void)addStream:(NSInputStream*)stream length:(UInt64)length
{
    [self addInput:stream length:length];
}

- (void)addStream:(NSInputStream*)stream
{
    os_log_info(CDTOSLog, "%{public}@: adding stream of unknown length: %{public}@", self, stream);
    [_inputs addObject:stream];
    _length = -1;  // length is now unknown
}

- (void)addData:(NSData*)data
{
    if (data.length > 0) [self addInput:data length:data.length];
}

- (BOOL)addFileURL:(NSURL*)url
{
    NSNumber* fileSizeObj;
    if (![url getResourceValue:&fileSizeObj forKey:NSURLFileSizeKey error:nil]) return NO;
    [self addInput:url length:fileSizeObj.unsignedLongLongValue];
    return YES;
}

- (BOOL)addFile:(NSString*)path { return [self addFileURL:[NSURL fileURLWithPath:path]]; }

#pragma mark - OPENING:

- (BOOL)isOpen { return _output.delegate != nil; }

- (void)opened
{
    _error = nil;
    _totalBytesWritten = 0;

    _output.delegate = self;
    [_output scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [_output open];
}

- (NSInputStream*)openForInputStream
{
    if (_input) return _input;
    Assert(!_output, @"Already open");
#ifdef GNUSTEP
    Assert(NO, @"Unimplemented CFStreamCreateBoundPair");  // TODO: Add this to GNUstep base fw
#else
    CFReadStreamRef cfInput;
    CFWriteStreamRef cfOutput;
    CFStreamCreateBoundPair(NULL, &cfInput, &cfOutput, _bufferSize);
    _input = CFBridgingRelease(cfInput);
    _output = CFBridgingRelease(cfOutput);
#endif
    os_log_info(CDTOSLog, "%{public}@: Opened input=%{public}p, output=%{public}p", self, _input, _output);
    [self opened];
    return _input;
}

- (void)openForOutputTo:(NSOutputStream*)output
{
    Assert(output);
    Assert(!_output, @"Already open");
    Assert(!_input);
    _output = output;
    [self opened];
}

- (void)close
{
    os_log_info(CDTOSLog, "%{public}@: Closed", self);
    [_output close];
    _output.delegate = nil;
    _output = nil;
    _input = nil;

    _bufferLength = 0;

    [_currentInput close];
    _currentInput = nil;
    _nextInputIndex = 0;
}

#pragma mark - I/O:

- (NSInputStream*)streamForInput:(id)input
{
    if ([input isKindOfClass:[NSData class]])
        return [NSInputStream inputStreamWithData:input];
    else if ([input isKindOfClass:[NSURL class]] && [input isFileURL])
        return [NSInputStream inputStreamWithFileAtPath:[(NSURL*)input path]];
    else if ([input isKindOfClass:[NSInputStream class]])
        return input;
    else
        Assert(NO, @"Invalid input class %@ for TDMultiStreamWriter", [input class]);
}

// Close the current input stream and open the next one, assigning it to _currentInput.
- (BOOL)openNextInput
{
    if (_currentInput) {
        [_currentInput close];
        _currentInput = nil;
    }
    if (_nextInputIndex < _inputs.count) {
        _currentInput = [self streamForInput:_inputs[_nextInputIndex]];
        ++_nextInputIndex;
        [_currentInput open];
        return YES;
    }
    return NO;
}

// Set my .error property from 'stream's error.
- (void)setErrorFrom:(NSStream*)stream
{
    NSError* error = stream.streamError;
    os_log_debug(CDTOSLog, "%{public}@: Error on %{public}@: %{public}@", self, stream, error);
    if (error && !_error) self.error = error;
}

// Read up to 'len' bytes from the aggregated input streams to 'buffer'.
- (NSInteger)read:(uint8_t*)buffer maxLength:(NSUInteger)len
{
    NSInteger totalBytesRead = 0;
    while (len > 0 && _currentInput) {
        NSInteger bytesRead = [_currentInput read:buffer maxLength:len];
        os_log_info(CDTOSLog, "%{public}@:     read %{public}d bytes from %{public}@", self, (int)bytesRead, _currentInput);
        if (bytesRead > 0) {
            // Got some data from the stream:
            totalBytesRead += bytesRead;
            buffer += bytesRead;
            len -= bytesRead;
        } else if (bytesRead == 0) {
            // At EOF on stream, so go to the next one:
            [self openNextInput];
        } else {
            // There was a read error:
            [self setErrorFrom:_currentInput];
            return bytesRead;
        }
    }
    return totalBytesRead;
}

// Read enough bytes from the aggregated input to refill my _buffer. Returns success/failure.
- (BOOL)refillBuffer
{
    os_log_info(CDTOSLog, "%{public}@:   Refilling buffer", self);
    NSInteger bytesRead = [self read:_buffer + _bufferLength maxLength:_bufferSize - _bufferLength];
    if (bytesRead <= 0) {
        os_log_info(CDTOSLog, "%{public}@:     at end of input, can't refill", self);
        return NO;
    }
    _bufferLength += bytesRead;
    os_log_info(CDTOSLog, "%{public}@:   refilled buffer to %{public}u bytes", self, (unsigned)_bufferLength);
    // LogTo(TDMultiStreamWriter, @"%@:   buffer is now \"%.*s\"", self, _bufferLength, _buffer);
    return YES;
}

// Write from my _buffer to _output, then refill _buffer if it's not halfway full.
- (BOOL)writeToOutput
{
    Assert(_bufferLength > 0);
    NSInteger bytesWritten = [_output write:_buffer maxLength:_bufferLength];
    os_log_info(CDTOSLog, "%{public}@:   Wrote %{public}d (of %{public}u) bytes to _output (total %{public}lld of %{public}lld)", self, (int)bytesWritten, (unsigned)_bufferLength, _totalBytesWritten + bytesWritten, _length);
    if (bytesWritten <= 0) {
        [self setErrorFrom:_output];
        return NO;
    }
    _totalBytesWritten += bytesWritten;
    Assert(bytesWritten <= (NSInteger)_bufferLength);
    _bufferLength -= bytesWritten;
    memmove(_buffer, _buffer + bytesWritten, _bufferLength);
    // LogTo(TDMultiStreamWriter, @"%@:     buffer is now \"%.*s\"", self, _bufferLength, _buffer);
    if (_bufferLength <= _bufferSize / 2) [self refillBuffer];
    return _bufferLength > 0;
}

// Handle an async event on my _output stream -- basically, write to it when it has room.
- (void)stream:(NSStream*)stream handleEvent:(NSStreamEvent)event
{
    if (stream != _output) return;
    os_log_info(CDTOSLog, "%{public}@: Received event 0x%{public}x", self, (unsigned)event);
    switch (event) {
        case NSStreamEventOpenCompleted:
            if ([self openNextInput]) [self refillBuffer];
            break;

        case NSStreamEventHasSpaceAvailable:
            if (_input && _input.streamStatus < NSStreamStatusOpen) {
                // CFNetwork workaround; see https://github.com/couchbaselabs/TouchDB-iOS/issues/99
                os_log_info(CDTOSLog, "%{public}@:   Input isn't open; waiting...", self);
                [self performSelector:@selector(retryWrite:) withObject:stream afterDelay:0.1];
            } else if (![self writeToOutput]) {
                os_log_info(CDTOSLog, "%{public}@:   At end -- closing _output!", self);
                if (_totalBytesWritten != _length && !_error)
                    os_log_debug(CDTOSLog, "%{public}@ wrote %{public}lld bytes, but expected length was %{public}lld!", self, _totalBytesWritten, _length);
                [self close];
            }
            break;

        case NSStreamEventEndEncountered:
            // This means the _input stream was closed before reading all the data.
            [self close];
            break;
        default:
            break;
    }
}

- (void)retryWrite:(NSStream*)stream
{
    [self stream:stream handleEvent:NSStreamEventHasSpaceAvailable];
}

- (NSData*)allOutput
{
    NSOutputStream* output = [NSOutputStream outputStreamToMemory];
    [self openForOutputTo:output];

    while (self.isOpen) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    }

    return [output propertyForKey:NSStreamDataWrittenToMemoryStreamKey];
}

@end
