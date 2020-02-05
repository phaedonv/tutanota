//
//  TUTAlarmManager.m
//  tutanota
//
//  Created by Tutao GmbH on 07.06.19.
//  Copyright © 2019 Tutao GmbH. All rights reserved.
//

#import "TUTAlarmManager.h"
#import "Utils/TUTEncodingConverter.h"
#import "Utils/TUTErrorFactory.h"
#import "Utils/TUTUtils.h"
#import "Utils/TUTLog.h"
#import "Keychain/TUTKeychainManager.h"
#import "Alarms/TUTMissedNotification.h"
#import "Alarms/TUTAlarmModel.h"
#import "Crypto/TUTAes128Facade.h"

#import "Swiftier.h"
#import "PSPDFFastEnumeration.h"

#import <UserNotifications/UserNotifications.h>

NSString *const TUTOperationCreate = @"0";
NSString *const TUTOperationUpdate = @"1";
NSString *const TUTOperationDelete = @"2";

static const int EVENTS_SCHEDULED_AHEAD = 100;
static const long MISSED_NOTIFICATION_TTL_SEC = 30L * 24 * 60 * 60; // 30 days

@interface TUTAlarmManager ()
@property (nonnull, readonly) TUTKeychainManager *keychainManager;
@property (nonnull, readonly) TUTUserPreferenceFacade *userPreference;
@end

@implementation TUTAlarmManager

- (instancetype) initWithUserPreferences:(TUTUserPreferenceFacade *) userPref{
    
    self = [super init];
    if (self) {
        _keychainManager = [TUTKeychainManager new];
        _userPreference = userPref;
    }
    return self;
}


- (void)scheduleAlarms:(TUTMissedNotification*) notificaiton completionsHandler:(void(^)(void))completionHandler {
    dispatch_group_t group = dispatch_group_create();
    
    foreach(alarmNotification, notificaiton.alarmNotifications) {
        dispatch_group_enter(group);
        [self scheduleLocalAlarm:alarmNotification handler: ^(NSError * _Nullable error) {
            if (error) {
                TUTLog(@"schedule error %@", error);
                completionHandler();
            } else {
                TUTLog(@"schedule success");
                
            }
            dispatch_group_leave(group);
        }];
    }
    
    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),^{
        completionHandler();
    });
}

- (void)fetchMissedNotifications:(void(^)(NSError *error))completionHandler {
    let sseInfo = self.userPreference.sseInfo;
    if (!sseInfo){
        TUTLog(@"No stored SSE info");
        completionHandler(nil);
        return;
    }
    
    NSMutableDictionary<NSString *, NSString *> *additionalHeaders = [NSMutableDictionary new];
    additionalHeaders[@"userIds"] = [sseInfo.userIds componentsJoinedByString:@","];
    if (_userPreference.lastProcessedNotificationId) {
        additionalHeaders[@"lastProcessedNotificationId"] = _userPreference.lastProcessedNotificationId;
    }
    let configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPAdditionalHeaders = additionalHeaders;
    
    let urlSession = [NSURLSession sessionWithConfiguration:configuration];
    let urlString = [self missedNotificationUrl:sseInfo.sseOrigin pushIdentifier:sseInfo.pushIdentifier];
    
    [[urlSession dataTaskWithURL:[NSURL URLWithString:urlString] completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        let httpResponse = (NSHTTPURLResponse *) response;
        TUTLog(@"Fetched missed notifications with status code %zd, error: %@", httpResponse.statusCode, error);
        if (error) {
            completionHandler(error);
        } if (httpResponse.statusCode == 404) {
            completionHandler(nil);
        } else if (httpResponse.statusCode != 200) {
            let error = [NSError errorWithDomain:TUT_NETWORK_ERROR
                                            code:httpResponse.statusCode
                                        userInfo:@{@"message": @"Failed to fetch missed notification"}
                         ];
            completionHandler(error);
        } else {
            self.userPreference.lastMissedNotificationCheckTime = [NSDate new];
            NSError *jsonError;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (jsonError) {
                TUTLog(@"Failed to parse response for the missed notification request %@", jsonError);
                return;
            }
            let missedNotification = [TUTMissedNotification fromJSON:json];
            self.userPreference.lastProcessedNotificationId =
            missedNotification.lastProcessedNotificationId;
            
            [self scheduleAlarms:missedNotification completionsHandler:^{
                completionHandler(nil);
            }];
        }
    }] resume];
}

- (BOOL)hasNotificationTTLExpired {
    let lastMissedNotificationCheckTime = _userPreference.lastMissedNotificationCheckTime;
    // Important: timeIntervalSinceNow is negative if it's in the past so we check with "less than"
    return lastMissedNotificationCheckTime && lastMissedNotificationCheckTime.timeIntervalSinceNow < MISSED_NOTIFICATION_TTL_SEC;
}

-(void)resetStoredState {
    TUTLog(@"Resetting current state");
    [self unscheduleAllAlarms];
    [_userPreference clear];
    NSError *error;
    [_keychainManager removePushIdentifierKeys:&error];
    if (error) {
        TUTLog(@"Failed to remove pushIdentifier keys %@", error);
    }
}

-(void)unscheduleAllAlarms {
    let alarms = [_userPreference alarms];
    foreach(alarm, alarms) {
        NSError *error;
        [self unscheduleAlarm:alarm error:&error];
        if (error) {
            TUTLog(@"Error duruing unscheduling of all alarms %@", error);
            error = nil;
        }
    }
    [_userPreference storeAlarms:alarms];
}

- (NSString *)stringToCustomId:(NSString *)string {
    var base64String = [TUTEncodingConverter bytesToBase64:[TUTEncodingConverter stringToBytes:string]];
    base64String = [base64String stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    base64String = [base64String stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    base64String = [base64String stringByReplacingOccurrencesOfString:@"=" withString:@""];
    return base64String;
}

- (NSString *)missedNotificationUrl:(NSString *)origin pushIdentifier:(NSString *)pushIdentifier {
    let base64urlId = [self stringToCustomId:pushIdentifier];
    return [NSString stringWithFormat:@"%@/rest/sys/missednotification/%@", origin, base64urlId];
}

- (void) scheduleLocalAlarm:(TUTAlarmNotification*)alarmNotification handler:(nullable void(^)(NSError *__nullable error))completionHandler {
    let alarmIdentifier = alarmNotification.alarmInfo.alarmIdentifier;
    if ([TUTOperationCreate isEqualToString:alarmNotification.operation] ) {
        var sessionKey = [self resolveSessionKey:alarmNotification];
        if (!sessionKey){
            completionHandler([TUTErrorFactory createError:@"cannot resolve session key"]);
            return;
        }
        
        NSError *error;
        let startDate = [alarmNotification getEventStartDec:sessionKey error:&error];
        let endDate = [alarmNotification getEventEndDec:sessionKey error:&error];
        let trigger = [alarmNotification.alarmInfo getTriggerDec:sessionKey error:&error];
        let repeatRule = alarmNotification.repeatRule;
        let summary = [alarmNotification getSummaryDec:sessionKey error:&error];
        
        if (repeatRule) {
            [self scheduleRepeatingAlarmEventWithTime:startDate
                                             eventEnd:endDate
                                              trigger:trigger
                                              summary:summary
                                      alarmIdentifier:alarmIdentifier
                                           repeatRule:repeatRule
                                           sessionKey:sessionKey
                                                error:&error];
            
            if (!error) {
                [self saveNewAlarm:alarmNotification];
            } else {
                let notificationCenter = UNUserNotificationCenter.currentNotificationCenter;
                let content = [UNMutableNotificationContent new];
                content.title =  [TUTUtils translate:@"TutaoCalendarAlarmTitle" default:@""];
                content.body = @"Could not set up an alarm. Please update the application.";
                content.sound = [UNNotificationSound defaultSound];
                
                let notificationRequest = [UNNotificationRequest requestWithIdentifier:@"parseError" content:content trigger:nil];
                [notificationCenter addNotificationRequest:notificationRequest withCompletionHandler:nil];
            }
        } else {
            [self scheduleAlarmOccurrenceEventWithTime:startDate
                                               trigger:trigger
                                               summary:summary
                                       alarmIdentifier:alarmIdentifier
                                            occurrence:0];
            [self saveNewAlarm:alarmNotification];
        }
        completionHandler(nil);
    } else if ([TUTOperationDelete isEqualToString:alarmNotification.operation]) {
        let savedNotifications = [_userPreference alarms];
        
        TUTAlarmNotification *alarmToUnschedule;
        let index = [savedNotifications indexOfObject:alarmNotification];
        if (index != NSNotFound) {
            alarmToUnschedule = savedNotifications[index];
        } else {
            alarmToUnschedule = alarmNotification;
        }
        NSError *error;
        [self unscheduleAlarm:alarmToUnschedule error:&error];
        if (error) {
            TUTLog(@"Failed to cancel alarm %@ %@", alarmNotification, error);
        }
        
        [savedNotifications removeObject:alarmNotification];
        [_userPreference storeAlarms:savedNotifications];
        completionHandler(nil);
    }
}

- (void)saveNewAlarm:(TUTAlarmNotification *)alarm {
    let savedNotifications = [_userPreference alarms];
    [savedNotifications addObject:alarm];
    [_userPreference storeAlarms:savedNotifications];
}

- (void)unscheduleAlarm:(TUTAlarmNotification *)alarm error:(NSError **)error {
    let notificationCenter = UNUserNotificationCenter.currentNotificationCenter;
    let alarmIdentifier =   alarm.alarmInfo.alarmIdentifier;
    if (alarm.repeatRule) {
        var sessionKey = [self resolveSessionKey:alarm];
        if (!sessionKey) {
            *error = [TUTErrorFactory createError:@"cannot resolve session key"];
            return;
        }
        
        let startDate = [alarm getEventStartDec:sessionKey error:error];
        let endDate = [alarm getEventEndDec:sessionKey error:error];
        let trigger = [alarm.alarmInfo getTriggerDec:sessionKey error:error];
        if (*error) {
            TUTLog(@"Failed to decrypt alarm to unschedule");
            return;
        }
        let repeatRule = alarm.repeatRule;
        NSMutableArray *occurrences = [NSMutableArray new];
        [self iterateRepeatingAlarmtWithTime:startDate
                                    eventEnd:endDate
                                     trigger:trigger
                                  repeatRule:repeatRule
                                  sessionKey:sessionKey
                                       error:error
                                       block:^(NSDate *time, int occurrence, NSDate *occurrenceDate) {
                                           let occurrenceIdentifier = [self occurrenceIdentifier:alarmIdentifier occurrence:occurrence];
                                           [occurrences addObject:occurrenceIdentifier];
                                       }];
        [notificationCenter removePendingNotificationRequestsWithIdentifiers:occurrences];
        TUTLog(@"Cancelling a repeat notification %@", alarmIdentifier);
    } else {
        let occurrenceIdentifier = [self occurrenceIdentifier:alarmIdentifier occurrence:0];
        NSMutableArray *occurrences = [NSMutableArray new];
        [occurrences addObject:occurrenceIdentifier];
        [notificationCenter removePendingNotificationRequestsWithIdentifiers:occurrences];
        TUTLog(@"Cancelling a single notification %@", alarmIdentifier);
    }
}

-(NSData *_Nullable)resolveSessionKey:(TUTAlarmNotification *)alarmNotification {
    NSError *error;
    foreach(notificationSessionKey, alarmNotification.notificationSessionKeys) {
        error = nil;
        let pushIdentifierSessionSessionKey = [_keychainManager getKeyWithError:notificationSessionKey.pushIdentifier.elementId error:&error];
        if (!error && pushIdentifierSessionSessionKey) {
            var encSessionKey = [TUTEncodingConverter base64ToBytes:notificationSessionKey.pushIdentifierSessionEncSessionKey];
            var sessionKey = [TUTAes128Facade decryptKey:encSessionKey
                                       withEncryptionKey:pushIdentifierSessionSessionKey error:&error];
            if (error){
                TUTLog(@"Failed to decrypt key %@ %@", notificationSessionKey.pushIdentifier.elementId, error);
            }
            return sessionKey;
        }
    }
    TUTLog(@"Failed to resolve session key %@, last error: %@", alarmNotification.alarmInfo.alarmIdentifier, error);
    return nil;
}

-(void)scheduleRepeatingAlarmEventWithTime:(NSDate *)eventTime
                                  eventEnd:(NSDate *)eventEnd
                                   trigger:(NSString *)trigger
                                   summary:(NSString *)summary
                           alarmIdentifier:(NSString *)alarmIdentifier
                                repeatRule:(TUTRepeatRule *)repeatRule
                                sessionKey:(NSData *)sessionKey
                                     error:(NSError **)error {
    [self iterateRepeatingAlarmtWithTime:eventTime
                                eventEnd:eventEnd
                                 trigger:trigger
                              repeatRule:repeatRule
                              sessionKey:sessionKey
                                   error:error
                                   block:^(NSDate *time, int occurrence, NSDate *occurrenceDate) {
                                       [self scheduleAlarmOccurrenceEventWithTime:occurrenceDate trigger:trigger summary:summary alarmIdentifier:alarmIdentifier occurrence:occurrence];
                                   }];
}

-(void)iterateRepeatingAlarmtWithTime:(NSDate *)eventTime
                             eventEnd:(NSDate *)eventEnd
                              trigger:(NSString *)trigger
                           repeatRule:(TUTRepeatRule *)repeatRule
                           sessionKey:(NSData *)sessionKey
                                error:(NSError **)error
                                block:(void(^)(NSDate *time, int occurrence, NSDate *occurrenceDate))block {
    
    let cal = NSCalendar.currentCalendar;
    let timeZoneName = [repeatRule getTimezoneDec:sessionKey error:error];
    cal.timeZone = [NSTimeZone timeZoneWithName:timeZoneName];
    
    let frequency = [repeatRule getFrequencyDec:sessionKey error:error];
    let interval = [repeatRule getIntervalDec:sessionKey error:error];
    let endType = [repeatRule getEndTypeDec:sessionKey error:error];
    let endValue = [repeatRule getEndValueDec:sessionKey error:error];
    
    if (*error) {
        TUTLog(@"Could not decrypt repeating alarm %@", *error);
        return;
    }
    
    let now = [NSDate new];
    
    [TUTAlarmModel iterateRepeatingAlarmWithNow:now
                                        timeZone:timeZoneName
                                      eventStart:eventTime
                                       eventEnd:eventEnd
                                   repeatPerioud:frequency
                                        interval:interval
                                         endType:endType
                                        endValue:endValue
                                         trigger:trigger
                                  localTimeZone:NSTimeZone.localTimeZone
                                   scheduleAhead:EVENTS_SCHEDULED_AHEAD
                                           block:block];
}

-(void)scheduleAlarmOccurrenceEventWithTime:(NSDate *)eventTime
                                    trigger:(NSString *)trigger
                                    summary:(NSString *)summary
                            alarmIdentifier:(NSString *)alarmIdentifier
                                 occurrence:(int)occurrence {
    let notificationCenter = UNUserNotificationCenter.currentNotificationCenter;
    if (!summary) {
        summary = @"Calendar event";
    }
    let alarmTime = [TUTAlarmModel alarmTimeWithTrigger:trigger eventTime:eventTime];
    
    let formattedTime = [NSDateFormatter localizedStringFromDate:eventTime dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
    let notificationText = [NSString stringWithFormat:@"%@: %@", formattedTime, summary];
    
    unsigned unitFlags = NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute;
    
    let cal = [NSCalendar currentCalendar];
    let dateComponents = [cal components:unitFlags fromDate:alarmTime];
    
    let notificationTrigger = [UNCalendarNotificationTrigger triggerWithDateMatchingComponents:dateComponents repeats:NO];
    
    let content = [UNMutableNotificationContent new];
    content.title =  [TUTUtils translate:@"TutaoCalendarAlarmTitle" default:@"Calendar reminder"];
    content.body = notificationText;
    content.sound = [UNNotificationSound defaultSound];
    
    // Create the request
    let identifier = [self occurrenceIdentifier:alarmIdentifier occurrence:occurrence];
    let request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:notificationTrigger];
    // Schedule the request with the system.
    TUTLog(@"Scheduling a notification %@ at: %@", identifier, dateComponents);
    [notificationCenter addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            TUTLog(@"Failed to schedule a notification: %@", error);
        }
    }];
}



-(NSString *)occurrenceIdentifier:(NSString *)alarmIdentifier occurrence:(int)occurrence {
    return [NSString stringWithFormat:@"%@#%d", alarmIdentifier, occurrence];
}

-(void)rescheduleEvents {
    TUTLog(@"Re-scheduling alarms");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        let savedNotifications = [self->_userPreference alarms];
        foreach(notification, savedNotifications) {
            NSError *error;
            let sessionKey = [self resolveSessionKey:notification];
            let alarmIdentifier = notification.alarmInfo.alarmIdentifier;
            if (!sessionKey) {
                TUTLog(@"Failed to rsolve session key for notification %@", alarmIdentifier);
                continue;
            }
            
            let startDate = [notification getEventStartDec:sessionKey error:&error];
            let endDate = [notification getEventEndDec:sessionKey error:&error];
            let trigger = [notification.alarmInfo getTriggerDec:sessionKey error:&error];
            let repeatRule = notification.repeatRule;
            let summary = [notification getSummaryDec:sessionKey error:&error];
            if (error) {
                TUTLog(@"Failed to decrypt notification %@ %@", alarmIdentifier, error);
                continue;
            }
            [self scheduleRepeatingAlarmEventWithTime:startDate
                                             eventEnd:endDate
                                              trigger:trigger
                                              summary:summary
                                      alarmIdentifier:alarmIdentifier
                                           repeatRule:repeatRule
                                           sessionKey:sessionKey
                                                error:&error];
        }
    });
}

@end
