//
//  EEProvisioning.m
//  OpenExtenderTest
//
//  Created by Matt Clarke on 28/12/2017.
//  Copyright © 2017 Matt Clarke. All rights reserved.
//

#import "EEProvisioning.h"
#import "EESigning.h"
#import "SAMKeychain.h"

#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <cstdio>
#include <iostream>

// NSHost is a private API on non-macOS platforms
#if TARGET_OS_IPHONE
@interface NSHost : NSObject
+ (instancetype)currentHost;
- (NSString *)localizedName;
@end

#import <UIKit/UIKit.h>  // For device name
#import "RPVResources.h"
#endif

@implementation EEProvisioning

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Initialisation
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////

+ (instancetype)provisionerWithCredentials:(NSString *)identity:(NSString *)gsToken {
    return [[EEProvisioning alloc] initWithCredentials:identity:gsToken];
}

- (instancetype)initWithCredentials:(NSString *)identity:(NSString *)gsToken {
    self = [super init];

    if (self) {
        _identity = identity;
        _gsToken = gsToken;
    }

    return self;
}

+ (NSError *)_errorFromString:(NSString *)string {
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: NSLocalizedString(string, nil),
        NSLocalizedFailureReasonErrorKey: NSLocalizedString(string, nil),
        NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"", nil)
    };

    NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:-1
                                     userInfo:userInfo];

    return error;
}

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Public methods
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)provisionDevice:(NSString *)udid name:(NSString *)name withTeamIDCheck:(NSString * (^)(NSArray *))teamIDCallback systemType:(EESystemType)systemType andCallback:(void (^)(NSError *))completionHandler {
    // nop.

    [self _provisioningStageOneWithIdentifier:@"" withTeamIDCheck:teamIDCallback andCallback:^(NSError *error) {
        if (error) {
            completionHandler(error);
            return;
        }

        [[EEAppleServices sharedInstance] addDevice:udid deviceName:name forTeamID:[[EEAppleServices sharedInstance] currentTeamID] systemType:systemType withCompletionHandler:^(NSError *error, NSDictionary *plist) {
            if (error) {
                completionHandler(error);
                return;
            }

            // TODO: Check plist for errors.

            int resultCode = [[plist objectForKey:@"resultCode"] intValue];
            if (resultCode != 0) {
                NSError *error = [EEProvisioning _errorFromString:[plist objectForKey:@"resultString"]];
                completionHandler(error);
                return;
            }

            completionHandler(nil);
        }];
    }];
}

- (void)revokeCertificatesWithTeamIDCheck:(NSString * (^)(NSArray *))teamIDCallback systemType:(EESystemType)systemType andCallback:(void (^)(NSError *))completionHandler {
    [self _provisioningStageOneWithIdentifier:@"" withTeamIDCheck:teamIDCallback andCallback:^(NSError *error) {
        if (error) {
            completionHandler(error);
            return;
        }

        [[EEAppleServices sharedInstance] listAllDevelopmentCertificatesForTeamID:[[EEAppleServices sharedInstance] currentTeamID] systemType:systemType withCompletionHandler:^(NSError *error, NSDictionary *plist) {
            if (error) {
                completionHandler(error);
                return;
            }

            // TODO: Check plist for errors.

            NSString *deviceID = [self _identifierForCurrentMachine];

            NSString *certId;

            for (NSDictionary *dict in [plist objectForKey:@"data"]) {
                NSString *machineId = dict[@"attributes"][@"machineId"];
                if ([machineId isEqualToString:deviceID]) {
                    // Got it!
                    certId = dict[@"id"];
                    break;
                }
            }

            if (certId) {
                // Revoke it!
                [[EEAppleServices sharedInstance] revokeCertificateForIdentifier:certId andTeamID:[[EEAppleServices sharedInstance] currentTeamID] systemType:systemType withCompletionHandler:^(NSError *error, NSDictionary *plist) {
                    if (error) {
                        completionHandler(error);
                        return;
                    }

                    // TODO: Check plist for errors.

                    completionHandler(nil);
                }];
            }
        }];
    }];
}

- (void)downloadProvisioningProfileForApplicationIdentifier:(NSString *)identifier applicationName:(NSString *)applicationName binaryLocation:(NSString *)binaryLocation withTeamIDCheck:(NSString * (^)(NSArray *))teamIDCallback systemType:(EESystemType)systemType andCallback:(void (^)(NSError *, NSData *, NSString *, NSDictionary *, NSDictionary *))completionHandler;
{
    /*
     * Process:
     *
     * Stage 1
     * 1. Sign in
     * 2. Update Team ID value stored locally
     * 2.a. If no Team ID associated to this account, create one if possible.
     *
     * Stage 2
     * 3. Check a valid development codesigning certifcate exists for the current machine.
     * 3.a. If present, but without access to its private key or is expired, revoke it.
     * 3.b. If none present or have revoked, create one.
     *
     * Stage 3
     * 4. Check an application group for "Cydia" exists for the current team.
     * 4.a. If none present, create one.
     * 5. Add or update an application entry with the provided identifier to the current team.
     *
     * Stage 4
     * 6. Remove the existing provisioning profile for this application entry.
     * 7. Download the provisioning certificate for this application entry.
     */

    [self _provisioningStageOneWithIdentifier:identifier withTeamIDCheck:teamIDCallback andCallback:^(NSError *error) {
        if (error) {
            completionHandler(error, nil, nil, nil, nil);
            return;
        }

        [self _provisioningStageTwoWithIdentifier:identifier systemType:systemType andCallback:^(NSError *error, NSString *privateKey, NSDictionary *certificate) {
            if (error) {
                completionHandler(error, nil, nil, nil, nil);
                return;
            }

            [self _provisioningStageThreeWithIdentifier:identifier applicationName:applicationName binaryLocation:binaryLocation systemType:systemType andCallback:^(NSError *error, NSString *appIdId, NSDictionary *entitlements) {
                if (error) {
                    completionHandler(error, nil, nil, nil, nil);
                    return;
                }

                [self _provisioningStageFourWithIdentifier:identifier appIdId:appIdId systemType:systemType andCallback:^(NSError *error, NSData *embeddedMobileprovision) {
                    // All done, return back to caller.
                    completionHandler(error, embeddedMobileprovision, privateKey, certificate, entitlements);
                }];
            }];
        }];
    }];
}

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Private methods: provisioning stage 1
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)_provisioningStageOneWithIdentifier:(NSString *)identifier withTeamIDCheck:(NSString * (^)(NSArray *))teamIDCallback andCallback:(void (^)(NSError *))completionHandler {
    /*
     * Stage 1
     * 1. Sign in
     * 2. Update Team ID value stored locally.
     */

    [self _signIn:_identity gsToken:_gsToken withCallback:^(NSError *error) {
        if (!error) {
            // Only continue if authenticated!
            NSLog(@"Authenticated!");

            [[EEAppleServices sharedInstance] updateCurrentTeamIDWithTeamIDCheck:teamIDCallback andCallback:^(NSError *error, NSString *teamid) {
                if (error) {
                    NSError *error2 = [EEProvisioning _errorFromString:[@"updateCurrentTeamIDWithCompletionHandler: " stringByAppendingString:error.localizedDescription]];
                    completionHandler(error2);
                    return;
                }

                // TODO: Check plist for errors.

                NSLog(@"Team ID: %@", teamid);

                if ([teamid isEqualToString:@""]) {
                    // We shouldn't ever reach this, but the logic is present just in case.
                    NSError *error = [EEProvisioning _errorFromString:@"updateCurrentTeamIDWithCompletionHandler: No Team ID present! This is *really* bad."];
                    completionHandler(error);
                } else {
                    completionHandler(nil);
                }
            }];
        } else {
            completionHandler(error);
        }
    }];
}

- (void)_signIn:(NSString *)identity gsToken:(NSString *)gsToken withCallback:(void (^)(NSError *))completionHandler {
    [[EEAppleServices sharedInstance] ensureSessionWithIdentity:identity gsToken:gsToken andCompletionHandler:^(NSError *error, NSDictionary *plist) {
        if (error) {
            completionHandler(error);
            return;
        }

        // TODO: Check plist for errors.

        NSString *reason = [plist objectForKey:@"reason"];
        NSString *userString = [plist objectForKey:@"userString"];
        BOOL authenticated = [reason isEqualToString:@"authenticated"];

        NSError *error2 = [EEProvisioning _errorFromString:[NSString stringWithFormat:@"%@ %@", reason, userString]];

        completionHandler(authenticated ? nil : error2);
    }];
}

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Private methods: provisioning stage 2
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)_provisioningStageTwoWithIdentifier:(NSString *)identifier systemType:(EESystemType)systemType andCallback:(void (^)(NSError *, NSString *, NSDictionary *))completionHandler {
    /*
     * Stage 2
     * 3. Check a valid development codesigning certifcate exists for "Cydia".
     * 3.a. If none present, create one.
     */

    [self _handleDevelopmentCodesigningRequestIfNecessary:^(NSError *error, NSString *privateKey, NSDictionary *certificate) {
        if (!error) {
            NSLog(@"We have a development certificate that can be used!");
        }

        completionHandler(error, privateKey, certificate);
    } systemType:systemType];
}

- (void)_handleDevelopmentCodesigningRequestIfNecessary:(void (^)(NSError *, NSString *, NSDictionary *))completionHandler systemType:(EESystemType)systemType {
    [[EEAppleServices sharedInstance] listAllDevelopmentCertificatesForTeamID:[[EEAppleServices sharedInstance] currentTeamID] systemType:systemType withCompletionHandler:^(NSError *error, NSDictionary *plist) {
        if (error) {
            NSError *error2 = [EEProvisioning _errorFromString:[@"listAllDevelopmentCertificatesForTeamID: " stringByAppendingString:error.localizedDescription]];
            completionHandler(error2, nil, nil);
            return;
        }

        // TODO: Check plist for errors.

        /*
          * We need to generate a development codesigning certificate for the CURRENT machine if one is not present,
          * OR if we're missing the private key locally. If missing the private key, we MUST revoke
          * the development certificate for the current machine.
          *
          * Furthermore, we will NOT use "Cydia" as a name for the codesigning certificate. The original
          * Cydia Extender did this, which then caused issues: other devices cannot use same Apple ID
          * to sign with, since they would be missing the private key for the certificate. As a result,
          * they'd try and make a new codesigning request with the machineName of "Cydia" and machineId
          * of "CB6D337C-3D63-4523-AADE-6622234ABDA8". This would then be rejected!
          *
          * To summarise:
            1. Check if we have the private key of the development cert in the keychain for this device's ID
            2. Check that a development certificate exists for this device's ID and is valid.
            2.a. If both true, return both the cert and key to the completion handler.
            3. If either is false, submit a new development codesigning request, revoking if (1) is true.
            3.a. Return the new cert and key to the completion handler.
          *
          * Note also that we stored the Team ID the private key is for. This is so we can detect when the user
          * has switched accounts, and so we re/create the development CSR as needed.
          */

        NSString *privateKeyAccount = @"privateKey";
        NSString *privateKey = [SAMKeychain passwordForService:@"jp.soh.reprovision" account:privateKeyAccount];
        NSString *privateKeyAssociatedTeamID = [SAMKeychain passwordForService:@"jp.soh.reprovision" account:@"privateKeyTeamID"];

        BOOL hasValidCertificate = NO;
        NSDate *now = [NSDate date];
        NSDictionary *certificate;
        NSString *certId;

        for (NSDictionary *dict in [plist objectForKey:@"data"]) {
            NSString *machineId = dict[@"attributes"][@"machineId"];
            NSString *machineName = dict[@"attributes"][@"machineName"];

            if (machineName != [NSNull null] && [machineName length] > 0) {
                BOOL shouldCheckForAltStore = [machineName isEqualToString:@"AltStore"] && [RPVResources shouldForceResign];

                if ([machineId isEqualToString:[self _identifierForCurrentMachine]] || shouldCheckForAltStore) {
                    // Alright cool. Now, we check to see if it has expired.
                    certificate = dict[@"attributes"];
                    certId = dict[@"id"];

                    // Compare expirationDate to now. If passed, then certificate is not valid.
                    hasValidCertificate = YES;

                    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
                    dateFormatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
                    dateFormatter.dateFormat = @"yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'";
                    dateFormatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];

                    NSDate *certificateExpiryDate = [dateFormatter dateFromString:dict[@"attributes"][@"expirationDate"]];
                    if ([now compare:certificateExpiryDate] == NSOrderedDescending || shouldCheckForAltStore) {
                        // Certificate has passed its expiry date.
                        hasValidCertificate = NO;
                    }

                    break;
                }
            }
        }

        BOOL currentTeamIDMatchesStored = [[[EEAppleServices sharedInstance] currentTeamID] isEqualToString:privateKeyAssociatedTeamID];

        if (!hasValidCertificate || [privateKey isEqualToString:@""] || privateKey == nil || !currentTeamIDMatchesStored) {
            // If the certificate exists already, then revoke.
            BOOL shouldRevokeFirst = certificate != nil;

            // Revoke that certificate! Note that this revocation is for THIS MACHINE ONLY.
            // Therefore, we SHOULD NOT have an issue for if we're on a team that allows App Store deployment.
            if (shouldRevokeFirst) {
                NSString *reason = @"";

                if ([privateKey isEqualToString:@""] || privateKey == nil || !currentTeamIDMatchesStored)
                    reason = @"not having the private key for it stored on this device.";
                else
                    reason = @"this certificate being expired.";

                NSLog(@"Revoking certificate with identifier '%@', due to %@", certId, reason);

                [[EEAppleServices sharedInstance] revokeCertificateForIdentifier:certId andTeamID:[[EEAppleServices sharedInstance] currentTeamID] systemType:systemType withCompletionHandler:^(NSError *error, NSDictionary *plist) {
                    if (error) {
                        // Handle error.
                        completionHandler(error, nil, nil);
                        return;
                    }

                    // No need to worry about any plist-based errors here.

                    // Send in the new code-signing request to Apple.
                    [self _submitNewCodeSigningRequestForTeamID:[[EEAppleServices sharedInstance] currentTeamID] machineName:[self _nameForCurrentMachine] machineId:[self _identifierForCurrentMachine] systemType:systemType withCallback:^(NSError *error, NSString *privateKey, NSDictionary *certificate) {
                        if (error) {
                            // Handle error.
                            completionHandler(error, nil, nil);
                            return;
                        }

                        // Store new private key into the keychain for future usage.
                        NSString *privateKeyAccount = @"privateKey";
                        [SAMKeychain setPassword:privateKey forService:@"jp.soh.reprovision" account:privateKeyAccount];
                        [SAMKeychain setPassword:[[EEAppleServices sharedInstance] currentTeamID] forService:@"jp.soh.reprovision" account:@"privateKeyTeamID"];

                        // Read certificate from result, and pass back to caller with the private key too.
                        completionHandler(nil, privateKey, certificate);
                    }];
                }];

                return;
            }

            // We need to make a code-signing request, such that we can sign on this machine.

            // Send in the new code-signing request to Apple.
            [self _submitNewCodeSigningRequestForTeamID:[[EEAppleServices sharedInstance] currentTeamID]
                                            machineName:[self _nameForCurrentMachine]
                                              machineId:[self _identifierForCurrentMachine]
                                             systemType:systemType
                                           withCallback:^(NSError *error, NSString *privateKey, NSDictionary *certificate) {
                                               if (error) {
                                                   // Handle error.
                                                   completionHandler(error, nil, nil);
                                                   return;
                                               }

                                               // Store new private key into the keychain for future usage.
                                               NSString *privateKeyAccount = @"privateKey";
                                               [SAMKeychain setPassword:privateKey forService:@"jp.soh.reprovision" account:privateKeyAccount];
                                               [SAMKeychain setPassword:[[EEAppleServices sharedInstance] currentTeamID] forService:@"jp.soh.reprovision" account:@"privateKeyTeamID"];

                                               // Read certificate from result, and pass back to caller with the private key too.
                                               completionHandler(nil, privateKey, certificate);
                                           }];
        } else {
            // Return the private key back to caller.
            completionHandler(nil, privateKey, certificate);
        }
    }];
}

- (NSString *)_nameForCurrentMachine {
    // Need to change how we get the device name for iOS-based devices.
#if TARGET_OS_SIMULATOR
    return @"Simulator";
#elif TARGET_OS_IPHONE
    return [NSString stringWithFormat:@"%@", [[UIDevice currentDevice] name]];
#else
    return [NSString stringWithFormat:@"%@", [[NSHost currentHost] localizedName]];
#endif
}

- (NSString *)_identifierForCurrentMachine {
    // We're using a persistent UUID here, not a UDID or anything.
    NSString *uuid = [SAMKeychain passwordForService:@"jp.soh.reprovision" account:@"uuid"];
    if (!uuid || [uuid isEqualToString:@""]) {
        uuid = [[NSUUID UUID] UUIDString];
        [SAMKeychain setPassword:uuid forService:@"jp.soh.reprovision" account:@"uuid"];
    }
    return uuid;
}

// Returns new private key in args[1] and new certificate in args[2] of comletionHandler.
- (void)_submitNewCodeSigningRequestForTeamID:(NSString *)teamid machineName:(NSString *)machineName machineId:(NSString *)machineId systemType:(EESystemType)systemType withCallback:(void (^)(NSError *, NSString *, NSDictionary *))completionHandler {
    // First, we generate the CSR.
    NSData *privateKey;
    NSData *codeSigningRequest;

    int ret = [self _generateCodeSigningRequest:&privateKey:&codeSigningRequest];
    if (ret != 1 || !codeSigningRequest) {
        NSError *error = [EEProvisioning _errorFromString:@"submitDevelopmentCSR: Failed to generate a code signing request"];
        completionHandler(error, nil, nil);
        return;
    }

    NSLog(@"Generated a codesigning request, submitting...");

    // Going to add a prefix to the machine name.
    machineName = [NSString stringWithFormat:@"RPV- %@", machineName];

    // Now that we have a CSR and private key, we can submit the CSR to Apple.
    [[EEAppleServices sharedInstance] submitCodeSigningRequestForTeamID:teamid machineName:machineName machineID:machineId codeSigningRequest:codeSigningRequest systemType:systemType withCompletionHandler:^(NSError *error, NSDictionary *plist) {
        if (error) {
            completionHandler(error, nil, nil);
            return;
        }

        // Verify that the certificate request has been approved.
        NSDictionary *data = [plist objectForKey:@"data"];
        NSArray *errors = [plist objectForKey:@"errors"];
        if (errors != nil) {
            // NOT the userString, since that has an incorrect error reason in.
            NSString *resultString = [errors[0] objectForKey:@"detail"];

            NSString *desc = [NSString stringWithFormat:@"submitDevelopmentCSR: %@", resultString];

            NSError *error = [EEProvisioning _errorFromString:desc];

            completionHandler(error, nil, nil);
            return;
        }

        // Double check now that we have been approved.

        /*NSDictionary *certRequest = [plist objectForKey:@"certRequest"];

        if (!certRequest) {
            NSError *error = [EEProvisioning _errorFromString:@"Missing certificate on Apple's servers."];

            completionHandler(error, nil, nil);
            return;
        }*/

        // Grab the certificate, and return it with the private key to the caller.
        NSString *certificateSerialID = data[@"attributes"][@"serialNumber"];

        [[EEAppleServices sharedInstance] listAllDevelopmentCertificatesForTeamID:[[EEAppleServices sharedInstance] currentTeamID] systemType:systemType withCompletionHandler:^(NSError *error, NSDictionary *plist) {
            if (error) {
                completionHandler(error, nil, nil);
                return;
            }

            // TODO: Check plist for errors.

            NSDictionary *certificate;
            for (NSDictionary *dict in [plist objectForKey:@"data"]) {
                NSString *certSerialNumber = dict[@"attributes"][@"serialNumber"];
                if ([certSerialNumber isEqualToString:certificateSerialID]) {
                    // Got it!
                    certificate = dict[@"attributes"];
                    break;
                }
            }

            // Job done!
            if (certificate) {
                NSString *stringifiedPrivateKey = [[NSString alloc] initWithData:privateKey encoding:NSUTF8StringEncoding];
                completionHandler(nil, stringifiedPrivateKey, certificate);
            } else {
                NSString *desc = [NSString stringWithFormat:@"submitDevelopmentCSR: Cannot find new certificate with serial number '%@'", certificateSerialID];

                NSError *error = [EEProvisioning _errorFromString:desc];

                completionHandler(error, nil, nil);
            }
        }];
    }];
}

- (int)_generateCodeSigningRequest:(NSData **)privateKey:(NSData **)codeSigningRequest {
    // Code utilised from: http://www.codepool.biz/how-to-use-openssl-to-generate-x-509-certificate-request.html

    int ret = 0;
    RSA *r = NULL;
    BIGNUM *bne = NULL;

    int nVersion = 1;
    int bits = 2048;
    unsigned long e = RSA_F4;

    X509_REQ *x509_req = NULL;
    X509_NAME *x509_name = NULL;
    EVP_PKEY *pKey = NULL;
    BIO *csr = NULL;
    BIO *privKey = NULL;
    char *data = NULL;
    long len = 0;

    // Certificate info.
    const char *szCountry = "UK";
    const char *szCommon = "ReProvision";
    const char *szProvince = "London";
    const char *szCity = "London";
    const char *szOrganization = "ReProvision";

    // 1. generate rsa key
    bne = BN_new();
    ret = BN_set_word(bne, (unsigned int)e);
    if (ret != 1) {
        goto free_all;
    }

    r = RSA_new();
    ret = RSA_generate_key_ex(r, bits, bne, NULL);
    if (ret != 1) {
        goto free_all;
    }

    // 2. set version of x509 req
    x509_req = X509_REQ_new();
    ret = X509_REQ_set_version(x509_req, nVersion);
    if (ret != 1) {
        goto free_all;
    }

    // 3. set subject of x509 req
    x509_name = X509_REQ_get_subject_name(x509_req);

    ret = X509_NAME_add_entry_by_txt(x509_name, "C", MBSTRING_ASC, (const unsigned char *)szCountry, -1, -1, 0);
    if (ret != 1) {
        goto free_all;
    }

    ret = X509_NAME_add_entry_by_txt(x509_name, "ST", MBSTRING_ASC, (const unsigned char *)szProvince, -1, -1, 0);
    if (ret != 1) {
        goto free_all;
    }

    ret = X509_NAME_add_entry_by_txt(x509_name, "L", MBSTRING_ASC, (const unsigned char *)szCity, -1, -1, 0);
    if (ret != 1) {
        goto free_all;
    }

    ret = X509_NAME_add_entry_by_txt(x509_name, "O", MBSTRING_ASC, (const unsigned char *)szOrganization, -1, -1, 0);
    if (ret != 1) {
        goto free_all;
    }

    ret = X509_NAME_add_entry_by_txt(x509_name, "CN", MBSTRING_ASC, (const unsigned char *)szCommon, -1, -1, 0);
    if (ret != 1) {
        goto free_all;
    }

    // 4. set public key of x509 req
    pKey = EVP_PKEY_new();
    EVP_PKEY_assign_RSA(pKey, r);

    ret = X509_REQ_set_pubkey(x509_req, pKey);
    if (ret != 1) {
        goto free_all;
    }

    // 5. set sign key of x509 req
    ret = X509_REQ_sign(x509_req, pKey, EVP_sha1());  // return x509_req->signature->length
    if (ret <= 0) {
        goto free_all;
    }

    csr = BIO_new(BIO_s_mem());
    ret = PEM_write_bio_X509_REQ(csr, x509_req);

    privKey = BIO_new(BIO_s_mem());
    ret = PEM_write_bio_RSAPrivateKey(privKey, r, NULL, NULL, 0, NULL, NULL);

    // 6. Push the CSR and the private key into our function outputs.
    len = BIO_get_mem_data(csr, &data);
    *codeSigningRequest = [NSData dataWithBytes:data length:len];

    len = BIO_get_mem_data(privKey, &data);
    *privateKey = [NSData dataWithBytes:data length:len];

    // 7. free
free_all:
    r = NULL;  // will be free rsa when EVP_PKEY_free(pKey)

    X509_REQ_free(x509_req);
    BIO_free_all(csr);
    BIO_free_all(privKey);

    EVP_PKEY_free(pKey);
    BN_free(bne);

    return (ret == 1);
}

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Private methods: provisioning stage 3
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)_provisioningStageThreeWithIdentifier:(NSString *)identifier applicationName:(NSString *)applicationName binaryLocation:(NSString *)binaryLocation systemType:(EESystemType)systemType andCallback:(void (^)(NSError *, NSString *, NSDictionary *))completionHandler {
    /*
     * Stage 3
     * 4. Check an application group for "Cydia" exists for the current team.
     * 4.a. if none present, create one.
     * 5. Add or update an application entry with the provided identifier to the current team.
     */

    [self _addOrUpdateApplicationID:identifier
                    applicationName:applicationName
                     binaryLocation:binaryLocation
                         systemType:systemType
              withCompletionHandler:^(NSError *error, NSString *appIdId, NSDictionary *entitlements) {
                  completionHandler(error, appIdId, entitlements);
              }];
}

- (void)_addOrUpdateApplicationID:(NSString *)applicationIdentifier applicationName:(NSString *)applicationName binaryLocation:(NSString *)binaryLocation systemType:(EESystemType)systemType withCompletionHandler:(void (^)(NSError *, NSString *, NSDictionary *))completionHandler {
    [[EEAppleServices sharedInstance] listAllApplicationsForTeamID:[[EEAppleServices sharedInstance] currentTeamID] systemType:systemType withCompletionHandler:^(NSError *error, NSDictionary *plist) {
        if (error) {
            NSError *err = [EEProvisioning _errorFromString:[@"listAllApplicationsForTeamID: " stringByAppendingString:error.localizedDescription]];
            completionHandler(err, @"", nil);
            return;
        }

        int resultCode = [[plist objectForKey:@"resultCode"] intValue];
        if (resultCode != 0) {
            NSError *err = [EEProvisioning _errorFromString:[@"listAllApplicationsForTeamID: " stringByAppendingString:[plist objectForKey:@"resultString"]]];
            completionHandler(err, @"", nil);
            return;
        }

        // If an app ID with this identifier doesn't exist, add one.
        // Else, update it.

        BOOL appIdExists = NO;
        NSString *appIdIdIfExists = @"";
        NSString *fullidentifier = @"";
        for (NSDictionary *appIdDictionary in plist[@"appIds"]) {
            if ([(NSString *)[appIdDictionary objectForKey:@"name"] isEqualToString:applicationName] || [(NSString *)[appIdDictionary objectForKey:@"identifier"] isEqualToString:applicationIdentifier]) {
                appIdExists = YES;
                appIdIdIfExists = [appIdDictionary objectForKey:@"appIdId"];
                fullidentifier = [appIdDictionary objectForKey:@"identifier"];
                break;
            }
        }

        // Setup values for this application.
        NSString *name = applicationName;
        // Strip non-alphanumerical characters
        NSCharacterSet *charactersToRemove = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
        name = [[name componentsSeparatedByCharactersInSet:charactersToRemove] componentsJoinedByString:@" "];
        // Strip multibyte characters
        NSData *nameData = [name dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:YES];
        name = [[NSString alloc] initWithData:nameData encoding:NSASCIIStringEncoding];

        NSString *identifier = applicationIdentifier;

        NSMutableDictionary *enabledFeatures = [NSMutableDictionary dictionary];

        // Grab entitlements and update them from the binary.
        NSMutableDictionary *entitlements = [[EESigning updateEntitlementsForBinaryAtLocation:binaryLocation bundleIdentifier:identifier teamID:[[EEAppleServices sharedInstance] currentTeamID]] mutableCopy];
        NSLog(@"old entitlements: %@ / location: %@", entitlements, binaryLocation);

        // Set application-identifier to be the identifier we have here.
        [entitlements setObject:[NSString stringWithFormat:@"%@.%@", [[EEAppleServices sharedInstance] currentTeamID], identifier] forKey:@"application-identifier"];

        // Setup enabledFeatures for this new application.
        // We need to check if the user has a paid account or not.
        [[EEAppleServices sharedInstance] listTeamsWithCompletionHandler:^(NSError *error, NSDictionary *dictionary) {
            if (error) {
                // TODO: handle!
                return;
            }

            // Check to see if the current Team ID is from a free profile.
            NSArray *teams = [dictionary objectForKey:@"teams"];

            BOOL isFreeUser = YES;
            for (NSDictionary *team in teams) {
                NSString *teamIdToCheck = [team objectForKey:@"teamId"];

                if ([teamIdToCheck isEqualToString:[[EEAppleServices sharedInstance] currentTeamID]]) {
                    NSArray *memberships = [team objectForKey:@"memberships"];

                    for (NSDictionary *membership in memberships) {
                        NSString *name = [membership objectForKey:@"name"];
                        NSString *platform = [membership objectForKey:@"platform"];
                        if ([name containsString:@"Apple Developer Program"] && [platform isEqualToString:@"ios"]) {
                            isFreeUser = NO;
                            break;
                        }
                    }

                    // Exit now if needed.
                    if (!isFreeUser)
                        break;
                }
            }

            // We now handle "Capabilities" this incoming app can utilise.

            // For the following features, the user MUST be using a paid developer account.
            if (!isFreeUser) {
                // TODO: Add the other entitlements that paid accounts can use.
                /*
                 * Apple Pay                                                        -> OM633U5T5G
                 * Associated Domains                                               -> SKC3T5S89Y
                 * iCloud                                                           -> iCloud
                 * In-App Purchase                                                  -> inAppPurchase
                 * Push Notifications                                               -> push
                 * Wallet/Passbook                                                  -> pass
                 */

                NSDictionary *paidEntitlementsToFeatures = @{
                    @"com.apple.developer.networking.networkextension": @"NWEXT04537",
                    @"com.apple.developer.networking.multipath": @"MP49FN762P",
                    @"com.apple.networking.vpn.configuration": @"V66P55NK2I",
                    @"com.apple.developer.siri": @"SI015DKUHP"
                };

                for (NSString *key in [paidEntitlementsToFeatures allKeys]) {
                    if ([[entitlements allKeys] containsObject:key]) {
                        NSString *feature = [paidEntitlementsToFeatures objectForKey:key];
                        [enabledFeatures setObject:@"on" forKey:feature];
                    }
                }
            }

            // More service IDs: https://github.com/fastlane/fastlane/blob/master/spaceship/lib/spaceship/portal/app_service.rb

            NSDictionary *freeAndPaidEntitlementsToFeatures = @{
                @"inter-app-audio": @"IAD53UNK2F",
                @"com.apple.external-accessory.wireless-configuration": @"WC421J6T7P",
                @"com.apple.developer.homekit": @"homeKit",
                @"com.apple.developer.healthkit": @"HK421J6T7P",
                @"com.apple.developer.default-data-protection": @"dataProtection"
            };

            for (NSString *key in [freeAndPaidEntitlementsToFeatures allKeys]) {
                if ([[entitlements allKeys] containsObject:key]) {
                    NSString *feature = [freeAndPaidEntitlementsToFeatures objectForKey:key];

                    // Handle specific weird capabilities
                    if ([feature isEqualToString:@"dataProtection"]) {
                        NSString *entitlement = [entitlements objectForKey:key];
                        NSString *featureValue = @"";

                        if ([entitlement isEqualToString:@"NSFileProtectionComplete"])
                            featureValue = @"complete";
                        else if ([entitlement isEqualToString:@"NSFileProtectionCompleteUnlessOpen"])
                            featureValue = @"unlessopen";
                        else if ([entitlement isEqualToString:@"NSFileProtectionCompleteUntilFirstUserAuthentication"])
                            featureValue = @"untilfirstauth";

                        [enabledFeatures setObject:featureValue forKey:feature];
                    } else {
                        [enabledFeatures setObject:@"on" forKey:feature];
                    }
                }
            }

            /*
             * A free (and paid) development account is also allowed the following entitlements:
             * com.apple.security.application-groups                            -> (handled later)
             * keychain-access-groups                                           -> (implicit)
             * application-identifier                                           -> (implicit)
             * com.apple.developer.team-identifier                              -> (implicit)
             * get-task-allow                                                   -> (to be removed later)
             */

            if (isFreeUser) {
                // We should strip out entitlements the user should not have.
                NSArray *freeCertificateAllowableEntitlements = [NSArray arrayWithObjects:
                                                                             @"application-identifier",
                                                                             @"com.apple.developer.team-identifier",
                                                                             @"keychain-access-groups",
                                                                             @"com.apple.security.application-groups",
                                                                             @"com.apple.developer.default-data-protection",
                                                                             @"com.apple.developer.healthkit",
                                                                             @"com.apple.developer.homekit",
                                                                             @"com.apple.external-accessory.wireless-configuration",
                                                                             @"inter-app-audio",
                                                                             @"get-task-allow",
                                                                             nil];

                for (NSString *key in [[entitlements allKeys] copy]) {
                    if (![freeCertificateAllowableEntitlements containsObject:key]) {
                        [entitlements removeObjectForKey:key];
                    }
                }
            }

            // // Remove get-task-allow, to avoid breaking e.g. H3lix.
            // // This works since the provisioning profile contains all entitlements+values we're allowed.
            // // We are allowed a subset of this profile's listing, not necessarily all of them!
            // if ([[entitlements allKeys] containsObject:@"get-task-allow"]) {
            //     [entitlements removeObjectForKey:@"get-task-allow"];
            // }

            // APG3427HIY -> App Groups. This can be used without a paid account.
            BOOL wantsApplicationGroups = NO;
            NSMutableArray *applicationGroups;
            if ([[entitlements allKeys] containsObject:@"com.apple.security.application-groups"]) {
                [enabledFeatures setObject:@"on" forKey:@"APG3427HIY"];

                // We need to do some magic on the dev portal with these.
                wantsApplicationGroups = YES;
                applicationGroups = [[entitlements objectForKey:@"com.apple.security.application-groups"] mutableCopy];
            }

            NSLog(@"new entitlements: %@ / enabledFeatures:%@ / location: %@", entitlements, enabledFeatures, binaryLocation);

            if (!appIdExists) {
                // /addAppId
                NSLog(@"This appId doesn't exist yet, so making a new one.");

                [[EEAppleServices sharedInstance] addApplicationId:identifier name:name enabledFeatures:enabledFeatures teamID:[[EEAppleServices sharedInstance] currentTeamID] entitlements:entitlements systemType:systemType withCompletionHandler:^(NSError *error, NSDictionary *plist) {
                    if (error) {
                        NSError *err = [EEProvisioning _errorFromString:[@"addApplicationId: " stringByAppendingString:error.localizedDescription]];
                        completionHandler(err, @"", nil);
                        return;
                    }

                    int resultCode = [[plist objectForKey:@"resultCode"] intValue];
                    if (resultCode != 0) {
                        NSError *err = [EEProvisioning _errorFromString:[@"addApplicationId: " stringByAppendingString:[plist objectForKey:@"userString"]]];
                        completionHandler(err, @"", nil);
                        return;
                    }

                    // Assign to application group if needed.
                    NSString *newAppIdId;
                    @try {
                        newAppIdId = [[plist objectForKey:@"appId"] objectForKey:@"appIdId"];
                    } @catch (NSException *e) {
                        newAppIdId = @"";
                    }

                    if (wantsApplicationGroups) {
                        [self _recursivelyAssignApplicationIdId:newAppIdId toApplicationGroups:applicationGroups interimAppGroups:[NSMutableArray array] systemType:systemType withCompletionHandler:^(NSError *error, NSArray *output) {
                            if (error) {
                                completionHandler(error, nil, nil);
                                return;
                            }

                            // Update entitlements with new stuff
                            [entitlements setObject:output forKey:@"com.apple.security.application-groups"];

                            completionHandler(nil, newAppIdId, entitlements);
                        }];

                    } else {
                        completionHandler(nil, newAppIdId, entitlements);
                    }
                }];
            } else {
                // /updateAppId
                NSLog(@"This appId already exists, so updating it.");

                [[EEAppleServices sharedInstance] updateApplicationIdId:appIdIdIfExists enabledFeatures:enabledFeatures teamID:[[EEAppleServices sharedInstance] currentTeamID] entitlements:entitlements systemType:systemType withCompletionHandler:^(NSError *error, NSDictionary *plist) {
                    if (error) {
                        NSError *err = [EEProvisioning _errorFromString:[@"updateApplicationIdId: " stringByAppendingString:error.localizedDescription]];
                        completionHandler(err, @"", nil);
                        return;
                    }

                    int resultCode = [[plist objectForKey:@"resultCode"] intValue];
                    if (resultCode != 0) {
                        NSError *err = [EEProvisioning _errorFromString:[@"updateApplicationIdId: " stringByAppendingString:[plist objectForKey:@"userString"]]];
                        completionHandler(err, @"", nil);
                        return;
                    }

                    // Assign to application group if needed.
                    NSString *newAppIdId;
                    @try {
                        newAppIdId = [[plist objectForKey:@"appId"] objectForKey:@"appIdId"];
                    } @catch (NSException *e) {
                        newAppIdId = @"";
                    }

                    if (wantsApplicationGroups) {
                        [self _recursivelyAssignApplicationIdId:newAppIdId toApplicationGroups:applicationGroups interimAppGroups:[NSMutableArray array] systemType:systemType withCompletionHandler:^(NSError *error, NSArray *output) {
                            if (error) {
                                completionHandler(error, nil, nil);
                                return;
                            }

                            // Update entitlements with new stuff
                            [entitlements setObject:output forKey:@"com.apple.security.application-groups"];

                            completionHandler(nil, newAppIdId, entitlements);
                        }];

                    } else {
                        completionHandler(nil, newAppIdId, entitlements);
                    }
                }];
            }
        }];
    }];
}

- (void)_recursivelyAssignApplicationIdId:(NSString *)applicationIdId toApplicationGroups:(NSMutableArray *)applicationGroups interimAppGroups:(NSMutableArray *)interimAppGroups systemType:(EESystemType)systemType withCompletionHandler:(void (^)(NSError *, NSArray *))completionHandler {
    // End case guard
    if (applicationGroups.count == 0) {
        completionHandler(nil, interimAppGroups);
        return;
    }

    NSString *nextApplicationGroup = [applicationGroups firstObject];

    [self _assignApplicationIdId:applicationIdId
              toGroupIfNecessary:nextApplicationGroup
                      systemType:systemType
           withCompletionHandler:^(NSError *error, NSString *groupIdentifier) {
               if (error) {
                   completionHandler(error, nil);
                   return;
               }

               [applicationGroups removeObjectAtIndex:0];

               // Update the entitlements.
               [interimAppGroups addObject:groupIdentifier];

               // And recurse over the remaining elements.
               [self _recursivelyAssignApplicationIdId:applicationIdId toApplicationGroups:applicationGroups interimAppGroups:interimAppGroups systemType:systemType withCompletionHandler:completionHandler];
           }];
}

- (void)_assignApplicationIdId:(NSString *)applicationIdId toGroupIfNecessary:(NSString *)applicationGroupIdentifier systemType:(EESystemType)systemType withCompletionHandler:(void (^)(NSError *, NSString *))completionHandler {
    [[EEAppleServices sharedInstance] listAllApplicationGroupsForTeamID:[[EEAppleServices sharedInstance] currentTeamID] systemType:systemType withCompletionHandler:^(NSError *error, NSDictionary *plist) {
        if (error) {
            completionHandler(error, nil);
            return;
        }

        if ([[plist objectForKey:@"resultCode"] intValue] != 0) {
            NSError *error = [EEProvisioning _errorFromString:[plist objectForKey:@"resultString"]];
            completionHandler(error, nil);
            return;
        }

        // We should return the application group ID to the caller's completion block, so we can update the
        // entitlements dictionary.

        /*
         * The idea here is that we check if a group containing the applicationGroupIdentifier string
         * in its own identifier without the "group." suffix exists. If it does, grab the full identifier
         * and roll with that. If not, we create one.
         */

        BOOL groupExists = NO;

        NSString *callerGroupIDNoPrefix = [applicationGroupIdentifier stringByReplacingOccurrencesOfString:@"group." withString:@""];

        // We may still have a UUID prefixed to the groupID. So, we need to remove that.
        if ([callerGroupIDNoPrefix hasPrefix:@"EE-"] || [callerGroupIDNoPrefix hasPrefix:@"AltStore"]) {
            NSRange range = [callerGroupIDNoPrefix rangeOfString:@"."];
            if (range.location != NSNotFound) {
                // Remove up to the .
                callerGroupIDNoPrefix = [callerGroupIDNoPrefix substringFromIndex:range.location + 1];
            }
        }

        NSString *groupIdentifierIfExists = @"";
        NSString *applicationGroupEntryIfExists = @"";

        for (NSDictionary *groupDictionary in plist[@"applicationGroupList"]) {
            if ([(NSString *)[groupDictionary objectForKey:@"identifier"] containsString:callerGroupIDNoPrefix]) {
                groupExists = YES;
                groupIdentifierIfExists = [groupDictionary objectForKey:@"identifier"];
                applicationGroupEntryIfExists = [groupDictionary objectForKey:@"applicationGroup"];
                break;
            }
        }

        if (groupExists) {
            // Assign the passed-in appIdId to this group, if needed.

            [self _assignAppIdId:applicationIdId
                toApplicationGroupIdentifier:applicationGroupEntryIfExists
                                  systemType:systemType
                       withCompletionHandler:^(NSError *error) {
                           if (error) {
                               completionHandler(error, nil);
                               return;
                           }

                           completionHandler(nil, groupIdentifierIfExists);
                       }];

        } else {
            // No group exists already, so we generate one.

            NSString *newGroupIdentifier = [NSString stringWithFormat:@"group.%@.%@", callerGroupIDNoPrefix, [[EEAppleServices sharedInstance] currentTeamID]];
            NSString *newGroupName = [NSString stringWithFormat:@"EE- group %@", [callerGroupIDNoPrefix stringByReplacingOccurrencesOfString:@"." withString:@" "]];

            // We normally add to the "group.EE-<UUID>.<identifier>" group.
            [[EEAppleServices sharedInstance] addApplicationGroupWithIdentifier:newGroupIdentifier andName:newGroupName forTeamID:[[EEAppleServices sharedInstance] currentTeamID] systemType:systemType withCompletionHandler:^(NSError *error, NSDictionary *plist) {
                if (error) {
                    completionHandler(error, nil);
                    return;
                }

                if ([[plist objectForKey:@"resultCode"] intValue] != 0) {
                    NSError *error = [EEProvisioning _errorFromString:[plist objectForKey:@"resultString"]];
                    completionHandler(error, nil);
                    return;
                }

                // Obtain new "applicationGroup" value for this newly added group.
                NSString *newGroupName = [[plist objectForKey:@"applicationGroup"] objectForKey:@"applicationGroup"];

                // With the new group identifier, we then assign the passed-in Application ID to this group.
                [self _assignAppIdId:applicationIdId toApplicationGroupIdentifier:newGroupName systemType:systemType withCompletionHandler:^(NSError *error) {
                    if (error) {
                        completionHandler(error, nil);
                        return;
                    }

                    completionHandler(nil, groupIdentifierIfExists);
                }];
            }];
        }
    }];
}

- (void)_assignAppIdId:(NSString *)appIdId toApplicationGroupIdentifier:(NSString *)groupIdentifier systemType:(EESystemType)systemType withCompletionHandler:(void (^)(NSError *))completionHandler {
    // Assign to application group.
    NSLog(@"Assigning appIdId '%@' to application group '%@'", appIdId, groupIdentifier);

    [[EEAppleServices sharedInstance] assignApplicationGroup:groupIdentifier toApplicationIdId:appIdId teamID:[[EEAppleServices sharedInstance] currentTeamID] systemType:systemType withCompletionHandler:^(NSError *error, NSDictionary *plist) {
        if (error) {
            completionHandler(error);
            return;
        }

        if ([[plist objectForKey:@"resultCode"] intValue] != 0) {
            NSError *error = [EEProvisioning _errorFromString:[plist objectForKey:@"resultString"]];
            completionHandler(error);
            return;
        }

        completionHandler(nil);
    }];
}

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Private methods: provisioning stage 4
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)_provisioningStageFourWithIdentifier:(NSString *)identifier appIdId:(NSString *)appIdId systemType:(EESystemType)systemType andCallback:(void (^)(NSError *, NSData *))completionHandler {
    /*
     * Stage 4
     * 6. Remove the existing provisioning profile for this application entry.
     * 7. Download the provisioning certificate for this application entry.
     */

    [self _removeExistingProvisioningProfileForApplication:identifier
                                                systemType:systemType
                                              withCallback:^(NSError *error) {
                                                  // No need to worry if this actually succeeded or not.

                                                  NSLog(@"Fetching new provisioning profile for '%@'", identifier);

                                                  [self _downloadTeamProvisioningProfileForAppIdId:appIdId
                                                                                        systemType:systemType
                                                                                      withCallback:^(NSError *error, NSData *result) {
                                                                                          completionHandler(error, result);
                                                                                      }];
                                              }];
}

- (void)_downloadTeamProvisioningProfileForAppIdId:(NSString *)appIdId systemType:(EESystemType)systemType withCallback:(void (^)(NSError *, NSData *))completionHandler {
    [[EEAppleServices sharedInstance] getProvisioningProfileForAppIdId:appIdId withTeamID:[[EEAppleServices sharedInstance] currentTeamID] systemType:systemType andCompletionHandler:^(NSError *error, NSDictionary *plist) {
        if (error) {
            NSError *err = [EEProvisioning _errorFromString:[@"getProvisioningProfileForAppIdId: " stringByAppendingString:error.localizedDescription]];
            completionHandler(err, nil);
            return;
        }

        if ([[plist objectForKey:@"resultCode"] intValue] != 0) {
            NSError *err = [EEProvisioning _errorFromString:[@"getProvisioningProfileForAppIdId: " stringByAppendingString:[plist objectForKey:@"resultString"]]];
            completionHandler(err, nil);
            return;
        }

        @try {
            NSDictionary *profile = [plist objectForKey:@"provisioningProfile"];
            NSData *encodedProfile = [profile objectForKey:@"encodedProfile"];

            completionHandler(nil, encodedProfile);
        } @catch (NSException *e) {
            NSError *err = [EEProvisioning _errorFromString:[@"getProvisioningProfileForAppIdId: " stringByAppendingString:e.reason]];
            completionHandler(err, nil);
        }
    }];
}

// Returns NO to the callback if no profile was deleted, YES if one was.
- (void)_removeExistingProvisioningProfileForApplication:(NSString *)bundleIdentifier systemType:(EESystemType)systemType withCallback:(void (^)(NSError *))completionHandler {
    NSLog(@"Revoking old provisioning profile for '%@' if possible", bundleIdentifier);

    NSString *_actualIdentifier = [NSString stringWithFormat:@"%@.%@", [[EEAppleServices sharedInstance] currentTeamID], bundleIdentifier];

    [[EEAppleServices sharedInstance] deleteProvisioningProfileForApplication:_actualIdentifier
                                                                    andTeamID:[[EEAppleServices sharedInstance] currentTeamID]
                                                                   systemType:systemType
                                                        withCompletionHandler:^(NSError *error, NSDictionary *plist) {
                                                            if (error) {
                                                                completionHandler(error);
                                                                return;
                                                            }

                                                            // Done!
                                                            completionHandler(nil);
                                                        }];
}

@end
