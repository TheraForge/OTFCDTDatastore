//
//  TDReachability.m
//  TouchDB
//
//  Created by Jens Alfke on 2/13/12.
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

#import "TDReachability.h"
#import "CollectionUtils.h"
#include <arpa/inet.h>

#if TARGET_OS_IOS
#import <SystemConfiguration/SystemConfiguration.h>

static void ClientCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags,
                           void *info);
#endif


@interface TDReachability ()
@property (readwrite, nonatomic) BOOL reachabilityKnown;
#if TARGET_OS_IOS
@property (readwrite, nonatomic) SCNetworkReachabilityFlags reachabilityFlags;
- (void)flagsChanged:(SCNetworkReachabilityFlags)flags;
#endif

@end

@implementation TDReachability

- (id)initWithHostName:(NSString *)hostName
{
    self = [super init];
    if (self) {
        if (!hostName.length) hostName = @"localhost";
        _hostName = [hostName copy];
#if TARGET_OS_IOS
        _ref = SCNetworkReachabilityCreateWithName(NULL, [_hostName UTF8String]);
        SCNetworkReachabilityContext context = {0, (__bridge void *)(self)};
        if (!_ref || !SCNetworkReachabilitySetCallback(_ref, ClientCallback, &context)) {
            return nil;
        }
#endif
    }
    return self;
}

- (BOOL)start
{
    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    if (_runLoop) return (_runLoop == runLoop);
#if TARGET_OS_IOS
    if (!SCNetworkReachabilityScheduleWithRunLoop(_ref, runLoop, kCFRunLoopCommonModes)) return NO;
#endif
    _runLoop = (CFRunLoopRef)CFRetain(runLoop);

    // See whether status is already known:
#if TARGET_OS_IOS
    if (SCNetworkReachabilityGetFlags(_ref, &_reachabilityFlags)) _reachabilityKnown = YES;
#endif
    
    return YES;
}

- (void)stop
{
    if (_runLoop) {
#if TARGET_OS_IOS
        SCNetworkReachabilityUnscheduleFromRunLoop(_ref, _runLoop, kCFRunLoopCommonModes);
#endif
        CFRelease(_runLoop);
        _runLoop = NULL;
    }
}

- (void)dealloc
{
#if TARGET_OS_IOS
    if (_ref) {
        [self stop];
        CFRelease(_ref);
    }
#endif
}

@synthesize hostName = _hostName, onChange = _onChange, reachabilityKnown = _reachabilityKnown;
#if TARGET_OS_IOS
@synthesize reachabilityFlags = _reachabilityFlags;
#endif

- (NSString *)status
{
    if (!_reachabilityKnown)
        return @"unknown";
    else if (!self.reachable)
        return @"unreachable";
#if TARGET_OS_IOS
    else if (!self.reachableByWiFi)
        return @"reachable (3G)";
#endif
    else
        return @"reachable";
}

- (NSString *)description {
#if TARGET_OS_WATCH
    return [NSString stringWithFormat:@"<%@>:%@", _hostName, self.status];
#else
    return $sprintf(@"<%@>:%@", _hostName, self.status);
#endif
}

- (BOOL)reachable
{
    // We want 'reachable' to be on, but not any of the flags that indicate that a network interface
    // must first be brought online.
    return _reachabilityKnown
#if TARGET_OS_IOS
            && (_reachabilityFlags &
            (kSCNetworkReachabilityFlagsReachable | kSCNetworkReachabilityFlagsConnectionRequired |
             kSCNetworkReachabilityFlagsConnectionAutomatic |
             kSCNetworkReachabilityFlagsInterventionRequired)) ==
               kSCNetworkReachabilityFlagsReachable
#endif
    ;
}

- (BOOL)reachableByWiFi
{
    return self.reachable
#if TARGET_OS_IOS
           && !(_reachabilityFlags & kSCNetworkReachabilityFlagsIsWWAN)
#endif
        ;
}

+ (NSSet *)keyPathsForValuesAffectingReachable
{
    return [NSSet setWithObjects:@"reachabilityKnown", @"reachabilityFlags", nil];
}

+ (NSSet *)keyPathsForValuesAffectingReachableByWiFi
{
    return [NSSet setWithObjects:@"reachabilityKnown", @"reachabilityFlags", nil];
}

- (void)flagsChanged
#if TARGET_OS_IOS
:(SCNetworkReachabilityFlags)flags
#endif
{
    if (!_reachabilityKnown
#if TARGET_OS_IOS
        || flags != _reachabilityFlags
#endif
        ) {
#if TARGET_OS_IOS
        self.reachabilityFlags = flags;
#endif
        self.reachabilityKnown = YES;
        if (_onChange) _onChange();
    }
}

static void ClientCallback(
#if TARGET_OS_IOS
                           SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags,
#endif
                           void *info)
{
    [(__bridge TDReachability *)info flagsChanged
#if TARGET_OS_IOS
     :flags
#endif
    ];
}

@end
