////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014-2015 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMDocument.h"

#import "RLMClassNode.h"
#import "RLMArrayNode.h"
#import "RLMClassProperty.h"
#import "RLMRealmOutlineNode.h"
#import "RLMRealmBrowserWindowController.h"

#import <AppSandboxFileAccess/AppSandboxFileAccess.h>

@interface RLMDocument ()

@property (nonatomic, assign, readwrite) BOOL potentiallyEncrypted;
@property (nonatomic, strong) NSURL *securityScopedURL;
@property (nonatomic) RLMNotificationToken *changeNotificationToken;

@end

@implementation RLMDocument

- (instancetype)initWithContentsOfURL:(NSURL *)absoluteURL ofType:(NSString *)typeName error:(NSError **)outError
{
    __block BOOL success = NO;
    
    if (self = [super init]) {
        if (![[typeName lowercaseString] isEqualToString:@"documenttype"]) {
            return nil;
        }
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:absoluteURL.path]) {
            return nil;
        }
        NSString *lastComponent = [absoluteURL lastPathComponent];
        NSString *extension = [absoluteURL pathExtension];
        
        if (![[extension lowercaseString] isEqualToString:@"realm"]) {
            return nil;
        }
        
        NSURL *folderURL = absoluteURL;
        BOOL isDir = NO;
        if (([[NSFileManager defaultManager] fileExistsAtPath:folderURL.path isDirectory:&isDir] && isDir == NO)) {
            folderURL = [folderURL URLByDeletingLastPathComponent];
        }
        
        AppSandboxFileAccess *sandBoxAccess = [AppSandboxFileAccess fileAccess];
        [sandBoxAccess requestAccessPermissionsForFileURL:folderURL persistPermission:YES withBlock:^(NSURL *securityScopedFileURL, NSData *bookmarkData){
            self.securityScopedURL = securityScopedFileURL;
        }];
        
        if (self.securityScopedURL == nil)
            return nil;
        
        NSArray *fileNameComponents = [lastComponent componentsSeparatedByString:@"."];
        NSString *realmName = [fileNameComponents firstObject];
        
        RLMRealmNode *realmNode = [[RLMRealmNode alloc] initWithName:realmName url:absoluteURL.path];
        __block __weak RLMDocument *ws = self;
        
        self.fileURL = absoluteURL;
        
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self.securityScopedURL startAccessingSecurityScopedResource];
            
            NSError *error;
            if ([realmNode connect:&error] || error.code == 2) {
                if (error) {
                    NSAlert *encryptionAlert = [[NSAlert alloc] init];
                    encryptionAlert.messageText = [NSString stringWithFormat:@"'%@' could not be opened. It may be encrypted, or it isn't in a compatible file format.", realmName];
                    encryptionAlert.informativeText = @"If you know the file is encrypted, you can manually enter its encryption key to open it.";
                    [encryptionAlert addButtonWithTitle:@"Close"];
                    [encryptionAlert addButtonWithTitle:@"Enter Encryption Key"];
                    
                    if ([encryptionAlert runModal] != NSAlertSecondButtonReturn) {
                        return;
                    }
                    
                    ws.potentiallyEncrypted = YES;
                }
                    
                ws.presentedRealm  = realmNode;
                
                ws.changeNotificationToken = [realmNode.realm addNotificationBlock:^(NSString *notification, RLMRealm *realm) {
                    for (RLMRealmBrowserWindowController *windowController in ws.windowControllers) {
                        [windowController reloadAfterEdit];
                    }
                }];
                
                NSDocumentController *documentController = [NSDocumentController sharedDocumentController];
                [documentController noteNewRecentDocumentURL:absoluteURL];
                
                for (RLMRealmBrowserWindowController *windowController in ws.windowControllers) {
                    [windowController realmDidLoad];
                }
                
                success = YES;
            }
            else if (error) {
                [[NSApplication sharedApplication] presentError:error];
            }
        });
    }
    
    return success ? self : nil;
}

- (id)initForURL:(NSURL *)urlOrNil withContentsOfURL:(NSURL *)contentsURL ofType:(NSString *)typeName error:(NSError *__autoreleasing *)outError
{
    return nil;
}

- (void)dealloc
{
    [self.presentedRealm.realm removeNotification:self.changeNotificationToken];
    
    //In certain instances, RLMRealm's C++ destructor method will attempt to clean up
    //specific auxiliary files belonging to this realm file.
    //If the destructor call occurs after the access to the sandbox resource has been released here,
    //and it attempts to delete any files, RLMRealm will throw an exception.
    //Mac OS X apps only have a finite number of open sandbox resources at any given time, so while it's not necessary
    //to release them straight away, it is still good practice to do so eventually.
    //As such, this will release the handle a minute, after closing the document.
    NSURL *scopedURL = self.securityScopedURL;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [scopedURL stopAccessingSecurityScopedResource];
    });
}

#pragma mark - Public methods - NSDocument overrides - Creating and Managing Window Controllers

- (void)makeWindowControllers
{
    RLMRealmBrowserWindowController *windowController = [[RLMRealmBrowserWindowController alloc] initWithWindowNibName:self.windowNibName];
    windowController.modelDocument = self;
    [self addWindowController:windowController];
}

- (NSString *)windowNibName
{
    return @"RLMDocument";
}

#pragma mark - Public methods - NSDocument overrides - Loading Document Data

+ (BOOL)canConcurrentlyReadDocumentsOfType:(NSString *)typeName
{
    return YES;
}

- (NSData *)dataOfType:(NSString *)typeName error:(NSError **)outError
{
    // As we do not use the usual file handling mechanism we just returns nil (but it is necessary
    // to override this method as the default implementation throws an exception.
    return nil;
}

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)typeName error:(NSError **)outError
{
    // As we do not use the usual file handling mechanism we just returns YES (but it is necessary
    // to override this method as the default implementation throws an exception.
    return YES;
}

#pragma mark - Public methods - NSDocument overrides - Managing Document Windows

- (NSString *)displayName
{
    if (self.presentedRealm.name != nil) {
        return self.presentedRealm.name;
    }
    
    return [super displayName];
}

@end
