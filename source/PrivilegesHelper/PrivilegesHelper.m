/*
 PrivilegesHelper.m
 Copyright 2016-2022 SAP SE

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "PrivilegesHelper.h"
#include <AppKit/AppKit.h>
#import "MTAuthCommon.h"
#import "Constants.h"
#import "MTIdentity.h"
#import "MTSyslog.h"
#import <CoreServices/CoreServices.h>
#import <Collaboration/Collaboration.h>
#import <errno.h>
#import <os/log.h>
#import <IOKit/IOKitLib.h>

@interface PrivilegesHelper () <NSXPCListenerDelegate, HelperToolProtocol>
@property (atomic, strong, readwrite) NSXPCListener *listener;
@property (atomic, strong, readwrite) MTSyslog *syslogServer;
@property (atomic, assign) BOOL shouldTerminate;
@property (atomic, assign) BOOL networkOperation;
@end

@interface ExtendedNSXPCConnection : NSXPCConnection
@property audit_token_t auditToken;
@end

OSStatus SecTaskValidateForRequirement(SecTaskRef task, CFStringRef requirement);

@implementation PrivilegesHelper

- (id)init
{
    self = [super init];
    if (self != nil) {

        // Set up our XPC listener to handle requests on our Mach service.
        self->_listener = [[NSXPCListener alloc] initWithMachServiceName:kHelperToolMachServiceName];
        [self->_listener setDelegate:self];
    }

    return self;
}

- (void)run
{
    // Tell the XPC listener to start processing requests.
    [_listener resume];

    // run until _shouldTerminate is true and network operations have been finished
    while (!(_shouldTerminate && !_networkOperation)) { [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:20.0]]; }
}

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection
// Called by our XPC listener when a new connection comes in.  We configure the connection
// with our protocol and ourselves as the main object.
{
    assert(listener == _listener);
#pragma unused(listener)
    assert(newConnection != nil);

    BOOL acceptConnection = NO;

// Skip code signature verification in DEBUG mode
#ifdef DEBUG
    acceptConnection = YES;

    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(HelperToolProtocol)];
    newConnection.exportedObject = self;
    [newConnection resume];

    return acceptConnection;
#endif

    // see how we have been signed and make sure only processes with the same signing authority can connect.
    // additionally the calling application must have the same version number as this helper and must be one
    // of the components using a bundle identifier starting with "com.ripeda.privileges"
    NSError *error = nil;
    NSString *signingAuth = [MTAuthCommon getSigningAuthorityWithError:&error];
    NSString *requiredVersion = [self helperVersion];

    if (signingAuth) {
        NSString *reqString = [NSString stringWithFormat:@"anchor trusted and certificate leaf [subject.CN] = \"%@\" and info [CFBundleShortVersionString] >= \"%@\" and info [CFBundleIdentifier] = com.ripeda.privileges*", signingAuth, requiredVersion];
        SecTaskRef taskRef = SecTaskCreateWithAuditToken(NULL, ((ExtendedNSXPCConnection*)newConnection).auditToken);

        if (taskRef) {

            if (SecTaskValidateForRequirement(taskRef, (__bridge CFStringRef)(reqString)) == errSecSuccess) {
                acceptConnection = YES;

                newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(HelperToolProtocol)];
                newConnection.exportedObject = self;
                [newConnection resume];

            } else {
                os_log(OS_LOG_DEFAULT, "RIPEDA: ERROR! Code signature verification failed");
            }

            CFRelease(taskRef);
        }

    } else {
        os_log(OS_LOG_DEFAULT, "RIPEDA: ERROR! Failed to get code signature: %{public}@", error);
    }

    return acceptConnection;
}

- (NSError *)checkAuthorization:(NSData *)authData command:(SEL)command
// Check that the client denoted by authData is allowed to run the specified command.
{
#pragma unused(authData)
    NSError *error;
    OSStatus err;
    OSStatus junk;
    AuthorizationRef authRef;

    assert(command != nil);

    authRef = NULL;

    // First check that authData looks reasonable.
    error = nil;
    if ( (authData == nil) || ([authData length] != sizeof(AuthorizationExternalForm)) ) {
        error = [NSError errorWithDomain:NSOSStatusErrorDomain code:paramErr userInfo:nil];
    }

    // Create an authorization ref from that the external form data contained within.

    if (error == nil) {
        err = AuthorizationCreateFromExternalForm([authData bytes], &authRef);

        // Authorize the right associated with the command.

        if (err == errAuthorizationSuccess) {
            AuthorizationItem   oneRight = { NULL, 0, NULL, 0 };
            AuthorizationRights rights   = { 1, &oneRight };

            oneRight.name = [[MTAuthCommon authorizationRightForCommand:command] UTF8String];
            assert(oneRight.name != NULL);

            err = AuthorizationCopyRights(
                                          authRef,
                                          &rights,
                                          NULL,
                                          kAuthorizationFlagExtendRights | kAuthorizationFlagInteractionAllowed,
                                          NULL
                                          );
        }
        if (err != errAuthorizationSuccess) {
            error = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:nil];
        }
    }

    if (authRef != NULL) {
        junk = AuthorizationFree(authRef, 0);
        assert(junk == errAuthorizationSuccess);
    }

    return error;
}

#pragma mark *HelperToolProtocol implementation

// IMPORTANT: NSXPCConnection can call these methods on any thread.  It turns out that our
// implementation of these methods is thread safe but if that's not the case for your code
// you have to implement your own protection (for example, having your own serial queue and
// dispatching over to it).

- (void)connectWithEndpointReply:(void (^)(NSXPCListenerEndpoint *))reply
    // Part of the HelperToolProtocol.  Not used by the standard app (it's part of the sandboxed
    // XPC service support).  Called by the XPC service to get an endpoint for our listener.  It then
    // passes this endpoint to the app so that the sandboxed app can talk us directly.
{
    reply([self.listener endpoint]);
}

- (void)helperVersionWithReply:(void(^)(NSString *version))reply
{
    reply([self helperVersion]);
}

- (NSString*)helperVersion
{
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
}

// Check if server is up
- (BOOL)checkServer
{
    __block BOOL serverUp = NO;

    // Check if server is up
    NSUserDefaults *userDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.ripeda.privileges"];
    NSDictionary *remoteLogging = [userDefaults dictionaryForKey:kMTDefaultsRemoteLogging];

    if (!remoteLogging) {
        os_log(OS_LOG_DEFAULT, "RIPEDA: ERROR! Remote logging not configured, treating as online");
        return YES;
    }

    NSWindow *
    __block myWindow = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        // Create window saying we're checking server status
        myWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 350, 200)
                                            styleMask:NSWindowStyleMaskTitled
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
        [myWindow setTitle:@"Privileges"];
        [myWindow setReleasedWhenClosed:NO];
        [myWindow center];
        [myWindow makeKeyAndOrderFront:nil];

        // Set icon
        NSImage *icon = [[NSImage alloc] initWithContentsOfFile:@"/Applications/Privileges.app/Contents/Resources/AppIcon.icns"];
        NSImageView *imageView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 96, 96)];
        [imageView setImage:icon];

        // Calculate the position to center the image vertically
        CGFloat windowContentHeight = myWindow.contentView.frame.size.height;
        CGFloat imageHeight = imageView.frame.size.height;
        CGFloat verticalOffset = (windowContentHeight - imageHeight) / 2.0 + 30;

        // Set the frame of the image view to align it to the top and center
        NSRect imageFrame = imageView.frame;
        imageFrame.origin.y = verticalOffset;
        imageFrame.origin.x = 127;
        [imageView setFrame:imageFrame];

        [myWindow.contentView addSubview:imageView];


        // Add text: Checking server status
        NSTextField *checkingServerStatus = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 350, 20)];
        [checkingServerStatus setStringValue:@"Checking server status..."];
        [checkingServerStatus setEditable:NO];
        [checkingServerStatus setBordered:NO];
        [checkingServerStatus setDrawsBackground:NO];
        [checkingServerStatus setAlignment:NSTextAlignmentCenter];
        [checkingServerStatus setFont:[NSFont systemFontOfSize:18]];

        // Calculate the position to center the text vertically
        CGFloat checkingServerStatusHeight = checkingServerStatus.frame.size.height;
        CGFloat verticalOffset2 = (windowContentHeight - checkingServerStatusHeight) / 2.0 - 40;

        // Set the frame of the text to align it to the top and center
        NSRect checkingServerStatusFrame = checkingServerStatus.frame;
        checkingServerStatusFrame.origin.y = verticalOffset2;
        [checkingServerStatus setFrame:checkingServerStatusFrame];

        [myWindow.contentView addSubview:checkingServerStatus];


        // Add progress bar, pulsing
        NSProgressIndicator *progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 250, 20)];
        [progressBar setIndeterminate:YES];
        [progressBar startAnimation:nil];

        // Calculate the position to center the progress bar vertically
        CGFloat progressBarHeight = progressBar.frame.size.height;
        CGFloat verticalOffset3 = (windowContentHeight - progressBarHeight) / 2.0 - 70;

        // Set the frame of the progress bar to align it to the top and center
        NSRect progressBarFrame = progressBar.frame;
        progressBarFrame.origin.y = verticalOffset3;
        progressBarFrame.origin.x = 50;
        [progressBar setFrame:progressBarFrame];

        [myWindow.contentView addSubview:progressBar];

    });


#ifdef DEBUG
    /*
        Allow tester to override this check with the presence of a file
        Ensure standard users can touch it, as otherwise they'd be locked out
    */
    NSString *testFile = @"/Users/Shared/.ripeda_lock_override";
    if ([[NSFileManager defaultManager] fileExistsAtPath:testFile]) {
        // Dismiss prompt
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSApp modalWindow] close];
        });

        return YES;
    }
#endif

    NSString *serverType = [remoteLogging objectForKey:kMTDefaultsRLServerType];
    NSString *serverAddress = [remoteLogging objectForKey:kMTDefaultsRLServerAddress];
    NSInteger serverPort = [[remoteLogging objectForKey:kMTDefaultsRLServerPort] integerValue];

    if (serverType && serverAddress) {

        if ([[serverType lowercaseString] isEqualToString:@"http"] || [[serverType lowercaseString] isEqualToString:@"https"]) {

            // Check if server is up
            NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@:%ld", serverType, serverAddress, (long)serverPort]];
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
            [request setHTTPMethod:@"HEAD"];

            NSURLSession *session = [NSURLSession sharedSession];
            session.configuration.timeoutIntervalForRequest = 3.0;
            NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

                if (error) {
                    os_log(OS_LOG_DEFAULT, "RIPEDA: ERROR! Server is down: %{public}@", error);
                    serverUp = NO;
                } else {
                    os_log(OS_LOG_DEFAULT, "RIPEDA: Server is up");
                    serverUp = YES;
                }
            }];

            [task resume];

            while (task.state == NSURLSessionTaskStateRunning) {
                sleep(1);
            }

        } else {
            // Unknown server type
            os_log(OS_LOG_DEFAULT, "RIPEDA: ERROR! Server status only supported on HTTP/HTTPS, treating as online");
            dispatch_async(dispatch_get_main_queue(), ^{
                [myWindow close];
            });

            return YES;
        }


    } else {
        // No server configured
        os_log(OS_LOG_DEFAULT, "RIPEDA: ERROR! No server configured, treating as online");
        dispatch_async(dispatch_get_main_queue(), ^{
            [myWindow close];
        });

        return YES;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [myWindow close];
    });

    return serverUp;
}

- (BOOL)isUserExempted:(NSString*)userName
{
    NSUserDefaults *userDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.ripeda.privileges"];
    NSArray *exemptedUsers = [userDefaults objectForKey:kMTDefaultsExcludeUsers];

    for (NSString *exemptedUser in exemptedUsers) {
        if ([userName isEqualToString:exemptedUser]) {
            return YES;
        }
    }

    return NO;
}


- (void)changeAdminRightsForUser:(NSString*)userName
                          remove:(BOOL)remove
                          reason:(NSString*)reason
                   authorization:(NSData*)authData
                       withReply:(void(^)(NSError *error))reply
{
    NSString *errorMsg = nil;
    NSError *error = [self checkAuthorization:authData command:_cmd];


    if (!remove && !error) {
        os_log(OS_LOG_DEFAULT, "RIPEDA: Elevating user: %{public}@, verifying server connection", userName);
        // Call server to see if it's online
        // Only allow users to be elevated if the server is online
        if ([self checkServer] == NO) {
            errorMsg = @"Server is down, cannot elevate user";
            error = [NSError errorWithDomain:NSOSStatusErrorDomain code:errAuthorizationDenied userInfo:@{NSLocalizedDescriptionKey: errorMsg}];

            // Display alert to user
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *alert = [[NSAlert alloc] init];
                [alert addButtonWithTitle:@"OK"];
                [alert setMessageText:errorMsg];
                [alert setInformativeText:@"Please try again later."];
                [alert setAlertStyle:NSAlertStyleWarning];
                NSImage *icon = [[NSImage alloc] initWithContentsOfFile:@"/Applications/Privileges.app/Contents/Resources/AppIcon.icns"];
                [alert setIcon:icon];
                [alert runModal];
            });
        }
    }


    if (!error) {

        if (userName) {

            // get the user identity
            CBIdentity *userIdentity = [CBIdentity identityWithName:userName
                                                          authority:[CBIdentityAuthority defaultIdentityAuthority]];

            if (userIdentity) {

                // get the group identity
                CBGroupIdentity *groupIdentity = [CBGroupIdentity groupIdentityWithPosixGID:kMTAdminGroupID
                                                                                  authority:[CBIdentityAuthority localIdentityAuthority]];

                if (groupIdentity) {

                    CSIdentityRef csUserIdentity = [userIdentity CSIdentity];
                    CSIdentityRef csGroupIdentity = [groupIdentity CSIdentity];

                    // add or remove the user to/from the group
                    if (remove) {
                        if ([self isUserExempted:userName]) {
                            errorMsg = @"User is an exempted account, cannot remove";
                            error = [NSError errorWithDomain:NSOSStatusErrorDomain code:errAuthorizationDenied userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
                        } else {
                            CSIdentityRemoveMember(csGroupIdentity, csUserIdentity);
                        }
                    } else {
                        CSIdentityAddMember(csGroupIdentity, csUserIdentity);
                    }

                    // commit changes to the identity store to update the group
                    if (CSIdentityCommit(csGroupIdentity, NULL, NULL)) {

                        // re-check the group membership. this seems to update some caches or so. without this re-checking
                        // sometimes the system does not recognize the changes of the group membership instantly.
                        [MTIdentity getGroupMembershipForUser:userName groupID:kMTAdminGroupID error:nil];

                        // log the privilege change
                        NSString *logMessage = [NSString stringWithFormat:@"RIPEDA: User %@ has now %@ rights", userName, (remove) ? @"standard user" : @"admin"];
                        if ([reason length] > 0) { logMessage = [logMessage stringByAppendingFormat:@" for the following reason: %@", reason]; }
                        os_log(OS_LOG_DEFAULT, "%{public}@", logMessage);

                        // if remote logging has been configured, we send the log message to the remote
                        // logging server as well
                        NSUserDefaults *userDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.ripeda.privileges"];

                        if ([userDefaults objectIsForcedForKey:kMTDefaultsRemoteLogging]) {

                            // get the required configuration data
                            NSDictionary *remoteLogging = [userDefaults dictionaryForKey:kMTDefaultsRemoteLogging];
                            NSString *serverType = [remoteLogging objectForKey:kMTDefaultsRLServerType];
                            NSString *serverAddress = [remoteLogging objectForKey:kMTDefaultsRLServerAddress];

                            os_log(OS_LOG_DEFAULT, "RIPEDA: Remote logging is enabled. Server type: %{public}@, server address: %{public}@", serverType, serverAddress);

                            if ([[serverType lowercaseString] isEqualToString:@"syslog"] && serverAddress) {
                                NSInteger serverPort = [[remoteLogging objectForKey:kMTDefaultsRLServerPort] integerValue];
                                BOOL enableTCP = [[remoteLogging objectForKey:kMTDefaultsRLEnableTCP] boolValue];
                                NSDictionary *syslogOptions = [remoteLogging objectForKey:kMTDefaultsRLSyslogOptions];
                                NSUInteger logFacility = ([syslogOptions objectForKey:kMTDefaultsRLSyslogFacility]) ? [[syslogOptions valueForKey:kMTDefaultsRLSyslogFacility] integerValue] : MTSyslogMessageFacilityAuth;
                                NSUInteger logSeverity = ([syslogOptions objectForKey:kMTDefaultsRLSyslogSeverity]) ? [[syslogOptions valueForKey:kMTDefaultsRLSyslogSeverity] integerValue] : MTSyslogMessageSeverityInformational;
                                NSUInteger maxSize = ([syslogOptions objectForKey:kMTDefaultsRLSyslogMaxSize]) ? [[syslogOptions valueForKey:kMTDefaultsRLSyslogMaxSize] integerValue] : 0;

                                MTSyslogMessage *message = [[MTSyslogMessage alloc] init];
                                [message setFacility:logFacility];
                                [message setSeverity:logSeverity];
                                [message setAppName:@"Privileges"];
                                [message setMessageId:(remove) ? @"PRIV_S" : @"PRIV_A"];
                                if (maxSize > MTSyslogMessageMaxSize480) { [message setMaxSize:maxSize]; }
                                [message setEventMessage:logMessage];

                                _syslogServer = [[MTSyslog alloc] initWithServerAddress:serverAddress
                                                                             serverPort:(serverPort > 0) ? serverPort : 514
                                                                            andProtocol:(enableTCP) ? MTSocketTransportLayerProtocolTCP : MTSocketTransportLayerProtocolUDP
                                                          ];

                                _networkOperation = YES;
                                [_syslogServer sendMessage:message completionHandler:^(NSError *networkError) {

                                    if (networkError) {
                                        os_log(OS_LOG_DEFAULT, "RIPEDA: ERROR! Remote logging failed: %{public}@", networkError);
                                    }

                                    dispatch_async(dispatch_get_main_queue(), ^{ self->_networkOperation = NO; });
                                }];
                            } else if (([[serverType lowercaseString] isEqualToString:@"http"] ||  [[serverType lowercaseString] isEqualToString:@"https"]) && serverAddress) {
                                /**
                                Implement a basic HTTP/HTTPS client to send a json-encoded message to the remote logging server
                                **/

                                NSInteger serverPort = [[remoteLogging objectForKey:kMTDefaultsRLServerPort] integerValue];

                                // Generate the json data using createJsonDictionaryForLoggingServer
                                NSDictionary *jsonDictionary = [self createJsonDictionaryForLoggingServer:userName remove:remove reason:reason];
                                NSError *jsonError = nil;
                                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonDictionary options:NSJSONWritingPrettyPrinted error:&jsonError];

                                // create url
                                NSString *serverURL = [NSString stringWithFormat:@"%@://%@:%ld", serverType, serverAddress, (serverPort > 0) ? serverPort : (([[serverType lowercaseString] isEqualToString:@"http"]) ? 80 : 443)];

                                // create the request
                                NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:serverURL]];
                                [request setHTTPMethod:@"POST"];
                                [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
                                [request setHTTPBody:jsonData];

                                os_log(OS_LOG_DEFAULT, "RIPEDA: Remote logging request: %{public}@", request);

                                // send the request
                                _networkOperation = YES;
                                NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {

                                    if (networkError) {
                                        os_log(OS_LOG_DEFAULT, "RIPEDA: ERROR! Remote logging failed: %{public}@", networkError);
                                    }

                                    dispatch_async(dispatch_get_main_queue(), ^{ self->_networkOperation = NO; });
                                }];

                                [task resume];

                            } else {
                                os_log(OS_LOG_DEFAULT, "RIPEDA: ERROR! Remote logging is misconfigured");
                            }
                        }

                    } else {
                        errorMsg = @"Identity could not be committed to the authority database";
                    }

                }  else {
                    errorMsg = @"Missing group identity";
                }

            }  else {
                errorMsg = @"Missing user identity";
            }

        }  else {
            errorMsg = @"User name is missing";
        }

    } else {
         errorMsg = @"Authorization check failed";
    }

    if ([errorMsg length] > 0) {
        NSDictionary *errorDetail = [NSDictionary dictionaryWithObjectsAndKeys:errorMsg, NSLocalizedDescriptionKey, nil];
        error = [NSError errorWithDomain:@"com.ripeda.privileges" code:100 userInfo:errorDetail];
    }

    reply(error);
}


/*
    Funtion that creates a json dictionary for logging server
    Takes following inputs:
    - userName: user name of the user
    - remove: boolean value that indicates if the user is being removed or added
    - reason: reason for the change

    Returns a json dictionary with following properties:
    {
        "message": "RIPEDA: User <user name> has now <standard/elevated> rights",
        "reason": "<reason for the change>",
        "isElevated": <true/false>,
        "username": "<user name>",
        "timestamp": "<timestamp>",
        "hostname": "<hostname>",
        "machineId": "<machine id>",
        "machineName": "<machine name>",
        "serialNumber": "<serial number>"
        "clientName": "<client name>"
    }
*/
- (NSDictionary *)createJsonDictionaryForLoggingServer:(NSString *)userName remove:(BOOL)remove reason:(NSString *)reason
{
    NSMutableDictionary *jsonDict = [NSMutableDictionary dictionary];

    // "message"
    NSString *logMessage = [NSString stringWithFormat:@"RIPEDA: User %@ has now %@ rights", userName, (remove) ? @"standard" : @"elevated"];
    [jsonDict setObject:logMessage forKey:@"message"];
    // "reason"
    if ([reason length] > 0) { [jsonDict setObject:reason forKey:@"reason"]; }
    // "isElevated"
    [jsonDict setObject:[NSNumber numberWithBool:!remove] forKey:@"isElevated"];
    // "username"
    [jsonDict setObject:userName forKey:@"username"];
    // "timestamp"
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZZZZZ"];
    NSString *timeStamp = [dateFormatter stringFromDate:[NSDate date]];
    [jsonDict setObject:timeStamp forKey:@"timestamp"];
    // "hostname"
    NSString *hostName = [[NSHost currentHost] localizedName];
    if ([hostName length] > 0) { [jsonDict setObject:hostName forKey:@"hostname"]; }
    // "machineId"
    NSString *machineId = [[NSUUID UUID] UUIDString];
    if ([machineId length] > 0) { [jsonDict setObject:machineId forKey:@"machineId"]; }
    // "machineName"
    NSString *machineName = [[NSHost currentHost] localizedName];
    if ([machineName length] > 0) { [jsonDict setObject:machineName forKey:@"machineName"]; }
    // "serialNumber"
    NSString *serialNumber = [self getSerialNumber];
    if ([serialNumber length] > 0) { [jsonDict setObject:serialNumber forKey:@"serialNumber"]; }
    // "clientName"
    NSString *clientName = [self getClientName];
    if ([clientName length] > 0) { [jsonDict setObject:clientName forKey:@"clientName"]; }

    return jsonDict;
}

// Ref: https://stackoverflow.com/a/15451318
- (NSString *)getSerialNumber
{
    NSString *serial = nil;
    io_service_t platformExpert = IOServiceGetMatchingService(kIOMasterPortDefault,
                                     IOServiceMatching("IOPlatformExpertDevice"));
    if (platformExpert) {
        CFTypeRef serialNumberAsCFString =
        IORegistryEntryCreateCFProperty(platformExpert,
                                        CFSTR(kIOPlatformSerialNumberKey),
                                        kCFAllocatorDefault, 0);
        if (serialNumberAsCFString) {
            serial = CFBridgingRelease(serialNumberAsCFString);
        }

        IOObjectRelease(platformExpert);
    }
    return serial;
}

- (NSString *)getClientName
{
    /*
        Call 'profiles' and fetch the profile with description:
        - ProfileDescription = 'Elegant Apple device management with SimpleMDM'

        The profile's display name will be that of the client's:
        - ProfileDisplayName = 'R&D - RIPEDA Profile'
    */

    NSString *clientName = nil;

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/profiles"];
    [task setArguments:[NSArray arrayWithObjects:@"list", @"-output", @"stdout-xml", nil]];

    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];

    NSFileHandle *file = [pipe fileHandleForReading];

    [task launch];

    NSData *data = [file readDataToEndOfFile];

    [task waitUntilExit];

    if ([task terminationStatus] == 0) {
        // Load output as plist
        NSError *error;
        NSPropertyListFormat format;
        NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:&format error:&error];

        if (plist) {
            NSArray *profiles = [plist objectForKey:@"_computerlevel"];
            for (NSDictionary *profile in profiles) {
                NSString *profileDescription = [profile objectForKey:@"ProfileDescription"];
                if ([profileDescription isEqualToString:@"Elegant Apple device management with SimpleMDM"]) {
                    clientName = [profile objectForKey:@"ProfileDisplayName"];
                    break;
                }
            }
        }
    }

    // If client name ends with ' Profile', strip it
    if ([clientName length] > 0) {
        if ([clientName hasSuffix:@" Profile"] || [clientName hasSuffix:@" profile"]) {
            clientName = [clientName substringToIndex:[clientName length] - 8];
        }
    }

    return clientName;
}

- (void)quitHelperTool
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_shouldTerminate = YES;
    });
}

@end
