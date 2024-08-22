//
//  main.m
//  ProtonDriveMac
//
//  Created by Robert Patchett on 02.07.22.
//  Copyright © 2022 ProtonMail. All rights reserved.
//

#import <Cocoa/Cocoa.h>

void runAppUsingAppDelegateStub(NSString *);

int main(int argc, char *argv[])
{
    // Prevents the host app from running during test runs but still allows access to the app's APIs
    // from test bundles
    NSString *unitTestsAppDelegateClassName = @"ProtonDriveMacUnitTests.AppDelegateStub";
    NSString *integrationTestsAppDelegateClassName = @"ProtonDriveMacIntegrationTests.AppDelegateStub";

    if (NSClassFromString(unitTestsAppDelegateClassName) != nil) {
        runAppUsingAppDelegateStub(unitTestsAppDelegateClassName);
    } else if (NSClassFromString(integrationTestsAppDelegateClassName) != nil) {
        runAppUsingAppDelegateStub(integrationTestsAppDelegateClassName);
    } else {
        return NSApplicationMain(argc,(const char **) argv);
    }
}

void runAppUsingAppDelegateStub(NSString *className)
{
    id appDelegate = [[NSClassFromString(className) alloc] init];
    [[NSApplication sharedApplication] setDelegate:appDelegate];
    [NSApp run];
}
