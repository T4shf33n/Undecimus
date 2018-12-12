//
//  utils.m
//  Undecimus
//
//  Created by Sam Bingner on 11/23/18.
//  Copyright © 2018 Pwn20wnd. All rights reserved.
//

#import <mach/error.h>
#import <sys/sysctl.h>
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <spawn.h>
#import <QiLin.h>
#include <common.h>
#import "utils.h"

int sha1_to_str(const unsigned char *hash, int hashlen, char *buf, size_t buflen)
{
    if (buflen < (hashlen*2+1)) {
        return -1;
    }
    
    int i;
    for (i=0; i<hashlen; i++) {
        sprintf(buf+i*2, "%02X", hash[i]);
    }
    buf[i*2] = 0;
    return ERR_SUCCESS;
}

NSString *sha1sum(NSString *file)
{
    uint8_t buffer[0x1000];
    unsigned char md[CC_SHA1_DIGEST_LENGTH];

    if (![[NSFileManager defaultManager] fileExistsAtPath:file])
        return nil;
    
    NSInputStream *fileStream = [NSInputStream inputStreamWithFileAtPath:file];
    [fileStream open];

    CC_SHA1_CTX c;
    CC_SHA1_Init(&c);
    while ([fileStream hasBytesAvailable]) {
        NSInteger read = [fileStream read:buffer maxLength:0x1000];
        CC_SHA1_Update(&c, buffer, (CC_LONG)read);
    }
    
    CC_SHA1_Final(md, &c);
    
    char checksum[CC_SHA1_DIGEST_LENGTH * 2 + 1];
    if (sha1_to_str(md, CC_SHA1_DIGEST_LENGTH, checksum, sizeof(checksum)) != ERR_SUCCESS)
        return nil;
    return [NSString stringWithUTF8String:checksum];
}

bool verifySha1Sums(NSString *sumFile) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:sumFile])
        return false;
    
    NSString *checksums = [NSString stringWithContentsOfFile:sumFile encoding:NSUTF8StringEncoding error:NULL];
    if (checksums == nil)
        return false;
    
    for (NSString *checksum in [checksums componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        // Ignore blank lines
        if ([checksum isEqualToString:@""])
            continue;

        NSArray<NSString*> *suminfo = [checksum componentsSeparatedByString:@"  "];

        if ([suminfo count] != 2) {
            LOG("Invalid line \"%s\"", checksum.UTF8String);
            return false;
        }
        NSString *fileSum = sha1sum(suminfo[1]);
        if (![fileSum.lowercaseString isEqualToString:suminfo[0]]) {
            LOG("Corrupted \"%s\"", [suminfo[1] UTF8String]);
            return false;
        }
        LOG("Verified \"%s\"", [suminfo[1] UTF8String]);
    }
    LOG("No errors in verifying checksums");
    return true;
}

int _system(const char *cmd) {
    posix_spawn_file_actions_t *actions = NULL;
    posix_spawn_file_actions_t actionsStruct;
    pid_t Pid = 0;
    int Status = 0;
    int out_pipe[2];
    bool valid_pipe = false;
    char *myenviron[] = {
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games",
        "PS1=\\h:\\w \\u\\$ ",
        NULL
    };
    char *argv[] = {"sh", "-c", (char *)cmd, NULL};
    valid_pipe = pipe(out_pipe) == ERR_SUCCESS;
    if (valid_pipe && posix_spawn_file_actions_init(&actionsStruct) == ERR_SUCCESS) {
        actions = &actionsStruct;
        posix_spawn_file_actions_adddup2(actions, out_pipe[1], 1);
        posix_spawn_file_actions_adddup2(actions, out_pipe[1], 2);
        posix_spawn_file_actions_addclose(actions, out_pipe[0]);
        posix_spawn_file_actions_addclose(actions, out_pipe[1]);
    }
    Status = posix_spawn(&Pid, "/bin/sh", actions, NULL, argv, myenviron);
    if (valid_pipe) {
        close(out_pipe[1]);
    }
    if (Status == ERR_SUCCESS) {
        waitpid(Pid, &Status, 0);
        if (valid_pipe) {
            NSData *outData = [[[NSFileHandle alloc] initWithFileDescriptor:out_pipe[0]] availableData];
            LOG("system(\"%s\") [%d]: %s", cmd, WEXITSTATUS(Status), [outData bytes]);
        }
    }
    if (valid_pipe) {
        close(out_pipe[0]);
    }
    return Status;
}

int _systemf(const char *cmd, ...) {
    va_list ap;
    va_start(ap, cmd);
    NSString *cmdstr = [[NSString alloc] initWithFormat:@(cmd) arguments:ap];
    va_end(ap);
    return _system([cmdstr UTF8String]);
}

bool debIsInstalled(char *packageID) {
    int rv = _systemf("/usr/bin/dpkg -s \"%s\" > /dev/null 2>&1", packageID);
    bool isInstalled = !WEXITSTATUS(rv);
    LOG("Deb: \"%s\" is%s installed", packageID, isInstalled?"":" not");
    return isInstalled;
}

bool debIsConfigured(char *packageID) {
    int rv = _systemf("/usr/bin/dpkg -s \"%s\" | grep Status: | grep \"install ok installed\" > /dev/null", packageID);
    bool isConfigured = !WEXITSTATUS(rv);
    LOG("Deb: \"%s\" is%s configured", packageID, isConfigured?"":" not");
    return isConfigured;
}

bool installDeb(char *debName) {
    NSString *destPathStr = [NSString stringWithFormat:@"/jb/%s", debName];
    const char *destPath = [destPathStr UTF8String];
    if (!clean_file(destPath)) {
        return false;
    }
    if (moveFileFromAppDir(debName, (char *)destPath) != ERR_SUCCESS) {
        return false;
    }
    int rv = _systemf("/usr/bin/dpkg --force-bad-path --force-configure-any -i \"%s\"", destPath);
    clean_file(destPath);
    return !WEXITSTATUS(rv);
}

bool pidFileIsValid(NSString *pidfile) {
    NSString *jbdpid = [NSString stringWithContentsOfFile:pidfile encoding:NSUTF8StringEncoding error:NULL];
    if (jbdpid != nil) {
        char pidpath[MAXPATHLEN];
        int len = proc_pidpath([jbdpid intValue], pidpath, sizeof(pidpath));
        if (len > 0 && strncmp(pidpath, "/usr/libexec/jailbreakd", len) == 0) {
            return true;
        }
    }
    return false;
}

bool pspawnHookLoaded() {
    static int request[2] = { CTL_KERN, KERN_BOOTTIME };
    struct timeval result;
    size_t result_len = sizeof result;

    if (access("/private/var/run/pspawn_hook.ts", F_OK) == ERR_SUCCESS) {
        NSString *stamp = [NSString stringWithContentsOfFile:@"/private/var/run/pspawn_hook.ts" encoding:NSUTF8StringEncoding error:NULL];
        if (stamp != nil && sysctl(request, 2, &result, &result_len, NULL, 0) >= 0) {
            if ([stamp integerValue] > result.tv_sec) {
                return true;
            }
        }
    }
    return false;
}