//
//  ADJPackageHandler.m
//  Adjust
//
//  Created by Christian Wellenbrock on 2013-07-03.
//  Copyright (c) 2013 adjust GmbH. All rights reserved.
//

#import "ADJPackageHandler.h"
#import "ADJActivityPackage.h"
#import "ADJLogger.h"
#import "ADJUtil.h"
#import "ADJAdjustFactory.h"
#import "ADJBackoffStrategy.h"
#import "ADJPackageBuilder.h"
#import "ADJUserDefaults.h"
#import "ADJPackageStore.h"

static const char * const kInternalQueueName = "io.adjust.PackageQueue";

#pragma mark - private
@interface ADJPackageHandler()

@property (nonatomic, strong) dispatch_queue_t internalQueue;
@property (nonatomic, strong) ADJRequestHandler *requestHandler;
@property (nonatomic, strong) ADJBackoffStrategy *backoffStrategy;
@property (nonatomic, strong) ADJBackoffStrategy *backoffStrategyForInstallSession;
@property (nonatomic, assign) BOOL paused;
@property (nonatomic, weak) id<ADJActivityHandler> activityHandler;
@property (nonatomic, weak) id<ADJLogger> logger;
@property (nonatomic, assign) NSInteger lastPackageRetriesCount;
@property (nonatomic, assign) BOOL isRetrying;
@property (nonatomic, assign) NSTimeInterval retryStartedAt;
@property (nonatomic, assign) double totalWaitTime;
@property (nonatomic, assign) BOOL isSending;

@end

@implementation ADJPackageHandler

- (id)initWithActivityHandler:(id<ADJActivityHandler>)activityHandler
                startsSending:(BOOL)startsSending
                    userAgent:(NSString *)userAgent
                  urlStrategy:(ADJUrlStrategy *)urlStrategy
{
    self = [super init];
    if (self == nil) return nil;

    self.internalQueue = dispatch_queue_create(kInternalQueueName, DISPATCH_QUEUE_SERIAL);
    self.backoffStrategy = [ADJAdjustFactory packageHandlerBackoffStrategy];
    self.backoffStrategyForInstallSession = [ADJAdjustFactory installSessionBackoffStrategy];
    self.lastPackageRetriesCount = 0;
    self.isRetrying = NO;
    self.totalWaitTime = 0.0;
    self.isSending = NO;

    [ADJUtil launchInQueue:self.internalQueue
                selfInject:self
                     block:^(ADJPackageHandler * selfI) {
        [selfI initI:selfI
     activityHandler:activityHandler
       startsSending:startsSending
           userAgent:userAgent
         urlStrategy:urlStrategy];
    }];

    return self;
}

- (void)addPackage:(ADJActivityPackage *)package {
    [ADJUtil launchInQueue:self.internalQueue
                selfInject:self
                     block:^(ADJPackageHandler* selfI) {
        NSUInteger queueSize = [[ADJPackageStore sharedInstance] count];
        [ADJPackageBuilder parameters:package.parameters
                               setInt:(int)queueSize
                               forKey:@"enqueue_size"];
                               
        if (selfI.isRetrying) {
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            package.waitBeforeSend = selfI.totalWaitTime - (now - selfI.retryStartedAt);
        }
        
        [[ADJPackageStore sharedInstance] addPackage:package];
        
        [selfI.logger debug:@"Added package %d (%@)", queueSize + 1, package];
        [selfI.logger verbose:@"%@", package.extendedString];
    }];
}

- (void)sendFirstPackage {
    [ADJUtil launchInQueue:self.internalQueue
                selfInject:self
                     block:^(ADJPackageHandler* selfI) {
        [selfI sendFirstI:selfI];
    }];
}

- (void)sendFirstI:(ADJPackageHandler *)selfI {
    @try {
        if (selfI.isSending) {
            [selfI.logger verbose:@"Package handler is already sending"];
            return;
        }

        NSUInteger queueSize = [[ADJPackageStore sharedInstance] count];
        if (queueSize == 0) return;

        if (selfI.paused) {
            [selfI.logger debug:@"Package handler is paused"];
            return;
        }

        ADJActivityPackage *activityPackage = [[ADJPackageStore sharedInstance] packageAtIndex:0];
        if (!activityPackage) {
            [selfI.logger error:@"Failed to read activity package"];
            [selfI sendNextI:selfI];
            return;
        }

        selfI.isSending = YES;

        NSMutableDictionary *sendingParameters = [NSMutableDictionary dictionaryWithCapacity:2];
        if (queueSize - 1 > 0) {
            [ADJPackageBuilder parameters:sendingParameters
                                   setInt:(int)queueSize - 1
                                   forKey:@"queue_size"];
        }
        [ADJPackageBuilder parameters:sendingParameters
                            setString:[ADJUtil formatSeconds1970:[NSDate.date timeIntervalSince1970]]
                               forKey:@"sent_at"];

        [ADJPackageBuilder parameters:sendingParameters
                               setInt:(int)activityPackage.errorCount
                               forKey:@"retry_count"];
        [ADJPackageBuilder parameters:sendingParameters
             setNumberWithoutRounding:activityPackage.firstErrorCode
                               forKey:@"first_error"];
        [ADJPackageBuilder parameters:sendingParameters
             setNumberWithoutRounding:activityPackage.lastErrorCode
                               forKey:@"last_error"];
        [ADJPackageBuilder parameters:sendingParameters
                            setDouble:self.totalWaitTime
                               forKey:@"wait_total"];
        [ADJPackageBuilder parameters:sendingParameters
                            setDouble:activityPackage.waitBeforeSend
                               forKey:@"wait_time"];

        [selfI.requestHandler sendPackageByPOST:activityPackage
                              sendingParameters:[sendingParameters copy]];
    } @catch (NSException *ex) {
        [selfI.logger error:@"Exception in sendFirstI: %@", ex];
        selfI.isSending = NO;
    }
}

- (void)responseCallback:(ADJResponseData *)responseData {
    if (responseData.jsonResponse) {
        [self.logger debug:@"Got JSON response with message: %@", responseData.message];
    } else {
        [self.logger error:@"Could not get JSON response with message: %@", responseData.message];
    }
    
    if (responseData.trackingState == ADJTrackingStateOptedOut) {
        [self.activityHandler setTrackingStateOptedOut];
        return;
    }
    
    self.isSending = NO;
    
    if (responseData.jsonResponse == nil) {
        [self closeFirstPackage:responseData];
    } else {
        [self sendNextPackage:responseData];
    }
}

- (void)sendNextPackage:(ADJResponseData *)responseData {
    self.lastPackageRetriesCount = 0;
    self.isRetrying = NO;
    self.retryStartedAt = 0.0;

    [ADJUtil launchInQueue:self.internalQueue
                selfInject:self
                     block:^(ADJPackageHandler* selfI) {
        [selfI sendNextI:selfI];
    }];

    [self.activityHandler finishedTracking:responseData];
}

- (void)sendNextI:(ADJPackageHandler *)selfI {
    if ([[ADJPackageStore sharedInstance] count] > 0) {
        [[ADJPackageStore sharedInstance] removePackageAtIndex:0];
    } else {
        selfI.totalWaitTime = 0.0;
    }

    selfI.isSending = NO;
    [selfI sendFirstI:selfI];
}

- (void)closeFirstPackage:(ADJResponseData *)responseData {
    responseData.willRetry = YES;
    [self.activityHandler finishedTracking:responseData];

    self.lastPackageRetriesCount++;
    
    NSTimeInterval waitTime;
    if (responseData.activityKind == ADJActivityKindSession && [ADJUserDefaults getInstallTracked] == NO) {
        waitTime = [ADJUtil waitingTime:self.lastPackageRetriesCount backoffStrategy:self.backoffStrategyForInstallSession];
    } else {
        waitTime = [ADJUtil waitingTime:self.lastPackageRetriesCount backoffStrategy:self.backoffStrategy];
    }
    
    NSString *waitTimeFormatted = [ADJUtil secondsNumberFormat:waitTime];
    [self.logger verbose:@"Waiting for %@ seconds before retrying the %d time", waitTimeFormatted, self.lastPackageRetriesCount];
    
    self.totalWaitTime += waitTime;
    self.isRetrying = YES;
    self.retryStartedAt = [[NSDate date] timeIntervalSince1970];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(waitTime * NSEC_PER_SEC)), self.internalQueue, ^{
        [self.logger verbose:@"Package handler finished waiting"];
        
        ADJActivityPackage *package = [[ADJPackageStore sharedInstance] packageAtIndex:0];
        if (package) {
            package.waitBeforeSend += waitTime;
            [[ADJPackageStore sharedInstance] updatePackage:package atIndex:0];
        }
        
        [self sendFirstPackage];
    });
}

- (void)pauseSending {
    dispatch_async(self.internalQueue, ^{
        self.paused = YES;
    });
}

- (void)resumeSending {
    self.paused = NO;
}

- (void)updatePackagesWithSessionParams:(ADJSessionParameters *)sessionParameters {
    ADJSessionParameters *sessionParametersCopy = [sessionParameters copy];
    
    [ADJUtil launchInQueue:self.internalQueue
                selfInject:self
                     block:^(ADJPackageHandler* selfI) {
        [[ADJPackageStore sharedInstance] updatePackages:^(ADJActivityPackage *package) {
            NSDictionary *mergedCallbackParameters = [ADJUtil mergeParameters:sessionParametersCopy.callbackParameters
                                                                     source:package.callbackParameters
                                                              parameterName:@"Callback"];
            [ADJPackageBuilder parameters:package.parameters
                          setDictionary:mergedCallbackParameters
                                 forKey:@"callback_params"];

            NSDictionary *mergedPartnerParameters = [ADJUtil mergeParameters:sessionParametersCopy.partnerParameters
                                                                    source:package.partnerParameters
                                                             parameterName:@"Partner"];
            [ADJPackageBuilder parameters:package.parameters
                          setDictionary:mergedPartnerParameters
                                 forKey:@"partner_params"];
        }];
    }];
}

- (void)updatePackagesWithAttStatus:(int)attStatus {
    [ADJUtil launchInQueue:self.internalQueue
                selfInject:self
                     block:^(ADJPackageHandler* selfI) {
        [[ADJPackageStore sharedInstance] updatePackages:^(ADJActivityPackage *package) {
            [ADJPackageBuilder parameters:package.parameters setInt:attStatus forKey:@"att_status"];
            
            [ADJPackageBuilder addConsentDataToParameters:package.parameters
                                        forActivityKind:package.activityKind
                                          withAttStatus:[package.parameters objectForKey:@"att_status"]
                                          configuration:selfI.activityHandler.adjustConfig
                                          packageParams:selfI.activityHandler.packageParams];
        }];
    }];
}

- (void)flush {
    [ADJUtil launchInQueue:self.internalQueue selfInject:self block:^(ADJPackageHandler *selfI) {
        [[ADJPackageStore sharedInstance] clearAllPackages];
    }];
}

- (void)teardown {
    [ADJAdjustFactory.logger verbose:@"ADJPackageHandler teardown"];
    self.internalQueue = nil;
    self.requestHandler = nil;
    self.backoffStrategy = nil;
    self.activityHandler = nil;
    self.logger = nil;
}

+ (void)deleteState {
    [[ADJPackageStore sharedInstance] clearAllPackages];
}

#pragma mark - private
- (void)initI:(ADJPackageHandler *)selfI
activityHandler:(id<ADJActivityHandler>)activityHandler
startsSending:(BOOL)startsSending
    userAgent:(NSString *)userAgent
  urlStrategy:(ADJUrlStrategy *)urlStrategy {
    selfI.activityHandler = activityHandler;
    selfI.paused = !startsSending;
    selfI.requestHandler = [[ADJRequestHandler alloc]
                            initWithResponseCallback:self
                            urlStrategy:urlStrategy
                            userAgent:userAgent
                            requestTimeout:[ADJAdjustFactory requestTimeout]];
    selfI.logger = ADJAdjustFactory.logger;
}

@end
