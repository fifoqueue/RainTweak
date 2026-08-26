#import "Telemetry.h"

#import <objc/message.h>
#import <objc/runtime.h>

#import "Logger.h"

static NSString *const RainTelemetryProtocolKey = @"RainTelemetryProtocol";

BOOL RainShouldBlockTelemetryURL(NSURL *url)
{
    if (!url) return NO;

    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path.lowercaseString ?: @"";

    if ([host containsString:@"appsflyer"] ||
        [host isEqualToString:@"app.adjust.com"] ||
        [host isEqualToString:@"datadog.discord.tools"] ||
        [host isEqualToString:@"client-analytics.braintreegateway.com"] ||
        [host hasSuffix:@".ingest.sentry.io"] ||
        [host isEqualToString:@"ingest.sentry.io"] ||
        [host isEqualToString:@"browser.sentry-cdn.com"])
    {
        return YES;
    }

    BOOL discordHost = [host isEqualToString:@"discord.com"] ||
                       [host hasSuffix:@".discord.com"] ||
                       [host isEqualToString:@"discordapp.com"] ||
                       [host hasSuffix:@".discordapp.com"];
    if (!discordHost) return NO;

    static NSRegularExpression *analyticsPath;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        analyticsPath = [NSRegularExpression regularExpressionWithPattern:
            @"^/(?:api(?:/v[0-9]+)?/)?(?:science|track)(?:/|$)"
                                                                  options:0
                                                                    error:nil];
    });

    return [analyticsPath firstMatchInString:path
                                     options:0
                                       range:NSMakeRange(0, path.length)] != nil;
}

@interface RainTelemetryBlockURLProtocol : NSURLProtocol
@end

@implementation RainTelemetryBlockURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    if ([NSURLProtocol propertyForKey:RainTelemetryProtocolKey inRequest:request]) return NO;
    return RainShouldBlockTelemetryURL(request.URL);
}

+ (BOOL)canInitWithTask:(NSURLSessionTask *)task
{
    return RainShouldBlockTelemetryURL(task.currentRequest.URL ?: task.originalRequest.URL);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b
{
    return [super requestIsCacheEquivalent:a toRequest:b];
}

- (void)startLoading
{
    NSURL *url = self.request.URL;
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url
                                                            statusCode:204
                                                           HTTPVersion:@"HTTP/1.1"
                                                          headerFields:@{
        @"Content-Length": @"0",
        @"X-Rain-Telemetry-Blocked": @"1"
    }];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading
{
}

@end

static NSURLSessionConfiguration *(*originalDefaultConfiguration)(id, SEL);
static NSURLSessionConfiguration *(*originalEphemeralConfiguration)(id, SEL);

static NSURLSessionConfiguration *RainAddTelemetryProtocol(NSURLSessionConfiguration *configuration)
{
    NSArray<Class> *classes = configuration.protocolClasses ?: @[];
    if (![classes containsObject:RainTelemetryBlockURLProtocol.class])
    {
        configuration.protocolClasses = [@[RainTelemetryBlockURLProtocol.class]
            arrayByAddingObjectsFromArray:classes];
    }
    return configuration;
}

static NSURLSessionConfiguration *RainDefaultConfiguration(id self, SEL command)
{
    return RainAddTelemetryProtocol(originalDefaultConfiguration(self, command));
}

static NSURLSessionConfiguration *RainEphemeralConfiguration(id self, SEL command)
{
    return RainAddTelemetryProtocol(originalEphemeralConfiguration(self, command));
}

static void RainReplaceClassMethod(Class cls, SEL selector, IMP replacement)
{
    Method method = class_getClassMethod(cls, selector);
    if (method) method_setImplementation(method, replacement);
}

static void RainReplaceInstanceMethod(Class cls, SEL selector, IMP replacement)
{
    Method method = class_getInstanceMethod(cls, selector);
    if (method) method_setImplementation(method, replacement);
}

static void RainNoopVoid(id self, SEL command, ...)
{
}

static id RainReturnNil(id self, SEL command, ...)
{
    return nil;
}

static BOOL RainReturnYes(id self, SEL command)
{
    return YES;
}

static void RainAppsFlyerCompletion(id self, SEL command, id completion)
{
    if (completion)
    {
        void (^handler)(NSDictionary *, NSError *) = (void (^)(NSDictionary *, NSError *))completion;
        handler(@{}, nil);
    }
}

static void RainInstallSessionHooks(void)
{
    [NSURLProtocol registerClass:RainTelemetryBlockURLProtocol.class];

    Method method = class_getClassMethod(NSURLSessionConfiguration.class, @selector(defaultSessionConfiguration));
    if (method)
    {
        originalDefaultConfiguration = (NSURLSessionConfiguration *(*)(id, SEL))method_getImplementation(method);
        method_setImplementation(method, (IMP)RainDefaultConfiguration);
    }

    method = class_getClassMethod(NSURLSessionConfiguration.class, @selector(ephemeralSessionConfiguration));
    if (method)
    {
        originalEphemeralConfiguration = (NSURLSessionConfiguration *(*)(id, SEL))method_getImplementation(method);
        method_setImplementation(method, (IMP)RainEphemeralConfiguration);
    }

}

static void RainInstallSentryHooks(void)
{
    Class sentry = NSClassFromString(@"SentrySDK") ?: NSClassFromString(@"_TtC6Sentry9SentrySDK");
    if (!sentry) return;

    for (NSString *name in @[
        @"startWithConfigureOptions:", @"startWithOptions:", @"startSession", @"endSession",
        @"addBreadcrumb:", @"reportFullyDisplayed"
    ])
    {
        RainReplaceClassMethod(sentry, NSSelectorFromString(name), (IMP)RainNoopVoid);
    }

    for (NSString *name in @[
        @"captureEvent:", @"captureEvent:withScope:", @"captureEvent:withScopeBlock:",
        @"captureException:", @"captureException:withScope:", @"captureException:withScopeBlock:",
        @"captureMessage:", @"captureMessage:withScope:", @"captureMessage:withScopeBlock:",
        @"captureError:", @"captureError:withScope:", @"captureEnvelope:"
    ])
    {
        RainReplaceClassMethod(sentry, NSSelectorFromString(name), (IMP)RainReturnNil);
    }
}

static void RainInstallAppsFlyerHooks(void)
{
    Class appsFlyer = NSClassFromString(@"AppsFlyerLib");
    if (!appsFlyer) return;

    SEL sharedSelector = NSSelectorFromString(@"shared");
    if ([appsFlyer respondsToSelector:sharedSelector])
    {
        id shared = ((id (*)(id, SEL))objc_msgSend)(appsFlyer, sharedSelector);
        SEL stopSelector = NSSelectorFromString(@"setIsStopped:");
        if ([shared respondsToSelector:stopSelector])
            ((void (*)(id, SEL, BOOL))objc_msgSend)(shared, stopSelector, YES);
    }

    for (NSString *name in @[
        @"start", @"logEvent:withValues:", @"__logEvent:withValues:completionHandler:"
    ])
    {
        RainReplaceInstanceMethod(appsFlyer, NSSelectorFromString(name), (IMP)RainNoopVoid);
    }

    for (NSString *name in @[
        @"startWithCompletionHandler:", @"__startWithCompletionHandler:",
        @"logEvent:withValues:completionHandler:"
    ])
    {
        RainReplaceInstanceMethod(appsFlyer, NSSelectorFromString(name), (IMP)RainAppsFlyerCompletion);
    }

    RainReplaceInstanceMethod(appsFlyer, NSSelectorFromString(@"setIsStopped:"), (IMP)RainNoopVoid);
    RainReplaceInstanceMethod(appsFlyer, NSSelectorFromString(@"isStopped"), (IMP)RainReturnYes);
}

static void RainInstallMetricKitHooks(void)
{
    Class metricKit = NSClassFromString(@"DCDMetricKitModule");
    if (!metricKit) return;
    RainReplaceInstanceMethod(metricKit, NSSelectorFromString(@"didReceiveMetricPayloads:"), (IMP)RainNoopVoid);
    RainReplaceInstanceMethod(metricKit, NSSelectorFromString(@"didReceiveDiagnosticPayloads:"), (IMP)RainNoopVoid);
}

void RainInstallTelemetryKillSwitch(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        RainInstallSessionHooks();
        RainInstallSentryHooks();
        RainInstallAppsFlyerHooks();
        RainInstallMetricKitHooks();
        BunnyLog(@"Telemetry kill switch installed");
    });
}
