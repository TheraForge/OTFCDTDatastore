//
//  MRDatabaseContentChecker.h
//
//  Created by Michael Rhodes on 11/05/2014.
//  Copyright (c) 2014 Mike Rhodes. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import <Foundation/Foundation.h>

#import "FMDatabase.h"
#import "FMDatabaseQueue.h"


/**
 * Indexing and query erors.
 */
typedef NS_ENUM(NSInteger, MRDatabaseContentCheckerError) {
    /**
     Validation of database failed
     */
    MRDatabaseContentCheckerErrorValidation = 1
};

/**
 Error domain for the database checker
 */
extern NSString* const MRDatabaseContentCheckerErrorDomain;

/**
 Key in user info dict for error messages.

 A typical use would be to use componentsJoinedByString: to
 join in an assert message.
 */
extern NSString* const MRDatabaseContentCheckerErrorsArray;

@interface MRDatabaseContentChecker : NSObject

- (NSString*)formattedErrors:(NSError*)error;

- (BOOL)checkDatabase:(FMDatabase*)db
                table:(NSString*)table
              hasRows:(NSArray*)expectedContent
                error:(NSError* __autoreleasing *)error;

- (BOOL)checkDatabase:(FMDatabase*)db
                table:(NSString*)table
              hasRows:(NSArray*)expectedContent
              orderBy:(NSArray*)orderby
                error:(NSError* __autoreleasing *)error;

@end
