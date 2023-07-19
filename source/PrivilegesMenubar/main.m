//
//  main.m
//  PrivilegesMenubar
//
//  Created by Mykola Grymalyuk on 2023-07-18.
//  Copyright © 2023 RIPEDA Consulting Corporation. All rights reserved.
//

#include <AppKit/AppKit.h>
#include <Foundation/Foundation.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) NSStatusItem *statusItem;

@property (nonatomic, strong) NSMenuItem *currentStatusItem;
@property (nonatomic, strong) NSMenuItem *toggleStatusItem;

@property (nonatomic, strong) NSImage *iconUnlocked;
@property (nonatomic, strong) NSImage *iconLocked;

@property (nonatomic, strong) NSTimer *demoteTimer;
@property (nonatomic, strong) NSTimer *labelTimer;

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self setupMenubar];
    [self listenForStatusChange];
    [self demotePrivileges];
    [self syncStatus];
}

- (BOOL)checkCurrentUserStatus {
    /*
        Check if user is admin/standard user, update status item accordingly
        Note that PrivilegesCLI outputs to STDERR, so we need to capture that
    */

    BOOL isAdmin = YES;

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/Applications/Privileges.app/Contents/Resources/PrivilegesCLI"];
    [task setArguments:@[@"--status"]];

    NSPipe *pipe = [NSPipe pipe];
    [task setStandardError:pipe];

    NSFileHandle *file = [pipe fileHandleForReading];

    [task launch];
    [task waitUntilExit];

    NSData *data = [file readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    if ([output containsString:@"has standard user rights"]) {
        isAdmin = NO;
    }

    return isAdmin;
}

- (int)fetchTimeout {
    /*
        Fetch configured timeout (in seconds)
    */

    int timeout = 60 * 5;

    NSString *plistPath = @"/Library/Managed Preferences/com.ripeda.privileges.plist";
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];

    if ([plist objectForKey:@"TimerLength"]) {
        timeout = [[plist objectForKey:@"TimerLength"] intValue];
    }

    return timeout;
}

- (void)syncStatus {
    /*
        Sync the status item with the current user status
    */

    if ([self checkCurrentUserStatus]) {
        [self.currentStatusItem setTitle:@"Current status: Admin"];
        [self.toggleStatusItem  setTitle:@"Return to Standard user"];
        [self.statusItem.button setImage:self.iconUnlocked];
        [self demoteAfterTimeout];
    } else {
        [self.currentStatusItem setTitle:@"Current status: Standard User"];
        [self.toggleStatusItem  setTitle:@"Request Admin Privileges"];
        [self.statusItem.button setImage:self.iconLocked];
        [self.statusItem.button setTitle:@""];
        [self invalidateTimer];
    }
}

- (void)demoteAfterTimeout {
    /*
        Demote privileges after specified timeout (in seconds)
    */

    if (self.demoteTimer.isValid) {
        return;
    }

    self.demoteTimer = [NSTimer scheduledTimerWithTimeInterval:[self fetchTimeout]
                                                  target:self
                                                selector:@selector(demotePrivileges)
                                                userInfo:nil
                                                 repeats:NO];

    [self updateTimerLabel];
    self.labelTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                     target:self
                                   selector:@selector(updateTimerLabel)
                                   userInfo:nil
                                    repeats:YES];

}

// Convert seconds to readable time
- (NSString *)timeFormatted:(int)totalSeconds {
    /*
        Convert seconds to readable time
    */

    int seconds = totalSeconds % 60;
    int minutes = (totalSeconds / 60) % 60;

    return [NSString stringWithFormat:@"%02d:%02d", minutes, seconds];
}

- (void)invalidateTimer {
    /*
        Invalidate timer
    */

    [self.demoteTimer invalidate];
    [self.labelTimer invalidate];
}


- (void)updateTimerLabel {
    /*
        Update the time left label
    */

    if (!self.demoteTimer.isValid || !self.demoteTimer) {
        [self.statusItem.button setTitle:@""];
        return;
    }

    if (self.demoteTimer.fireDate.timeIntervalSinceNow < 0) {
        [self demotePrivileges];
        return;
    }

    NSString *timeLeft = [self timeFormatted:self.demoteTimer.fireDate.timeIntervalSinceNow];
    [self.statusItem.button setTitle:timeLeft];
}

- (void)listenForStatusChange {
    /*
        Listen for '@"com.ripeda.PrivilegesChanged"' notification
    */

        [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                            selector:@selector(syncStatus)
                                                                name:@"com.ripeda.PrivilegesChanged"
                                                            object:nil];

}

- (void)togglePrivileges {
    /*
        Toggle privileges
    */

    NSTask *task = [[NSTask alloc] init];

    [task setLaunchPath:@"/Applications/Privileges.app/Contents/MacOS/Privileges"];

    [task launch];
}

- (void)demotePrivileges {
    /*
        Demote privileges
    */

    NSTask *task = [[NSTask alloc] init];

    [task setLaunchPath:@"/Applications/Privileges.app/Contents/Resources/PrivilegesCLI"];
    [task setArguments:@[@"--remove"]];

    [task launch];
}

- (void)setupMenubar {
    // Create the status item
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];

    self.iconLocked = [NSImage imageNamed:@"MenubarIconLockedTemplate"];
    self.iconUnlocked = [NSImage imageNamed:@"MenubarIconUnlockedTemplate"];

    [self.iconLocked setSize:NSMakeSize(20, 20)];
    [self.iconUnlocked setSize:NSMakeSize(20, 20)];

    [self.statusItem.button setImage:self.iconLocked];

    // Create the menu
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Menu"];

    // Description
    NSArray *description = @[
        @"Privileges:",
        @"  Allows you to request admin privileges",
        @"  for a limited amount of time.",
    ];

    for (NSString *menuItem in description) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:menuItem action:nil keyEquivalent:@""];
        [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];

    NSArray *greatPower = @[
        @"With great power comes great responsibility.",
        @"  - Uncle Ben",
    ];
    for (NSString *menuItem in greatPower) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:menuItem action:nil keyEquivalent:@""];
        [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];


    // Current status
    self.currentStatusItem = [[NSMenuItem alloc] initWithTitle:@"Current status: Unknown" action:nil keyEquivalent:@""];
    [menu addItem:self.currentStatusItem];
    [menu addItem:[NSMenuItem separatorItem]];

    // Toggle privileges
    self.toggleStatusItem = [[NSMenuItem alloc] initWithTitle:@"Toggle privileges" action:@selector(togglePrivileges) keyEquivalent:@""];
    [menu addItem:self.toggleStatusItem];
    [menu addItem:[NSMenuItem separatorItem]];

    // Set the menu for the status item
    self.statusItem.menu = menu;
}

@end

int main(int argc, const char * argv[]) {
    // Create the application
    NSApplication *application = [NSApplication sharedApplication];

    // Create the app delegate
    AppDelegate *appDelegate = [[AppDelegate alloc] init];
    [application setDelegate:appDelegate];

    [application run];

    return 0;
}
