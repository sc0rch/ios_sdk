//
//  ADJActivityPackage.m
//  Adjust
//
//  Created by Christian Wellenbrock on 2013-07-03.
//  Copyright (c) 2013 adjust GmbH. All rights reserved.
//

#import "ADJActivityKind.h"
#import "ADJActivityPackage.h"
#import "ADJAdjustFactory.h"

@interface ADJActivityPackage ()
@property (nonatomic, strong) NSLock *propertyLock;
@end

@implementation ADJActivityPackage

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    
    @try {
        self.propertyLock = [[NSLock alloc] init];
        if (self.propertyLock == nil) return nil;
    } @catch (NSException *ex) {
        return nil; 
    }
    return self;
}

#pragma mark - Public methods

- (NSString *)extendedString {
    NSMutableString *builder = [NSMutableString string];
    NSArray *excludedKeys = @[
        @"secret_id",
        @"app_secret",
        @"signature",
        @"headers_id",
        @"native_version",
        @"adj_signing_id"];

    // Make thread-safe copies of properties
    [self.propertyLock lock];
    NSString *pathCopy = [self.path copy];
    NSString *clientSdkCopy = [self.clientSdk copy];
    NSDictionary *parametersCopy = [self.parameters copy];
    [self.propertyLock unlock];

    [builder appendFormat:@"Path:      %@\n", pathCopy];
    [builder appendFormat:@"ClientSdk: %@\n", clientSdkCopy];

    if (parametersCopy != nil) {
        NSArray *sortedKeys = [[parametersCopy allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        NSUInteger keyCount = [sortedKeys count];

        [builder appendFormat:@"Parameters:"];
        
        for (NSUInteger i = 0; i < keyCount; i++) {
            NSString *key = (NSString *)[sortedKeys objectAtIndex:i];

            if ([excludedKeys containsObject:key]) {
                continue;
            }

            NSString *value = [parametersCopy objectForKey:key];
            
            [builder appendFormat:@"\n\t\t%-22s %@", [key UTF8String], value];
        }
    }

    return builder;
}

- (NSString *)description {
    @try {
        [self.propertyLock lock];
        NSString *result = [NSString stringWithFormat:@"%@%@", 
                           [ADJActivityKindUtil activityKindToString:self.activityKind], 
                           self.suffix ?: @""];
        [self.propertyLock unlock];
        return result;
    } @catch (NSException *ex) {
        [self.propertyLock unlock];
        return @"";
    }
}

- (NSString *)successMessage {
    [self.propertyLock lock];
    NSString *result = [NSString stringWithFormat:@"Tracked %@%@", 
                       [ADJActivityKindUtil activityKindToString:self.activityKind], 
                       self.suffix ?: @""];
    [self.propertyLock unlock];
    return result;
}

- (NSString *)failureMessage {
    [self.propertyLock lock];
    NSString *result = [NSString stringWithFormat:@"Failed to track %@%@", 
                       [ADJActivityKindUtil activityKindToString:self.activityKind], 
                       self.suffix ?: @""];
    [self.propertyLock unlock];
    return result;
}

- (void)addError:(NSNumber *)errorCode {
    [self.propertyLock lock];
    self.errorCount = self.errorCount + 1;

    if (self.firstErrorCode == nil) {
        self.firstErrorCode = errorCode;
    } else {
        self.lastErrorCode = errorCode;
    }
    [self.propertyLock unlock];
}

#pragma mark - NSCoding protocol methods

- (id)initWithCoder:(NSCoder *)decoder {
    self = [super init];
    if (self == nil) {
        return self;
    }

    self.propertyLock = [[NSLock alloc] init];

    @try {
        [self.propertyLock lock];
        
        // Safe string decoding with nil check
        self.path = [decoder decodeObjectOfClass:[NSString class] forKey:@"path"];
        self.suffix = [decoder decodeObjectOfClass:[NSString class] forKey:@"suffix"];
        self.clientSdk = [decoder decodeObjectOfClass:[NSString class] forKey:@"clientSdk"];
        
        // Safe dictionary decoding with type checking
        id parametersObj = [decoder decodeObjectForKey:@"parameters"];
        if ([parametersObj isKindOfClass:[NSDictionary class]]) {
            self.parameters = [NSMutableDictionary dictionaryWithDictionary:parametersObj];
        } else {
            self.parameters = [NSMutableDictionary dictionary];
        }
        
        id partnerParametersObj = [decoder decodeObjectForKey:@"partnerParameters"];
        if ([partnerParametersObj isKindOfClass:[NSDictionary class]]) {
            self.partnerParameters = partnerParametersObj;
        }
        
        id callbackParametersObj = [decoder decodeObjectForKey:@"callbackParameters"];
        if ([callbackParametersObj isKindOfClass:[NSDictionary class]]) {
            self.callbackParameters = callbackParametersObj;
        }

        NSString *kindString = [decoder decodeObjectOfClass:[NSString class] forKey:@"kind"];
        self.activityKind = [ADJActivityKindUtil activityKindFromString:kindString];

        // Safe number decoding
        NSNumber *errorCountNum = [decoder decodeObjectOfClass:[NSNumber class] forKey:@"errorCount"];
        self.errorCount = errorCountNum ? [errorCountNum unsignedIntegerValue] : 0;
        
        self.firstErrorCode = [decoder decodeObjectOfClass:[NSNumber class] forKey:@"firstErrorCode"];
        self.lastErrorCode = [decoder decodeObjectOfClass:[NSNumber class] forKey:@"lastErrorCode"];
        
        NSNumber *waitBeforeSendNum = [decoder decodeObjectOfClass:[NSNumber class] forKey:@"waitBeforeSend"];
        self.waitBeforeSend = waitBeforeSendNum ? [waitBeforeSendNum doubleValue] : 0.0;
        
        [self.propertyLock unlock];
    } @catch (NSException *exception) {
        [self.propertyLock unlock];
        [ADJAdjustFactory.logger error:@"Failed to decode activity package: %@", exception];
        return nil;
    }

    return self;
}

- (void)encodeWithCoder:(NSCoder *)encoder {
    NSString *localPathCopy = nil;  // Add local variable for path copy
    [self.propertyLock lock];
    @try {
        // Make thread-safe copies of all properties we'll need
        NSDictionary *parametersCopy = [self.parameters copy];
        NSDictionary *partnerParametersCopy = [self.partnerParameters copy];
        NSDictionary *callbackParametersCopy = [self.callbackParameters copy];
        localPathCopy = [self.path copy];  // Store in local variable
        NSString *suffixCopy = [self.suffix copy];
        NSString *clientSdkCopy = [self.clientSdk copy];
        ADJActivityKind activityKindCopy = self.activityKind;
        NSUInteger errorCountCopy = self.errorCount;
        NSNumber *firstErrorCodeCopy = [self.firstErrorCode copy];
        NSNumber *lastErrorCodeCopy = [self.lastErrorCode copy];
        double waitBeforeSendCopy = self.waitBeforeSend;
        
        [self.propertyLock unlock];
        
        // Check dictionary sizes first to prevent memory issues
        NSUInteger totalSize = 0;
        if (parametersCopy) {
            totalSize += parametersCopy.count;
        }
        if (partnerParametersCopy) {
            totalSize += partnerParametersCopy.count;
        }
        if (callbackParametersCopy) {
            totalSize += callbackParametersCopy.count;
        }
        
        // Arbitrary reasonable limit
        if (totalSize > 1000) {
            [ADJAdjustFactory.logger warn:@"Large package detected, some data might be truncated"];
        }
        
        // Check and safely encode strings
        [encoder encodeObject:localPathCopy ?: @"" forKey:@"path"];  // Use local variable
        
        NSString *kindString = [ADJActivityKindUtil activityKindToString:activityKindCopy];
        [encoder encodeObject:kindString ?: @"unknown" forKey:@"kind"];
        
        [encoder encodeObject:suffixCopy ?: @"" forKey:@"suffix"];
        [encoder encodeObject:clientSdkCopy ?: @"" forKey:@"clientSdk"];
        
        // Create safe copies of dictionaries for serialization
        NSMutableDictionary *safeParameters = [NSMutableDictionary dictionary];
        for (id key in parametersCopy) {
            if ([key isKindOfClass:[NSString class]]) {
                id value = parametersCopy[key];
                if ([value isKindOfClass:[NSString class]] ||
                    [value isKindOfClass:[NSNumber class]] ||
                    [value isKindOfClass:[NSDate class]]) {
                    safeParameters[key] = value;
                } else {
                    safeParameters[key] = [value description];
                }
            }
        }
        [encoder encodeObject:safeParameters forKey:@"parameters"];
        
        // Safe partner parameters encoding with deep validation
        if ([partnerParametersCopy isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *safePartnerParameters = [NSMutableDictionary dictionary];
            for (id key in partnerParametersCopy) {
                if ([key isKindOfClass:[NSString class]]) {
                    id value = partnerParametersCopy[key];
                    if ([value isKindOfClass:[NSString class]] ||
                        [value isKindOfClass:[NSNumber class]] ||
                        [value isKindOfClass:[NSDate class]]) {
                        safePartnerParameters[key] = value;
                    } else {
                        safePartnerParameters[key] = [value description];
                    }
                }
            }
            [encoder encodeObject:safePartnerParameters forKey:@"partnerParameters"];
        }
        
        // Safe callback parameters encoding with deep validation
        if ([callbackParametersCopy isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *safeCallbackParameters = [NSMutableDictionary dictionary];
            for (id key in callbackParametersCopy) {
                if ([key isKindOfClass:[NSString class]]) {
                    id value = callbackParametersCopy[key];
                    if ([value isKindOfClass:[NSString class]] ||
                        [value isKindOfClass:[NSNumber class]] ||
                        [value isKindOfClass:[NSDate class]]) {
                        safeCallbackParameters[key] = value;
                    } else {
                        safeCallbackParameters[key] = [value description];
                    }
                }
            }
            [encoder encodeObject:safeCallbackParameters forKey:@"callbackParameters"];
        }
        
        // Safe number encoding with type checking
        [encoder encodeObject:@(errorCountCopy) forKey:@"errorCount"];
        
        if (firstErrorCodeCopy && [firstErrorCodeCopy isKindOfClass:[NSNumber class]]) {
            [encoder encodeObject:firstErrorCodeCopy forKey:@"firstErrorCode"];
        } else {
            [encoder encodeObject:@0 forKey:@"firstErrorCode"];
        }
        
        if (lastErrorCodeCopy && [lastErrorCodeCopy isKindOfClass:[NSNumber class]]) {
            [encoder encodeObject:lastErrorCodeCopy forKey:@"lastErrorCode"];
        } else {
            [encoder encodeObject:@0 forKey:@"lastErrorCode"];
        }
        
        [encoder encodeObject:@(waitBeforeSendCopy) forKey:@"waitBeforeSend"];
    } @catch (NSException *exception) {
        [ADJAdjustFactory.logger error:@"Failed to encode activity package: %@", exception];
        // Try to save at least basic information
        @try {
            [encoder encodeObject:localPathCopy ?: @"" forKey:@"path"];  // Use local variable
            [encoder encodeObject:@"unknown" forKey:@"kind"];
            [encoder encodeObject:@{} forKey:@"parameters"];
        } @catch (NSException *fallbackException) {
            [ADJAdjustFactory.logger error:@"Failed to encode even basic package data: %@", fallbackException];
        }
    }
}

- (void)dealloc {
    self.propertyLock = nil;
}

@end
